// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    Arcadia asset-managers — PoC for the `Slipstream._unstake` overwrite lead
////////////////////////////////////////////////////////////////////////////

WHAT THIS TESTS
---------------
src/cl-managers/base/Slipstream.sol:_unstake() contains:

    if (rewards > 0) {                               // rewards = IStakedSlipstream.burn(id)
        if (balances.length == 3) balances[2] = rewards;     // <-- OVERWRITE (line ~276)
        else if (position.tokens[0] == REWARD_TOKEN) balances[0] += rewards;
        else balances[1] += rewards;
    }

`_claim()` runs BEFORE `_unstake()` in the rebalance/compound flow and does
`balances[2] += claimReward(id)`. The concern: if `burn(id)` also returns a
non-zero AERO amount in the SAME tx, the `=` (overwrite) discards the amount
`_claim()` already credited, stranding that AERO on the manager (owner-skimmable)
=> a single-user, atomic, permanent loss of yield.

THE CLAIM UNDER TEST
--------------------
The deployed StakedSlipstreamAM (0x1Dc7A0...67bF1) computes rewards as:

    claimReward(id): gauge.getReward(id);   rewards = AERO.balanceOf(address(this)); transfer out
    burn(id):        gauge.withdraw(id);    rewards = AERO.balanceOf(address(this)); transfer out

So after claimReward() drains the gauge AND transfers the AM's full AERO balance
out, a burn() in the same tx sees `earned == 0` (block.timestamp unchanged) and
`AERO.balanceOf(AM) == 0`  =>  burn() returns 0  =>  the `if (rewards > 0)` guard
in `_unstake` is FALSE  =>  the overwrite never executes  =>  no loss.

This test proves that empirically against the live contract:
  - asserts claimReward() returns > 0
  - asserts burn() in the same tx returns == 0
  - replicates the exact `_unstake` branch and asserts balances[2] is preserved.

If burn() ever returns > 0 here, the bug is LIVE and this test FAILS loudly.

HOW TO RUN
----------
  export BASE_RPC_URL=<your base mainnet rpc>
  export POSITION_ID=<a tokenId currently staked in the StakedSlipstreamAM>
  # optional: export FORK_BLOCK=<block>
  forge test --match-path test/BurnAfterClaimReward.fork.t.sol -vvv

HOW TO FIND A LIVE POSITION_ID (mint events of the AM are ERC721 Transfers from 0x0):
  cast logs --rpc-url $BASE_RPC_URL \
    --address 0x1Dc7A0f5336F52724B650E39174cfcbbEdD67bF1 \
    'Transfer(address,address,uint256)' \
    --from-block <recent> --to-block latest \
    'topic1=0x0000000000000000000000000000000000000000000000000000000000000000'
  # take topic3 (the tokenId) of any position still owned (ownerOf != 0).
*/

interface Vm {
    function createSelectFork(string calldata urlOrAlias) external returns (uint256);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envString(string calldata name) external view returns (string memory);
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function label(address, string calldata) external;
}

interface IStakedSlipstreamAM {
    function ownerOf(uint256 id) external view returns (address);
    function rewardOf(uint256 positionId) external view returns (uint256 rewards);
    function claimReward(uint256 positionId) external returns (uint256 rewards);
    function burn(uint256 positionId) external returns (uint256 rewards);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract BurnAfterClaimReward_Fork_Test {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Arcadia deployments on Base (docs.arcadia.finance).
    address internal constant STAKED_SLIPSTREAM_AM = 0x1Dc7A0f5336F52724B650E39174cfcbbEdD67bF1;
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    IStakedSlipstreamAM internal stakedAM = IStakedSlipstreamAM(STAKED_SLIPSTREAM_AM);
    IERC20 internal aero = IERC20(AERO);

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        vm.label(STAKED_SLIPSTREAM_AM, "StakedSlipstreamAM");
        vm.label(AERO, "AERO");
    }

    function test_burnReturnsZeroAfterClaimReward_unstakeOverwriteUnreachable() public {
        uint256 positionId = vm.envOr("POSITION_ID", uint256(0));
        require(positionId != 0, "set POSITION_ID env to a live staked Slipstream position id");

        address owner = stakedAM.ownerOf(positionId);
        require(owner != address(0), "position not staked / wrong POSITION_ID");

        // Let AERO accrue in the gauge. NOTE: warp advances the fork clock between
        // calls, NOT within a single tx — claimReward+burn below still execute atomically.
        vm.warp(block.timestamp + 7 days);

        uint256 pending = stakedAM.rewardOf(positionId);
        require(pending > 0, "no pending AERO; choose an active-gauge position");

        vm.startPrank(owner);

        // (1) _claim() -> claimReward(): harvests the gauge and moves all AERO out of the AM.
        uint256 r1 = stakedAM.claimReward(positionId);
        require(r1 > 0, "claimReward returned 0");

        // (2) _unstake() -> burn() in the SAME tx: gauge already drained this block.
        uint256 r2 = stakedAM.burn(positionId);

        vm.stopPrank();

        // ---- CORE RESULT -------------------------------------------------------
        // burn() returns 0 after claimReward() in the same tx.
        // If this assertion fails (r2 > 0), the _unstake overwrite IS reachable and
        // the lead would be a confirmed finding.
        require(r2 == 0, "LIVE BUG: burn() returned >0 after claimReward() in same tx");

        // ---- Replicate Slipstream._unstake() branch exactly --------------------
        // State after _claim(): balances[2] holds the claimReward amount (r1).
        uint256[3] memory balances;
        balances[2] = r1;

        uint256 rewards = r2; // == burn() return value used by _unstake()
        if (rewards > 0) {
            balances[2] = rewards; // line ~276 overwrite — NOT executed because r2 == 0
        }

        // No discard: the claimReward amount survives.
        require(balances[2] == r1, "REGRESSION: balances[2] overwritten, reward discarded");
        // Tracked == actually received by the manager during _claim + _unstake.
        require(balances[2] == r1 + r2, "tracked reward != received reward");
    }
}
