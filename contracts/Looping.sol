// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISwapper} from "./interfaces/ISwapper.sol";
import {IPool} from "./interfaces/IPool.sol";

/// @title Looping
/// @author LightLend
/// @notice Contract used to open leveraged positions on LightLend
contract Looping is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice mapping of whitelisted lending pools
    mapping(address => bool) public pools;
    /// @notice mapping of whitelisted swapper contracts
    mapping(address => bool) public swappers;
    /// @notice address that receives referral rewards from the swapper
    address public referralAddress;

    address private _pendingFlashloanUser;

    /// @notice When true, `openPosition` reverts. Closes remain available.
    bool public opensPaused;

    event OpensPaused(bool paused);
    event PositionOpened(
        address indexed user, address indexed pool, address debtAsset, address yieldAsset, uint256 flashloanAmount
    );
    event PositionClosed(
        address indexed user, address indexed pool, address debtAsset, address yieldAsset, uint256 flashloanAmount
    );
    event PoolUpdated(address indexed pool, bool approved);
    event SwapperUpdated(address indexed swapper, bool approved);
    event ReferralUpdated(address indexed referral);

    /// @param _pools array of whitelisted pools
    /// @param _swappers array of whitelisted swappers
    constructor(address[] memory _pools, address[] memory _swappers, address _owner) Ownable(_owner) {
        for (uint256 i = 0; i < _pools.length; i++) {
            pools[_pools[i]] = true;
        }
        for (uint256 i = 0; i < _swappers.length; i++) {
            swappers[_swappers[i]] = true;
        }

        referralAddress = _owner;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Public Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice function used to open a leveraged position using a flashloan
    /// @param _pool address of the pool we want to supply/borrow from
    /// @param _swapper address of the swapping contract (DEX) used to swap _debtAsset to _yieldAsset
    /// @param _debtAsset asset we want to borrow
    /// @param _yieldAsset asset we want to maximize the supply
    /// @param _initialAmount initial amount of the _debtAsset provided by the user
    /// @param _flashloanAmount amount of the _debtAsset we want to flashloan and then swap to _yieldAsset
    /// @param _minAmountOut minimum amount of _yieldAsset we can receive after swapping _debtAsset
    /// @param _path path used to swap from _debtAsset to _yieldAsset
    /// @param _startWithYield user provides _yieldAsset initially, otherwise we use _debtAsset
    /// @param _minInitialAmountOut minimum output when swapping from yield to debt token (if _startWithYield is true)
    /// @param _deadline deadline for swapping tokens
    function openPosition(
        address _pool,
        address _swapper,
        address _debtAsset,
        address _yieldAsset,
        uint256 _initialAmount,
        uint256 _flashloanAmount,
        uint256 _minAmountOut,
        address[] memory _path,
        bool _startWithYield,
        uint256 _minInitialAmountOut,
        uint256 _deadline
    ) external nonReentrant {
        require(!opensPaused, "opens paused");
        require(_initialAmount > 0 && _flashloanAmount > 0, "zero amount");
        require(block.timestamp <= _deadline, "expired");
        require(pools[_pool], "pool not allowed");
        require(_debtAsset != _yieldAsset, "assets must differ");
        require(_path.length >= 2, "invalid path");
        if (!_startWithYield) {
            require(_path[0] == _debtAsset, "path[0] != debtAsset");
            require(_path[_path.length - 1] == _yieldAsset, "path[last] != yieldAsset");
        } else {
            require(_path[0] == _yieldAsset, "path[0] != yieldAsset");
            require(_path[_path.length - 1] == _debtAsset, "path[last] != debtAsset");
        }

        if (_startWithYield) {
            //transfer initial _yieldAsset from user
            IERC20(_yieldAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);
            //swap from yieldAsset to debtAsset (path is already yield -> debt)
            _initialAmount = _swap(_swapper, _path, _initialAmount, _minInitialAmountOut, _deadline);
        } else {
            //transfer initial _debtAsset from user
            IERC20(_debtAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);
        }

        require(_flashloanAmount >= _initialAmount, "_flashloanAmount < _initialAmount");

        //use flashloan to borrow _debtAsset
        uint256 repaymentAmount = _flashloanAmount - _initialAmount;

        // Build the path for the flashloan callback (must be debt -> yield)
        address[] memory flashloanPath;
        if (_startWithYield) {
            // _path is yield -> debt, but the flashloan callback needs debt -> yield
            flashloanPath = new address[](_path.length);
            for (uint256 i = 0; i < _path.length; i++) {
                flashloanPath[i] = _path[_path.length - 1 - i];
            }
        } else {
            flashloanPath = _path;
        }

        bytes memory params = abi.encode(
            0, _yieldAsset, _swapper, flashloanPath, repaymentAmount, _minAmountOut, msg.sender, 0, _deadline
        );
        _pendingFlashloanUser = msg.sender;
        IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);
        _pendingFlashloanUser = address(0);

        emit PositionOpened(msg.sender, _pool, _debtAsset, _yieldAsset, _flashloanAmount);

        // Verify user's position health after open
        (,,,,, uint256 healthFactor) = IPool(_pool).getUserAccountData(msg.sender);
        require(healthFactor >= 1e18 || healthFactor == type(uint256).max, "position unhealthy after open");
    }

    /// @notice function used to close a leveraged position using a flashloan
    /// @param _pool address of the pool we want to supply/borrow from
    /// @param _swapper address of the swapping contract (DEX) used to swap _debtAsset to _yieldAsset
    /// @param _debtAsset asset we want to borrow
    /// @param _yieldAsset asset we want to maximize the supply
    /// @param _flashloanAmount amount of the _debtAsset we want to flashloan and then swap to _yieldAsset
    /// @param _minAmountOut minimum amount of _yieldAsset we can receive after swapping _debtAsset
    /// @param _path path used to swap from _debtAsset to _yieldAsset
    /// @param _withdrawAmount amount of yield token we need to withdraw to repay the flashloan (when swapped to _debtAsset, output should be > _flashloanAmount+premium)
    /// @param _deadline deadline for swapping tokens
    function closePosition(
        address _pool,
        address _swapper,
        address _debtAsset,
        address _yieldAsset,
        uint256 _flashloanAmount,
        uint256 _minAmountOut,
        address[] memory _path,
        uint256 _withdrawAmount,
        uint256 _deadline
    ) external nonReentrant {
        require(_flashloanAmount > 0 && _withdrawAmount > 0, "zero amount");
        require(block.timestamp <= _deadline, "expired");
        require(pools[_pool], "pool not allowed");
        require(_debtAsset != _yieldAsset, "assets must differ");
        require(_path.length >= 2, "invalid path");
        require(_path[0] == _yieldAsset, "path[0] != yieldAsset");
        require(_path[_path.length - 1] == _debtAsset, "path[last] != debtAsset");

        //use flashloan to borrow _debtAsset
        bytes memory params = abi.encode(
            1, _yieldAsset, _swapper, _path, _flashloanAmount, _minAmountOut, msg.sender, _withdrawAmount, _deadline
        );
        _pendingFlashloanUser = msg.sender;
        IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);
        _pendingFlashloanUser = address(0);

        emit PositionClosed(msg.sender, _pool, _debtAsset, _yieldAsset, _flashloanAmount);

        // Verify user's position health after close
        (,,,,, uint256 healthFactor) = IPool(_pool).getUserAccountData(msg.sender);
        require(healthFactor >= 1e18 || healthFactor == type(uint256).max, "position unhealthy after close");
    }

    /// @notice callback function called by pool contract during flashloan
    /// @param debtAsset asset we received from the flashloan
    /// @param amount amount of the debtAsset we received from the flashloan
    /// @param premium flashloan premium we must repay
    /// @param initiator address of the flashloan initiator
    /// @param params extra data passed to us by the pool contract
    function executeOperation(
        address debtAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(pools[msg.sender], "msg.sender != pool");
        require(initiator == address(this), "initiator != address(this)");

        //actionType: 0 = open position, 1 = close position
        (uint8 actionType, address yieldAsset, address _swapper,,,, address user,,) =
            abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));
        require(user == _pendingFlashloanUser, "user mismatch");
        require(swappers[_swapper], "callback: swapper not allowed");

        // Snapshot balances before position logic for delta-based refund
        uint256 debtBefore = IERC20(debtAsset).balanceOf(address(this));
        uint256 yieldBefore = IERC20(yieldAsset).balanceOf(address(this));

        if (actionType == 0) {
            require(!opensPaused, "opens paused");
            _executeOpenPosition(params, debtAsset, amount, premium);
        } else if (actionType == 1) {
            _executeClosePosition(params, debtAsset);
        } else {
            revert("invalid action");
        }

        //refund any leftover assets that would remain in the contract after flashloan repayment
        _refund(debtAsset, yieldAsset, amount, premium, user, debtBefore, yieldBefore);

        //approve pool so it can pull the funds to repay the flashloan
        IERC20(debtAsset).forceApprove(msg.sender, amount + premium);

        return true;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                   Internal Functions                     */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice open a leveraged positon using a flashloan
    /// @dev we take a flashloan of debtAsset, swap it to yieldAsset, supply yieldAsset, borrow debtAsset and repay the flashloan
    function _executeOpenPosition(bytes memory params, address debtAsset, uint256 amount, uint256 premium) internal {
        (
            , //action type
            address yieldAsset,
            address swapper,
            address[] memory path,
            uint256 repaymentAmount,
            uint256 minAmountOut,
            address user,
            ,
            uint256 deadline
        ) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));

        //swap flashloaned debt token to yield token
        uint256 yieldAmount = _swap(swapper, path, amount, minAmountOut, deadline);

        //supply yield tokens, note: msg.sender is now lending pool
        IERC20(yieldAsset).forceApprove(msg.sender, yieldAmount);
        IPool(msg.sender).supply(yieldAsset, yieldAmount, user, 0);

        //borrow debt token, so we have enough to repay the flashloan
        IPool(msg.sender).borrow(debtAsset, repaymentAmount + premium, 2, 0, user);
    }

    /// @dev we take a flashloan of debtAsset, repay the loan, withdraw the yieldAsset, swap yieldAsset to debtAsset, repay the flashloan
    function _executeClosePosition(bytes memory params, address debtAsset) internal {
        (
            , //action type
            address yieldAsset,
            address swapper,
            address[] memory path,
            uint256 repaymentAmount, //=flashloanAmount
            uint256 minAmountOut,
            address user,
            uint256 withdrawAmount,
            uint256 deadline
        ) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));

        IERC20 hYieldToken = IERC20(IPool(msg.sender).getReserveData(yieldAsset).aTokenAddress);

        //close full position if repaymentAmount == maxUint256
        if (withdrawAmount == type(uint256).max) {
            IERC20 debtDebtToken = IERC20(IPool(msg.sender).getReserveData(debtAsset).variableDebtTokenAddress);
            repaymentAmount = debtDebtToken.balanceOf(user);
            withdrawAmount = hYieldToken.balanceOf(user);
        }

        //repay debt, note: msg.sender is now the lending pool
        IERC20(debtAsset).forceApprove(msg.sender, repaymentAmount);
        IPool(msg.sender).repay(debtAsset, repaymentAmount, 2, user);

        //get address of the hToken and transfer it from user, so we can withdraw it
        hYieldToken.safeTransferFrom(user, address(this), withdrawAmount);

        //withdraw yield token
        uint256 actualWithdrawn = IPool(msg.sender).withdraw(yieldAsset, withdrawAmount, address(this));

        //swap yield token to debt token
        _swap(swapper, path, actualWithdrawn, minAmountOut, deadline);
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Helper Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice used to swap debt token to yield token
    /// @param swapper address of the dex contract
    /// @param path path we want to use when swapping
    /// @param minAmountOut minimum amount fo yield token we want to receive
    /// @return amountOut amount of output token received after the swap
    function _swap(address swapper, address[] memory path, uint256 amountToSwap, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256)
    {
        require(swappers[swapper], "swapper not allowed");

        IERC20(path[0]).forceApprove(swapper, amountToSwap);

        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(address(this));
        ISwapper(swapper).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap, minAmountOut, path, address(this), referralAddress, deadline
        );
        uint256 balanceAfter = IERC20(path[path.length - 1]).balanceOf(address(this));

        uint256 amountOut = balanceAfter - balanceBefore;
        require(amountOut >= minAmountOut, "insufficient swap output");

        IERC20(path[0]).forceApprove(swapper, 0);

        return amountOut;
    }

    /// @notice used to refund any tokens that would remain in the contract after the flashloan repayment
    /// @param debtAsset address of the token we want to borrow
    /// @param yieldAsset address of the token we want to supply
    /// @param amount amount of the debt token we owe from the flashloan
    /// @param premium amount of the premium we need to pay for the flashloan
    /// @param debtBefore debt asset balance snapshot taken after flashloan received (includes amount)
    /// @param yieldBefore yield asset balance snapshot before position logic
    function _refund(
        address debtAsset,
        address yieldAsset,
        uint256 amount,
        uint256 premium,
        address user,
        uint256 debtBefore,
        uint256 yieldBefore
    ) internal {
        uint256 debtAssetBalance = IERC20(debtAsset).balanceOf(address(this));
        uint256 yieldAssetBalance = IERC20(yieldAsset).balanceOf(address(this));

        // debtBefore includes the flashloan amount + any pre-existing balance.
        // Pre-existing balance = debtBefore - amount.
        // We must keep (amount + premium) for repayment and not touch pre-existing balance.
        // Refundable = debtAssetBalance - (amount + premium) - (debtBefore - amount)
        //            = debtAssetBalance - premium - debtBefore
        if (debtAssetBalance > debtBefore + premium) {
            IERC20(debtAsset).safeTransfer(user, debtAssetBalance - debtBefore - premium);
        }
        if (yieldAssetBalance > yieldBefore) {
            IERC20(yieldAsset).safeTransfer(user, yieldAssetBalance - yieldBefore);
        }
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Admin Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice used to add or remove pools from the whitelist
    function setPool(address _pool, bool _isApproved) external onlyOwner {
        require(_pool != address(0), "zero address");
        pools[_pool] = _isApproved;
        emit PoolUpdated(_pool, _isApproved);
    }

    /// @notice used to add or remove swappers from the whitelist
    function setSwapper(address _swapper, bool _isApproved) external onlyOwner {
        require(_swapper != address(0), "zero address");
        swappers[_swapper] = _isApproved;
        emit SwapperUpdated(_swapper, _isApproved);
    }

    /// @notice used to update the swapper referral address
    function setReferralAddress(address _newReferralAddress) external onlyOwner {
        require(_newReferralAddress != address(0), "zero address");
        referralAddress = _newReferralAddress;
        emit ReferralUpdated(_newReferralAddress);
    }

    /// @notice Pause new opens while leaving closes available.
    function setOpensPaused(bool _paused) external onlyOwner {
        opensPaused = _paused;
        emit OpensPaused(_paused);
    }

    /// @notice used to rescue stuck tokens that were sent to the contract by mistake
    function rescueTokens(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            (bool success,) = payable(msg.sender).call{value: _amount}("");
            require(success, "transfer failed");
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }
}
