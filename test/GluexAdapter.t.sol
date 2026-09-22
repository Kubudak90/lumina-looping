// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GluexAdapter} from "../contracts/periphery/GluexAdapter.sol";
import {MockERC20, MockWETH, MockGluex} from "./mocks/MockTokens.sol";

/// @dev Simulates StrategyManager setting a route for Looping to consume in the same tx.
contract RouteHarness {
    GluexAdapter public immutable adapter;

    constructor(GluexAdapter adapter_) {
        adapter = adapter_;
    }

    function setThenSwapAs(
        address executor,
        address tokenIn,
        address tokenOut,
        bytes calldata gluexData,
        uint256 amountIn,
        uint256 minOut,
        address[] calldata path,
        uint256 deadline
    ) external {
        adapter.setSwapPath(tokenIn, tokenOut, gluexData, amountIn, executor);
        (bool ok, bytes memory data) = executor.call(
            abi.encodeWithSelector(GluexExecutor.swap.selector, amountIn, minOut, path, executor, deadline)
        );
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }
}

contract GluexExecutor {
    GluexAdapter public immutable adapter;

    constructor(GluexAdapter adapter_) {
        adapter = adapter_;
    }

    function swap(uint256 amountIn, uint256 minOut, address[] calldata path, address to, uint256 deadline) external {
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, minOut, path, to, address(0), deadline);
    }
}

contract GluexAdapterTest is Test {
    GluexAdapter adapter;
    MockGluex gluex;
    MockWETH weth;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    RouteHarness setter;
    GluexExecutor looping;

    address owner = address(this);

    function setUp() public {
        gluex = new MockGluex();
        weth = new MockWETH();
        tokenIn = new MockERC20("Debt", "DEBT");
        tokenOut = new MockERC20("Yield", "YLD");
        adapter = new GluexAdapter(address(gluex), address(weth));
        setter = new RouteHarness(adapter);
        looping = new GluexExecutor(adapter);

        adapter.setAuthorizedCaller(address(setter), true);
        adapter.setAuthorizedCaller(address(looping), true);

        tokenIn.mint(address(looping), 1_000 ether);
        tokenOut.mint(address(gluex), 1_000 ether);
        vm.prank(address(looping));
        tokenIn.approve(address(adapter), type(uint256).max);
    }

    function _path() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);
    }

    function _gluexData(uint256 amountIn, uint256 amountOut) internal view returns (bytes memory) {
        return abi.encodeWithSelector(MockGluex.swap.selector, address(tokenIn), address(tokenOut), amountIn, amountOut);
    }

    function test_strategyManagerSetsRoute_loopingExecutes() public {
        uint256 amountIn = 10 ether;
        bytes memory data = _gluexData(amountIn, 9 ether);
        setter.setThenSwapAs(
            address(looping), address(tokenIn), address(tokenOut), data, amountIn, 9 ether, _path(), block.timestamp + 1
        );
        assertEq(tokenOut.balanceOf(address(looping)), 9 ether);
    }

    function test_revertIfExecutorMismatch() public {
        bytes memory data = _gluexData(1 ether, 1 ether);
        adapter.setAuthorizedCaller(address(this), true);
        adapter.setSwapPath(address(tokenIn), address(tokenOut), data, 1 ether, address(looping));
        address[] memory path = _path();
        vm.expectRevert("GluexAdapter: executor mismatch");
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 1 ether, path, address(this), address(0), block.timestamp + 1
        );
    }

    function test_revertIfExecutorNotAuthorized() public {
        bytes memory data = _gluexData(1 ether, 1 ether);
        vm.expectRevert("executor not authorized");
        adapter.setSwapPath(address(tokenIn), address(tokenOut), data, 1 ether, address(0xBEEF));
    }

    function test_revertOnReplay() public {
        uint256 amountIn = 1 ether;
        bytes memory data = _gluexData(amountIn, 1 ether);
        tokenIn.mint(address(looping), 10 ether);
        setter.setThenSwapAs(
            address(looping), address(tokenIn), address(tokenOut), data, amountIn, 1 ether, _path(), block.timestamp + 1
        );
        vm.prank(address(looping));
        vm.expectRevert("GluexAdapter: no executor recorded");
        looping.swap(amountIn, 1 ether, _path(), address(looping), block.timestamp + 1);
    }

    function test_nativeDustNotWrappedIntoSwapOutput() public {
        vm.deal(address(adapter), 1 ether);
        uint256 amountIn = 1 ether;
        bytes memory data = _gluexData(amountIn, 1 ether);
        setter.setThenSwapAs(
            address(looping), address(tokenIn), address(tokenOut), data, amountIn, 1 ether, _path(), block.timestamp + 1
        );
        assertEq(address(adapter).balance, 1 ether);
        assertEq(tokenOut.balanceOf(address(looping)), 1 ether);
    }

    function test_revertIfAmountInMismatch() public {
        bytes memory data = _gluexData(1 ether, 1 ether);
        adapter.setSwapPath(address(tokenIn), address(tokenOut), data, 1 ether, address(looping));
        vm.expectRevert("GluexAdapter: amount mismatch");
        looping.swap(5 ether, 1 ether, _path(), address(looping), block.timestamp + 1);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
    }

    function test_deadlineEqualToTimestampIsAllowed() public {
        uint256 amountIn = 1 ether;
        bytes memory data = _gluexData(amountIn, 1 ether);
        setter.setThenSwapAs(
            address(looping), address(tokenIn), address(tokenOut), data, amountIn, 1 ether, _path(), block.timestamp
        );
        assertEq(tokenOut.balanceOf(address(looping)), 1 ether);
    }
}
