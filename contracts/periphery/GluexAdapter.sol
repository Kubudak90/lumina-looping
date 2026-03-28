// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWETH} from "../interfaces/IWrappedHype.sol";

/// @title GluexAdapter
/// @author LightLend
/// @notice Contract used to swap tokens on GlueX, using a uniswap-like interface for integration.
/// @dev Swap relies on pre-setting swap calldata
contract GluexAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice GlueX router address
    address public immutable gluex;

    /// @notice wrapped ETH
    IWETH public immutable WETH;

    /// @notice owner of the contract
    address public owner;
    /// @notice mapping of authorized callers
    mapping(address => bool) public authorizedCallers;

    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner, "not authorized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _gluex, address _weth) {
        require(_gluex != address(0), "zero gluex");
        require(_weth != address(0), "zero weth");
        gluex = _gluex;
        WETH = IWETH(_weth);
        owner = msg.sender;
    }

    /// @notice set authorized caller status
    function setAuthorizedCaller(address _caller, bool _status) external onlyOwner {
        authorizedCallers[_caller] = _status;
    }

    /// @notice Pending owner for two-step ownership transfer
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Initiate ownership transfer
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "zero address");
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    /// @notice Accept pending ownership
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice used to preset the swap route calldata, which will then be used in the swap function.
    /// @dev This must be called in the same transaction as the swap.
    /// @param tokenIn The input token of the swap.
    /// @param tokenOut The output token of the swap.
    /// @param gluexData The raw calldata to be sent to the GlueX router to perform the swap.
    function setSwapPath(
        address tokenIn,
        address tokenOut,
        bytes calldata gluexData
    ) external onlyAuthorized {
        // Generate unique slots for this token pair in transient storage
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));
        bytes32 callerSlot = keccak256(abi.encodePacked(baseSlot, "caller"));

        assembly {
            tstore(blockSlot, number())
            tstore(callerSlot, caller())
            tstore(baseSlot, gluexData.length)
        }
        
        // Store data in chunks of 32 bytes
        uint256 length = gluexData.length;
        for (uint256 i = 0; i < length; i += 32) {
            bytes32 chunk;
            assembly {
                chunk := calldataload(add(gluexData.offset, i))
                tstore(add(baseSlot, add(1, div(i, 32))), chunk)
            }
        }
    }

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    /// @dev The function signature is kept identical to a standard Uniswap V2 router for compatibility.
    /// It relies on `setSwapPath` being called in the same transaction to provide the swap calldata.
    /// @param amountIn The amount of tokens to be swapped.
    /// @param amountOutMin The minimum amount of output tokens that must be received.
    /// @param path An array of token addresses. `path[0]` is the input token, `path[path.length - 1]` is the output token.
    /// @param to The recipient of the output tokens.
    /// @param deadline The deadline for the transaction.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer; unused in this implementation
        uint deadline
    ) external nonReentrant onlyAuthorized {
        require(block.timestamp < deadline, "GluexAdapter: expired");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // Load and validate swap data from transient storage
        bytes memory gluexCallData = _loadSwapData(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(gluex), amountIn);

        uint256 balanceOutBefore = IERC20(tokenOut).balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;

        (bool success, ) = gluex.call(gluexCallData);
        require(success, "GluexAdapter: gluex swap failed");

        IERC20(tokenIn).forceApprove(address(gluex), 0);

        // Only wrap native balance delta (not pre-existing dust)
        if (address(this).balance > nativeBefore) {
            WETH.deposit{value: address(this).balance - nativeBefore}();
        }

        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this)) - balanceOutBefore;
        require(
            balanceOut >= amountOutMin,
            "GluexAdapter: minAmountOut > balanceOut"
        );
        IERC20(tokenOut).safeTransfer(to, balanceOut);
    }

    /// @notice Internal function to load swap data from transient storage
    /// @param tokenIn The input token
    /// @param tokenOut The output token
    /// @return gluexCallData The swap calldata
    function _loadSwapData(address tokenIn, address tokenOut) internal returns (bytes memory) {
        // Generate unique slots for this token pair in transient storage
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));
        bytes32 callerSlot = keccak256(abi.encodePacked(baseSlot, "caller"));

        uint256 storedBlock;
        assembly {
            storedBlock := tload(blockSlot)
        }
        require(
            storedBlock == block.number,
            "GluexAdapter: path not set in this block"
        );

        address storedCaller;
        assembly {
            storedCaller := tload(callerSlot)
        }
        require(storedCaller != address(0), "GluexAdapter: no caller recorded");
        require(storedCaller == msg.sender, "GluexAdapter: caller mismatch");

        // Load data length from transient storage
        uint256 dataLength;
        assembly {
            dataLength := tload(baseSlot)
        }
        require(dataLength > 0, "GluexAdapter: path data is empty");
        
        // Reconstruct the calldata from transient storage
        bytes memory gluexCallData = new bytes(dataLength);
        for (uint256 i = 0; i < dataLength; i += 32) {
            bytes32 chunk;
            assembly {
                chunk := tload(add(baseSlot, add(1, div(i, 32))))
            }
            
            assembly {
                mstore(add(add(gluexCallData, 0x20), i), chunk)
            }
        }
        
        return gluexCallData;
    }

    /// @notice Gets the stored GlueX calldata for a given token pair from transient storage.
    /// @dev Only works within the same transaction where setSwapPath was called
    function getSwapRoute(
        address tokenIn,
        address tokenOut
    ) external returns (bytes memory) {
        return _loadSwapData(tokenIn, tokenOut);
    }

    /// @notice rescue stuck tokens from the contract
    function rescueTokens(address _token, address _to) external onlyOwner {
        require(_to != address(0), "zero address");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(_token).safeTransfer(_to, balance);
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = _to.call{value: ethBalance}("");
            require(success, "ETH transfer failed");
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
