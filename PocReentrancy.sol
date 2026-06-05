// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WAD, ORACLE_PRICE_SCALE, CALLBACK_SUCCESS} from "../src/libraries/ConstantsLib.sol";
import {IMidnight, Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {IBuyCallback, ISellCallback, IRepayCallback, IFlashLoanCallback, ILiquidateCallback}
    from "../src/interfaces/ICallbacks.sol";
import {UtilsLib} from "../src/libraries/UtilsLib.sol";
import {TickLib, MAX_TICK} from "../src/libraries/TickLib.sol";
import {Midnight} from "../src/Midnight.sol";
import {Oracle} from "./helpers/Oracle.sol";
import {BaseTest, MAX_TEST_AMOUNT} from "./BaseTest.sol";
import {ERC20} from "./erc20s/ERC20.sol";

/// Focused reentrancy harness for `take`'s onBuy/onSell callbacks.
///
/// `take` commits ALL state effects (positions, totalUnits, claimableSettlementFee, consumed)
/// BEFORE the onBuy callback, the inbound transfers, and the onSell callback. Certora stubs
/// onBuy/onSell as NONDET in every spec (including Solvency), so reentrancy through these two
/// callbacks is formally unmodeled. This harness drives a malicious callback that re-enters
/// Midnight mid-`take` and checks three invariants on the FINAL state:
///   (1) tokenBalanceCorrect: loanToken.balanceOf(midnight) >= withdrawable + claimableSettlementFee
///   (2) creditXORdebt:       no tracked user has credit>0 AND debt>0
///   (3) totalUnits:          sum(updated credit over all users) + continuousFeeCredit == totalUnits

contract Attacker is IBuyCallback, ISellCallback, IRepayCallback, IFlashLoanCallback, ILiquidateCallback {
    Midnight public midnight;
    ERC20 public loanToken;

    // Reentrancy program: what to do inside the callback, executed exactly once.
    enum Mode { NONE, TAKE, WITHDRAW, REPAY, LIQUIDATE, FLASHLOAN }

    Mode public mode;
    bool internal fired;

    // Parameters for the reentrant action, set by the test before the outer take.
    Market internal reMarket;
    Offer internal reOffer; // for TAKE
    uint256 internal reUnits; // for TAKE / WITHDRAW / REPAY / FLASHLOAN
    address internal reBorrower; // for LIQUIDATE
    uint256 internal reSeized; // for LIQUIDATE

    constructor(Midnight _midnight, ERC20 _loanToken) {
        midnight = _midnight;
        loanToken = _loanToken;
        _loanToken.approve(address(_midnight), type(uint256).max);
        // Authorize the deployer (the test) to act on this contract's behalf (supply collateral, etc.).
        _midnight.setIsAuthorized(msg.sender, true, address(this));
    }

    function arm(Mode _mode, Market memory m, Offer memory o, uint256 units, address borrower, uint256 seized)
        external
    {
        mode = _mode;
        reMarket = m;
        reOffer = o;
        reUnits = units;
        reBorrower = borrower;
        reSeized = seized;
        fired = false;
    }

    function approveCollateral(address token) external {
        ERC20(token).approve(address(midnight), type(uint256).max);
    }

    function _reenter() internal {
        if (fired || mode == Mode.NONE) return;
        fired = true;
        if (mode == Mode.TAKE) {
            midnight.take(reOffer, hex"", reUnits, address(this), address(this), address(0), hex"");
        } else if (mode == Mode.WITHDRAW) {
            midnight.withdraw(reMarket, reUnits, address(this), address(this));
        } else if (mode == Mode.REPAY) {
            midnight.repay(reMarket, reUnits, address(this), address(0), hex"");
        } else if (mode == Mode.LIQUIDATE) {
            midnight.liquidate(reMarket, 0, reSeized, 0, reBorrower, false, address(this), address(0), hex"");
        } else if (mode == Mode.FLASHLOAN) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = address(loanToken);
            amounts[0] = reUnits;
            midnight.flashLoan(tokens, amounts, address(this), hex"");
        }
    }

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory)
        external
        returns (bytes32)
    {
        _reenter();
        return CALLBACK_SUCCESS;
    }

    function onSell(bytes32, Market memory, uint256, uint256, uint256, address, address, bytes memory)
        external
        returns (bytes32)
    {
        _reenter();
        return CALLBACK_SUCCESS;
    }

    function onRepay(bytes32, Market memory, uint256, address, bytes memory) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }

    function onLiquidate(address, bytes32, Market memory, uint256, uint256, uint256, address, address, bytes memory, uint256)
        external
        pure
        returns (bytes32)
    {
        return CALLBACK_SUCCESS;
    }

    function onFlashLoan(address, address[] memory, uint256[] memory, bytes memory) external pure returns (bytes32) {
        // Flash loaned tokens are already in this contract and approved; Midnight pulls them back.
        return CALLBACK_SUCCESS;
    }
}

