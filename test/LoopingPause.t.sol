// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Looping} from "../contracts/Looping.sol";
import {MockERC20} from "./mocks/MockTokens.sol";

contract MockPoolCallback {
    function invoke(Looping looping, address debtAsset, uint256 amount, uint256 premium, bytes calldata params)
        external
    {
        looping.executeOperation(debtAsset, amount, premium, address(looping), params);
    }

    function getUserAccountData(address) external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, type(uint256).max);
    }
}

contract LoopingPauseTest is Test {
    Looping looping;
    MockPoolCallback pool;
    address swapper = address(0xB0B);

    function setUp() public {
        pool = new MockPoolCallback();
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        address[] memory swappers = new address[](1);
        swappers[0] = swapper;
        looping = new Looping(pools, swappers, address(this));
    }

    function test_opensPausedBlocksOpen() public {
        looping.setOpensPaused(true);
        address[] memory path = new address[](2);
        path[0] = address(1);
        path[1] = address(2);
        vm.expectRevert("opens paused");
        looping.openPosition(
            address(pool), swapper, address(1), address(2), 1, 1, 0, path, false, 0, block.timestamp + 1
        );
    }

    function test_invalidActionTypeReverts() public {
        MockERC20 debt = new MockERC20("Debt", "D");
        MockERC20 yield = new MockERC20("Yield", "Y");
        debt.mint(address(looping), 10 ether);
        bytes memory params = abi.encode(
            uint8(2),
            address(yield),
            swapper,
            new address[](2),
            uint256(1),
            uint256(0),
            address(this),
            uint256(1),
            uint256(block.timestamp + 1)
        );
        // _pendingFlashloanUser is the first scalar after Ownable/Ownable2Step/Reentrancy + 2 mappings + referral.
        vm.store(address(looping), bytes32(uint256(6)), bytes32(uint256(uint160(address(this)))));
        vm.expectRevert("invalid action");
        pool.invoke(looping, address(debt), 1 ether, 0, params);
    }
}
