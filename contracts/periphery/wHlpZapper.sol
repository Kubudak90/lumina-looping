// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidSwap} from "../interfaces/ILiquidSwap.sol";
import {IVaultDepositor} from "../interfaces/IWrappedHlpDepositor.sol";

/// @title VaultZapper
/// @author LightLend
/// @notice Contract used to swap tokens to deposit token before depositing them to vault
contract VaultZapper is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice liquid swap router
    ILiquidSwap public immutable liquidSwapRouter;

    /// @notice vault depositor
    IVaultDepositor public immutable depositor;

    /// @notice GlueX router address
    address public immutable gluex;

    /// @notice address of the vault deposit token
    address public immutable depositToken;

    /// @notice address of the vault share token
    address public immutable vaultToken;

    /// @notice `lightlend` bytes
    bytes public communityCode = hex"6c696768746c656e64";

    constructor(address _liquidSwapRouter, address _depositor, address _gluex, address _depositToken, address _vaultToken) Ownable(msg.sender) {
        require(_liquidSwapRouter != address(0), "zero liquidSwapRouter");
        require(_depositor != address(0), "zero depositor");
        require(_gluex != address(0), "zero gluex");
        require(_depositToken != address(0), "zero depositToken");
        require(_vaultToken != address(0), "zero vaultToken");
        liquidSwapRouter = ILiquidSwap(_liquidSwapRouter);
        depositor = IVaultDepositor(_depositor);
        gluex = _gluex;
        depositToken = _depositToken;
        vaultToken = _vaultToken;
    }

    /// @notice function used to swap from token X into deposit token and then deposit it into vault
    /// @param tokenIn token user is swapping to vault
    /// @param amountIn amount of the input token
    /// @param amountOutMin minimum deposit token amount after the swap
    /// @param minimumMint minimum vault shares received
    /// @param deadline swap deadline
    /// @param tokens list of tokens in LiquisSwap swap
    /// @param hops list of hops in LiquisSwap swap
    function zapIn(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 minimumMint,
        uint256 deadline,
        address[] calldata tokens,
        ILiquidSwap.Swap[][] calldata hops,
        uint256 expectedAmountOut,
        uint256 feeBps
    ) external nonReentrant returns (uint256 sharesReceived) {
        // Inclusive, matching Looping's `block.timestamp <= deadline`.
        require(block.timestamp <= deadline, "VaultZapper: expired");

        uint256 tokenInBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(liquidSwapRouter), amountIn);

        uint256 depositTokenBefore = IERC20(depositToken).balanceOf(address(this));

        liquidSwapRouter.executeSwaps(
            tokens,
            amountIn,
            amountOutMin,
            expectedAmountOut,
            hops,
            feeBps,
            owner() // feeRecipient
        );

        // Reset residual approval after swap
        IERC20(tokenIn).forceApprove(address(liquidSwapRouter), 0);

        // Calculate deposit token delta BEFORE tokenIn refund (critical when tokenIn == depositToken)
        uint256 balanceOut = IERC20(depositToken).balanceOf(address(this)) - depositTokenBefore;

        // Refund only the delta of residual tokenIn (not pre-existing dust)
        uint256 tokenInAfter = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInAfter > tokenInBefore) {
            IERC20(tokenIn).safeTransfer(msg.sender, tokenInAfter - tokenInBefore);
        }
        require(
            balanceOut >= amountOutMin,
            "VaultZapper: minAmountOut > balanceOut"
        );

        IERC20(depositToken).forceApprove(address(depositor), balanceOut);
        uint256 sharesBefore = IERC20(vaultToken).balanceOf(msg.sender);
        depositor.deposit(
            depositToken,
            balanceOut,
            minimumMint,
            msg.sender,
            communityCode
        );
        sharesReceived = IERC20(vaultToken).balanceOf(msg.sender) - sharesBefore;
    }

    /// @notice function used to swap from token X into deposit token via Gluex and then deposit it into vault
    /// @param tokenIn The token to swap from
    /// @param amountIn The amount of tokenIn to swap
    /// @param gluexData The encoded calldata for the call to be executed by the GlueX contract
    /// @param amountOutMin The minimum amount of deposit token to receive
    /// @param minimumMint The minimum amount of vault shares to receive
    /// @param deadline The deadline for the transaction
    function zapInGluex(
        address tokenIn,
        uint256 amountIn,
        bytes calldata gluexData,
        uint256 amountOutMin,
        uint256 minimumMint,
        uint256 deadline
    ) external payable nonReentrant {
        // Inclusive, matching Looping's `block.timestamp <= deadline`.
        require(block.timestamp <= deadline, "VaultZapper: expired");

        if (tokenIn == address(0)) {
            require(
                msg.value == amountIn,
                "VaultZapper: msg.value must match amountIn for ETH zap"
            );
        } else {
            require(
                msg.value == 0,
                "VaultZapper: msg.value must be 0 for token zap"
            );
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            IERC20(tokenIn).forceApprove(address(gluex), amountIn);
        }

        uint256 balanceBefore = IERC20(depositToken).balanceOf(address(this));
        uint256 ethBefore = address(this).balance - msg.value;

        (bool success, ) = gluex.call{value: msg.value}(gluexData);
        require(success, "VaultZapper: gluex swap failed");

        if (tokenIn != address(0)) {
            IERC20(tokenIn).forceApprove(address(gluex), 0);
        }

        uint256 receivedDepositToken = IERC20(depositToken).balanceOf(address(this)) -
            balanceBefore;
        require(
            receivedDepositToken >= amountOutMin,
            "VaultZapper: insufficient amount out"
        );

        IERC20(depositToken).forceApprove(address(depositor), receivedDepositToken);
        depositor.deposit(
            depositToken,
            receivedDepositToken,
            minimumMint,
            msg.sender,
            communityCode
        );

        // Refund any remaining native ETH to user (delta only)
        uint256 remainingEth = address(this).balance - ethBefore;
        if (remainingEth > 0) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: remainingEth}("");
            require(refundSuccess, "ETH refund failed");
        }
    }

    /// @notice used to rescue stuck tokens that were sent to the contract by mistake
    function rescueTokens(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            require(success, "transfer failed");
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
