// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StrategyManager} from "../contracts/StrategyManager.sol";

contract StrategyManagerTest is Test {
    StrategyManager manager;

    function setUp() public {
        manager = new StrategyManager(address(this), address(1), address(2), address(3));
    }

    function test_rejectsZeroTargetAndEmptyBatch() public {
        vm.expectRevert("zero target");
        manager.executeCall(address(0), 0, "", false);

        StrategyManager.Call[] memory empty;
        vm.expectRevert("invalid calls");
        manager.executeMultiCall(empty);

        StrategyManager.Call[] memory tooMany = new StrategyManager.Call[](17);
        vm.expectRevert("invalid calls");
        manager.executeMultiCall(tooMany);
    }

    function test_allowRevertEmitsFailureNotSuccess() public {
        StrategyManager.Call[] memory calls = new StrategyManager.Call[](1);
        calls[0] = StrategyManager.Call({
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("iRevert()"),
            allowRevert: true
        });
        vm.expectEmit(true, false, false, true);
        emit StrategyManager.CallFailed(
            address(this), 0, calls[0].data, abi.encodeWithSignature("Error(string)", "boom")
        );
        manager.executeMultiCall(calls);
    }

    function iRevert() external pure {
        revert("boom");
    }
}
