// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DataTypes} from "../../contracts/interfaces/DataTypes.sol";
import {Looping} from "../../contracts/Looping.sol";
import {ISwapper} from "../../contracts/interfaces/ISwapper.sol";
import {MockERC20} from "./MockTokens.sol";

interface IFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

/// @dev Minimal Aave-like pool used to drive Looping open/close.
contract MockLendingPool {
    mapping(address => address) public aToken;
    mapping(address => address) public debtToken;
    uint256 public premiumBps = 5; // 5 bps, Aave default
    uint256 public healthFactor = type(uint256).max;

    function setPremiumBps(uint256 bps) external {
        premiumBps = bps;
    }

    function setHealthFactor(uint256 hf) external {
        healthFactor = hf;
    }

    function registerReserve(address asset, address aToken_, address debtToken_) external {
        aToken[asset] = aToken_;
        debtToken[asset] = debtToken_;
    }

    function accrueDebt(address asset, address user, uint256 extra) external {
        MockERC20(debtToken[asset]).mint(user, extra);
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        IERC20(asset).transfer(receiver, amount);
        uint256 premium = (amount * premiumBps) / 10_000;
        require(
            IFlashLoanSimpleReceiver(receiver).executeOperation(asset, amount, premium, receiver, params),
            "callback failed"
        );
        IERC20(asset).transferFrom(receiver, address(this), amount + premium);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockERC20(aToken[asset]).mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        MockERC20(debtToken[asset]).mint(onBehalfOf, amount);
        IERC20(asset).transfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockERC20(debtToken[asset]).burn(onBehalfOf, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockERC20(aToken[asset]).burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, healthFactor);
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory data) {
        data.aTokenAddress = aToken[asset];
        data.variableDebtTokenAddress = debtToken[asset];
    }
}

contract MockSwapper is ISwapper {
    uint256 public outBps = 10_000;
    bool public reenterOpen;
    bool public reenterExecute;
    Looping public looping;
    address public pool;
    address public debt;
    address public yieldTok;

    function setOutBps(uint256 bps) external {
        outBps = bps;
    }

    function configureReenter(Looping looping_, address pool_, address debt_, address yieldTok_) external {
        looping = looping_;
        pool = pool_;
        debt = debt_;
        yieldTok = yieldTok_;
    }

    function setReenterOpen(bool v) external {
        reenterOpen = v;
    }

    function setReenterExecute(bool v) external {
        reenterExecute = v;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        address,
        uint256
    ) external {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        if (reenterOpen) {
            address[] memory p = new address[](2);
            p[0] = debt;
            p[1] = yieldTok;
            looping.openPosition(pool, address(this), debt, yieldTok, 1, 1, 0, p, false, 0, block.timestamp + 1);
        }
        if (reenterExecute) {
            looping.executeOperation(debt, 1, 0, address(looping), "");
        }
        uint256 out = (amountIn * outBps) / 10_000;
        if (out > 0) {
            IERC20(path[path.length - 1]).transfer(to, out);
        }
    }
}

contract MockFeeOnTransfer is MockERC20 {
    address public constant FEE_SINK = address(0xFEE);

    constructor() MockERC20("Fee", "FEE") {}

    function _take(address from, address to, uint256 amount) internal {
        uint256 fee = amount / 100;
        _transfer(from, to, amount - fee);
        if (fee > 0) _transfer(from, FEE_SINK, fee);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _take(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _take(from, to, amount);
        return true;
    }
}
