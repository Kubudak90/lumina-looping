// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ILiquidSwap} from "../contracts/interfaces/ILiquidSwap.sol";
import {LiquidSwapAdapter} from "../contracts/periphery/LiquidSwapAdapter.sol";
import {VaultZapper} from "../contracts/periphery/wHlpZapper.sol";
import {MockERC20, MockWETH} from "./mocks/MockTokens.sol";

contract SwapDeadlineTest is Test {
    LiquidSwapAdapter adapter;
    VaultZapper zapper;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    function setUp() public {
        vm.warp(1_000);
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        adapter = new LiquidSwapAdapter(address(0xBEEF), address(new MockWETH()));
        zapper = new VaultZapper(address(0xBEEF), address(0xCAFE), address(0xD00D), address(tokenOut), address(tokenIn));
    }

    function _path() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);
    }

    function test_liquidSwapDeadlineEqualToTimestampIsAllowed() public {
        vm.expectRevert("Swapper: path not set");
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 1, _path(), address(this), address(0), block.timestamp
        );
    }

    function test_liquidSwapDeadlineInThePastReverts() public {
        vm.expectRevert("Swapper: expired");
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 1, _path(), address(this), address(0), block.timestamp - 1
        );
    }

    function test_zapperDeadlineEqualToTimestampIsAllowed() public {
        ILiquidSwap.Swap[][] memory hops = new ILiquidSwap.Swap[][](0);
        address[] memory tokens = new address[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zapper), 0, 1 ether)
        );
        zapper.zapIn(address(tokenIn), 1 ether, 1, 1, block.timestamp, tokens, hops, 1, 0);
    }

    function test_zapperDeadlineInThePastReverts() public {
        ILiquidSwap.Swap[][] memory hops = new ILiquidSwap.Swap[][](0);
        address[] memory tokens = new address[](0);
        vm.expectRevert("VaultZapper: expired");
        zapper.zapIn(address(tokenIn), 1 ether, 1, 1, block.timestamp - 1, tokens, hops, 1, 0);
    }

    function test_zapperGluexDeadlineEqualToTimestampIsAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zapper), 0, 1 ether)
        );
        zapper.zapInGluex(address(tokenIn), 1 ether, hex"01", 1, 1, block.timestamp);
    }

    function test_zapperGluexDeadlineInThePastReverts() public {
        vm.expectRevert("VaultZapper: expired");
        zapper.zapInGluex(address(tokenIn), 1 ether, hex"01", 1, 1, block.timestamp - 1);
    }
}