contract PocReentrancy is BaseTest {
    using UtilsLib for uint256;

    Market internal market;
    bytes32 internal id;
    Attacker internal attacker;

    uint256 internal constant HALF = 0.5e18;

    address[] internal users;

    function setUp() public override {
        super.setUp();

        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 100 days;
        market.collateralParams.push(
            CollateralParams({
                token: address(collateralToken1),
                lltv: 0.77e18,
                maxLif: maxLif(0.77e18, 0.25e18),
                oracle: address(oracle1)
            })
        );
        market.rcfThreshold = 0;
        id = toId(market);

        midnight.touchMarket(market);
        midnight.setMarketTickSpacing(id, 1); // unlock all ticks
        // settlement fee left at 0 (default) for clean invariant-1 arithmetic.
        // continuous fee left at 0 (default) so continuousFeeCredit stays 0.

        Oracle(address(oracle1)).setPrice(ORACLE_PRICE_SCALE); // 1:1

        attacker = new Attacker(midnight, ERC20(address(loanToken)));
        attacker.approveCollateral(address(collateralToken1));

        users = [borrower, lender, otherBorrower, otherLender, address(attacker)];

        deal(address(loanToken), address(attacker), MAX_TEST_AMOUNT);
        deal(address(loanToken), lender, MAX_TEST_AMOUNT);
        deal(address(loanToken), otherLender, MAX_TEST_AMOUNT);
    }

    /// HELPERS ///

    // A resting SELL offer by `maker` at `tick`: taker becomes the BUYER (gains credit).
    function sellOffer(address maker, uint256 tick) internal view returns (Offer memory o) {
        o.market = market;
        o.buy = false;
        o.maker = maker;
        o.receiverIfMakerIsSeller = maker;
        o.maxUnits = type(uint256).max;
        o.group = keccak256(abi.encode("sell", maker));
        o.ratifier = address(dummyRatifier);
        o.start = vm.getBlockTimestamp();
        o.expiry = vm.getBlockTimestamp() + 1000 days;
        o.tick = tick;
    }

    // A resting BUY offer by `maker` at `tick`: taker becomes the SELLER (gains debt).
    function buyOffer(address maker, uint256 tick) internal view returns (Offer memory o) {
        o.market = market;
        o.buy = true;
        o.maker = maker;
        o.maxUnits = type(uint256).max;
        o.group = keccak256(abi.encode("buy", maker));
        o.ratifier = address(dummyRatifier);
        o.start = vm.getBlockTimestamp();
        o.expiry = vm.getBlockTimestamp() + 1000 days;
        o.tick = tick;
    }

    // Seed the market with a withdrawable pool: `who` borrows `amt` from `lender`, then repays it.
    // Net effect: withdrawable == amt, lender keeps `amt` credit, `who` ends with 0 debt.
    function seedWithdrawable(address who, uint256 amt) internal {
        collateralize(market, who, amt);
        Offer memory o = sellOffer(who, MAX_TICK); // price 1, no discount
        vm.prank(lender);
        midnight.take(o, hex"", amt, lender, lender, address(0), hex"");
        // `who` now owes `amt`; lender holds `amt` credit. Now `who` repays -> withdrawable grows.
        deal(address(loanToken), who, amt);
        vm.prank(who);
        loanToken.approve(address(midnight), amt);
        vm.prank(who);
        midnight.repay(market, amt, who, address(0), hex"");
    }

    function checkInvariants(string memory tag) internal view {
        // (1) token balance covers withdrawable + claimable settlement fee.
        uint256 bal = loanToken.balanceOf(address(midnight));
        uint256 wd = midnight.withdrawable(id);
        uint256 fee = midnight.claimableSettlementFee(address(loanToken));
        require(bal >= wd + fee, string.concat("INV1 broken: ", tag));

        // (2) credit XOR debt per user.
        for (uint256 i; i < users.length; i++) {
            uint256 c = midnight.creditOf(id, users[i]);
            uint256 d = midnight.debtOf(id, users[i]);
            require(!(c > 0 && d > 0), string.concat("INV2 broken: ", tag));
        }

        // (3) sum of up-to-date credit + continuousFeeCredit == totalUnits.
        uint256 sumCredit;
        for (uint256 i; i < users.length; i++) {
            (uint128 credit,,) = midnight.updatePositionView(market, id, users[i]);
            sumCredit += credit;
        }
        sumCredit += midnight.continuousFeeCredit(id);
        require(sumCredit == midnight.totalUnits(id), string.concat("INV3 broken: ", tag));
    }

    /// VECTOR A: re-enter take() during onBuy.
    /// Attacker buys credit from otherBorrower's sell offer; inside onBuy it takes a SECOND sell
    /// offer (from a fresh maker) to gain more credit before paying for the first.
    function test_reenter_take_during_onBuy() public {
        // Outer maker: otherBorrower sells (gains debt), must stay healthy.
        collateralize(market, otherBorrower, 1000);
        // Inner maker: `borrower` sells too.
        collateralize(market, borrower, 1000);

        Offer memory inner = sellOffer(borrower, MAX_TICK / 2); // price 0.5
        attacker.arm(Attacker.Mode.TAKE, market, inner, 100, address(0), 0);

        Offer memory outer = sellOffer(otherBorrower, MAX_TICK / 2);
        // attacker takes the outer sell offer with itself as callback.
        vm.prank(address(attacker));
        midnight.take(outer, hex"", 100, address(attacker), address(attacker), address(attacker), hex"");

        checkInvariants("take/onBuy");
        emit log_named_uint("attacker credit", midnight.creditOf(id, address(attacker)));
    }

    /// VECTOR B: re-enter withdraw() during onBuy.
    /// Attacker gains `units` credit (not yet paid) and immediately withdraws it against a
    /// pre-seeded withdrawable pool BEFORE its own payment lands.
    function test_reenter_withdraw_during_onBuy() public {
        seedWithdrawable(otherBorrower, 500); // withdrawable = 500, backed by lender credit
        collateralize(market, borrower, 1000); // outer maker (seller)

        uint256 balBefore = loanToken.balanceOf(address(attacker));

        attacker.arm(Attacker.Mode.WITHDRAW, market, sellOffer(address(0), 0), 100, address(0), 0);

        Offer memory outer = sellOffer(borrower, MAX_TICK / 2); // price 0.5: attacker pays 50, gains 100 credit
        vm.prank(address(attacker));
        midnight.take(outer, hex"", 100, address(attacker), address(attacker), address(attacker), hex"");

        checkInvariants("withdraw/onBuy");

        int256 attackerPnl = int256(loanToken.balanceOf(address(attacker))) - int256(balBefore);
        emit log_named_int("attacker loan-token PnL (wei)", attackerPnl);
        emit log_named_uint("attacker credit after", midnight.creditOf(id, address(attacker)));
        emit log_named_uint("withdrawable after", midnight.withdrawable(id));
    }

    /// VECTOR C: re-enter repay() during onSell.
    /// Attacker SELLS (gains debt) via a buy offer; inside onSell it repays its own debt.
    function test_reenter_repay_during_onSell() public {
        // Attacker is the seller -> needs collateral to be healthy at the end of take.
        deal(address(collateralToken1), address(this), 100000);
        collateralToken1.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 100000, address(attacker)); // onBehalf=attacker (test is authorized)

        // Lender posts a buy offer; attacker takes it as seller.
        Offer memory outer = buyOffer(lender, MAX_TICK / 2);

        // Inside onSell, repay 40 of the 100 debt just created.
        attacker.arm(Attacker.Mode.REPAY, market, outer, 40, address(0), 0);

        vm.prank(address(attacker));
        midnight.take(outer, hex"", 100, address(attacker), address(attacker), address(attacker), hex"");

        checkInvariants("repay/onSell");
        emit log_named_uint("attacker debt after", midnight.debtOf(id, address(attacker)));
    }

    /// VECTOR D: re-enter liquidate() during onBuy.
    /// Attacker buys credit; inside onBuy it liquidates an unhealthy borrower (realizing bad debt
    /// -> bumping lossFactor and totalUnits) WHILE the outer take's credit increase is half-applied.
    ///
    /// CONTROL: we run the IDENTICAL operations both reentrantly and sequentially and compare the
    /// (totalUnits - sumCredit) gap. If the gap is identical, the INV3 inequality is the DOCUMENTED
    /// bad-debt rounding (lenders collectively lose slightly more than badDebt), not a reentrancy bug.
    function test_reenter_liquidate_during_onBuy() public {
        _setupLiquidateScenario();

        uint256 snap = vm.snapshotState();

        // --- Reentrant: liquidate fired inside the outer take's onBuy callback ---
        attacker.arm(Attacker.Mode.LIQUIDATE, market, sellOffer(address(0), 0), 0, otherBorrower, 0);
        Offer memory outer = sellOffer(borrower, MAX_TICK / 2);
        vm.prank(address(attacker));
        midnight.take(outer, hex"", 10, address(attacker), address(attacker), address(attacker), hex"");

        (uint256 tuR, uint256 scR) = _totalUnitsVsSumCredit();
        emit log_named_uint("[reentrant]  totalUnits", tuR);
        emit log_named_uint("[reentrant]  sumCredit ", scR);
        emit log_named_uint("[reentrant]  gap       ", tuR - scR);
        // Real solvency direction must hold either way: claims never exceed accounted units.
        require(scR <= tuR, "INV3 solvency broken (reentrant): sumCredit > totalUnits");
        checkInvariantsExceptTotalUnits("liquidate/onBuy");

        // --- Sequential baseline: take fully, THEN liquidate ---
        vm.revertToState(snap);
        attacker.arm(Attacker.Mode.NONE, market, sellOffer(address(0), 0), 0, address(0), 0);
        vm.prank(address(attacker));
        midnight.take(outer, hex"", 10, address(attacker), address(attacker), address(attacker), hex"");
        midnight.liquidate(market, 0, 0, 0, otherBorrower, false, address(this), address(0), hex"");

        (uint256 tuS, uint256 scS) = _totalUnitsVsSumCredit();
        emit log_named_uint("[sequential] totalUnits", tuS);
        emit log_named_uint("[sequential] sumCredit ", scS);
        emit log_named_uint("[sequential] gap       ", tuS - scS);

        // The verdict: identical end-state => reentrancy changed nothing (rounding only).
        assertEq(tuR, tuS, "totalUnits differ between reentrant and sequential");
        assertEq(scR, scS, "sumCredit differs between reentrant and sequential");
    }

    function _setupLiquidateScenario() internal {
        // Victim borrower with debt that will go unhealthy.
        collateralize(market, otherBorrower, 1000);
        Offer memory vOffer = sellOffer(otherBorrower, MAX_TICK);
        vm.prank(lender);
        midnight.take(vOffer, hex"", 1000, lender, lender, address(0), hex"");

        // Outer maker: borrower sells (healthy, ample collateral even at the LOW price).
        collateralize(market, borrower, 100000);
        Oracle(address(oracle1)).setPrice(ORACLE_PRICE_SCALE / 100); // drop so otherBorrower has bad debt
    }

    function _totalUnitsVsSumCredit() internal view returns (uint256 totalUnits_, uint256 sumCredit_) {
        for (uint256 i; i < users.length; i++) {
            (uint128 credit,,) = midnight.updatePositionView(market, id, users[i]);
            sumCredit_ += credit;
        }
        sumCredit_ += midnight.continuousFeeCredit(id);
        totalUnits_ = midnight.totalUnits(id);
    }

    function checkInvariantsExceptTotalUnits(string memory tag) internal view {
        uint256 bal = loanToken.balanceOf(address(midnight));
        uint256 wd = midnight.withdrawable(id);
        uint256 fee = midnight.claimableSettlementFee(address(loanToken));
        require(bal >= wd + fee, string.concat("INV1 broken: ", tag));
        for (uint256 i; i < users.length; i++) {
            uint256 c = midnight.creditOf(id, users[i]);
            uint256 d = midnight.debtOf(id, users[i]);
            require(!(c > 0 && d > 0), string.concat("INV2 broken: ", tag));
        }
    }

    /// VECTOR E: re-enter flashLoan() during onBuy.
    function test_reenter_flashLoan_during_onBuy() public {
        seedWithdrawable(otherBorrower, 1000); // give the contract a loan-token balance to flash
        collateralize(market, borrower, 1000);

        attacker.arm(Attacker.Mode.FLASHLOAN, market, sellOffer(address(0), 0), 500, address(0), 0);

        Offer memory outer = sellOffer(borrower, MAX_TICK / 2);
        vm.prank(address(attacker));
        midnight.take(outer, hex"", 100, address(attacker), address(attacker), address(attacker), hex"");

        checkInvariants("flashLoan/onBuy");
    }
}
