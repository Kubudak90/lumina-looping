// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPool} from "./interfaces/IPool.sol";

/// @title StrategyManager
/// @notice Single-user strategy account for managing leveraged lending positions.
/// @dev WARNING: This contract allows arbitrary external calls via executeCall/executeMultiCall.
/// It is designed for single-user strategy accounts where the owner is the sole beneficiary.
/// Do NOT use this contract for multi-user or shared fund management.
/// @author LightLend
contract StrategyManager is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice variables are used on the UI to identify which StrategyManager is used for certain pairs of assets
    address public immutable pool;
    address public immutable yieldAsset;
    address public immutable debtAsset;

    uint256 public constant MAX_CALLS = 16;

    struct Call {
        address target;
        uint256 value;
        bytes data;
        bool allowRevert;
    }

    /// @notice Emitted when an external call succeeds
    event CallExecuted(address indexed target, uint256 value, bytes data, bytes returnData);
    /// @notice Emitted when an external call fails and `allowRevert` is true
    event CallFailed(address indexed target, uint256 value, bytes data, bytes returnData);

    constructor(address _owner, address _pool, address _yieldAsset, address _debtAsset) Ownable(_owner) {
        pool = _pool;
        yieldAsset = _yieldAsset;
        debtAsset = _debtAsset;
    }

    function executeCall(address target, uint256 value, bytes memory data, bool allowRevert)
        public
        payable
        onlyOwner
        nonReentrant
        returns (bytes memory)
    {
        require(target != address(0), "zero target");
        return _executeCall(target, value, data, allowRevert);
    }

    function executeMultiCall(Call[] memory calls) external payable onlyOwner nonReentrant {
        require(calls.length > 0 && calls.length <= MAX_CALLS, "invalid calls");
        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].target != address(0), "zero target");
            _executeCall(calls[i].target, calls[i].value, calls[i].data, calls[i].allowRevert);
        }
    }

    function _executeCall(address target, uint256 value, bytes memory data, bool allowRevert)
        internal
        returns (bytes memory)
    {
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) {
            if (!allowRevert) _revertWithReason(returnData);
            emit CallFailed(target, value, data, returnData);
            return returnData;
        }
        emit CallExecuted(target, value, data, returnData);
        return returnData;
    }

    function cleanOutTokens(address[] memory tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) {
                (bool sent,) = owner().call{value: address(this).balance}("");
                require(sent, "cleanOutTokens: failed to send native");
            } else {
                uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
                IERC20(tokens[i]).safeTransfer(owner(), balance);
            }
        }
    }

    function withdrawAllFromPool(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            IPool(pool).withdraw(tokens[i], type(uint256).max, owner());
        }
    }

    function _revertWithReason(bytes memory returndata) internal pure {
        if (returndata.length > 0) {
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert("execution failed");
        }
    }
}
