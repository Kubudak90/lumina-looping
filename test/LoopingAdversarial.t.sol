// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Looping} from "../contracts/Looping.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockLendingPool, MockSwapper, MockFeeOnTransfer} from "./mocks/LoopingPool.sol";

contract LoopingAdversarialTest is Test {
    Looping looping;
    MockLendingPool pool;
    MockSwapper swapper;
    MockERC20 debt;
    MockERC20 yieldTok;
    MockERC20 aYield;
    MockERC20 aDebt;
    MockERC20 dYield;
    MockERC20 dDebt;

    address user = address(0xA11CE);

    function setUp() public {
        debt = new MockERC20("Debt", "DEBT");
        yieldTok = new MockERC20("Yield", "YLD");
        aYield = new MockERC20("aYield", "aYLD");
        aDebt = new MockERC20("aDebt", "aDEBT");
        dYield = new MockERC20("dYield", "dYLD");
        dDebt = new MockERC20("dDebt", "dDEBT");

        pool = new MockLendingPool();
        pool.registerReserve(address(debt), address(aDebt), address(dDebt));
        pool.registerReserve(address(yieldTok), address(aYield), address(dYield));

        swapper = new MockSwapper();
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        address[] memory swappers = new address[](1);
        swappers[0] = address(swapper);
        looping = new Looping(pools, swappers, address(this));

        debt.mint(address(pool), 1_000_000 ether);
        yieldTok.mint(address(pool), 1_000_000 ether);
        yieldTok.mint(address(swapper), 1_000_000 ether);
        debt.mint(address(swapper), 1_000_000 ether);

        debt.mint(user, 10_000 ether);
        vm.startPrank(user);
        debt.approve(address(looping), type(uint256).max);
        aYield.approve(address(looping), type(uint256).max);
        vm.stopPrank();
    }

    function _openPath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(debt);
        path[1] = address(yieldTok);
    }

    function _closePath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(yieldTok);
        path[1] = address(debt);
    }

    function _open(uint256 initialAmount, uint256 flashloanAmount, uint256 minOut) internal {
        vm.prank(user);
        looping.openPosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            initialAmount,
            flashloanAmount,
            minOut,
            _openPath(),
            false,
            0,
            block.timestamp + 600
        );
    }

    function test_openAndFullClose() public {
        _open(10 ether, 20 ether, 20 ether);
        assertEq(aYield.balanceOf(user), 20 ether);
        assertGt(dDebt.balanceOf(user), 0);

        uint256 flash = dDebt.balanceOf(user);
        vm.prank(user);
        looping.closePosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            flash,
            flash,
            _closePath(),
            type(uint256).max,
            block.timestamp + 600
        );
        assertEq(dDebt.balanceOf(user), 0);
        assertEq(aYield.balanceOf(user), 0);
    }

    function test_partialCloseAfterInterest() public {
        _open(10 ether, 20 ether, 20 ether);
        uint256 debtBefore = dDebt.balanceOf(user);
        pool.accrueDebt(address(debt), user, 1 ether);
        assertEq(dDebt.balanceOf(user), debtBefore + 1 ether);

        uint256 withdraw = aYield.balanceOf(user) / 2;
        vm.prank(user);
        looping.closePosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            debtBefore / 2,
            1,
            _closePath(),
            withdraw,
            block.timestamp + 600
        );
        assertLt(dDebt.balanceOf(user), debtBefore + 1 ether);
        assertEq(aYield.balanceOf(user), withdraw);
    }

    function test_flashPremiumIncreaseStillRepays() public {
        pool.setPremiumBps(9); // 9 bps, within typical buffers
        _open(10 ether, 20 ether, 1);
        uint256 flash = dDebt.balanceOf(user);
        vm.prank(user);
        looping.closePosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            flash,
            1,
            _closePath(),
            type(uint256).max,
            block.timestamp + 600
        );
        assertEq(dDebt.balanceOf(user), 0);
    }

    function test_minAmountOutProtectsOpen() public {
        swapper.setOutBps(9_000);
        vm.expectRevert("insufficient swap output");
        _open(10 ether, 20 ether, 20 ether);
    }

    function test_zeroOutputSwapReverts() public {
        swapper.setOutBps(0);
        vm.expectRevert("insufficient swap output");
        _open(10 ether, 20 ether, 1);
    }

    function test_preExistingDustIsNotStolen() public {
        debt.mint(address(looping), 7 ether);
        uint256 dust = debt.balanceOf(address(looping));
        _open(10 ether, 20 ether, 1);
        assertEq(debt.balanceOf(address(looping)), dust);
        assertEq(yieldTok.balanceOf(address(looping)), 0);
    }

    function test_maliciousSwapperCannotReenterOpen() public {
        swapper.configureReenter(looping, address(pool), address(debt), address(yieldTok));
        swapper.setReenterOpen(true);
        vm.expectRevert();
        _open(10 ether, 20 ether, 1);
    }

    function test_maliciousSwapperCannotSpoofCallback() public {
        swapper.configureReenter(looping, address(pool), address(debt), address(yieldTok));
        swapper.setReenterExecute(true);
        vm.expectRevert("msg.sender != pool");
        _open(10 ether, 20 ether, 1);
    }

    function test_unwhitelistedPoolCallbackReverts() public {
        MockLendingPool rogue = new MockLendingPool();
        vm.expectRevert("msg.sender != pool");
        vm.prank(address(rogue));
        looping.executeOperation(address(debt), 1 ether, 0, address(looping), "");
    }

    function test_userMismatchReverts() public {
        debt.mint(address(looping), 10 ether);
        bytes memory params = abi.encode(
            uint8(0),
            address(yieldTok),
            address(swapper),
            _openPath(),
            uint256(1),
            uint256(0),
            address(0xB0B),
            uint256(0),
            uint256(block.timestamp + 1)
        );
        vm.store(address(looping), bytes32(uint256(6)), bytes32(uint256(uint160(user))));
        vm.expectRevert("user mismatch");
        pool.flashLoanSimple(address(looping), address(debt), 1 ether, params, 0);
    }

    function test_rejectsZeroAmountsAndBadPath() public {
        vm.startPrank(user);
        vm.expectRevert("zero amount");
        looping.openPosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            0,
            1,
            0,
            _openPath(),
            false,
            0,
            block.timestamp + 1
        );
        vm.expectRevert("assets must differ");
        looping.openPosition(
            address(pool),
            address(swapper),
            address(debt),
            address(debt),
            1,
            1,
            0,
            _openPath(),
            false,
            0,
            block.timestamp + 1
        );
        address[] memory shortPath = new address[](1);
        shortPath[0] = address(debt);
        vm.expectRevert("invalid path");
        looping.openPosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            1,
            1,
            0,
            shortPath,
            false,
            0,
            block.timestamp + 1
        );
        vm.expectRevert("expired");
        looping.openPosition(
            address(pool),
            address(swapper),
            address(debt),
            address(yieldTok),
            1,
            1,
            0,
            _openPath(),
            false,
            0,
            block.timestamp - 1
        );
        vm.stopPrank();
    }

    function test_feeOnTransferDebtDoesNotPullForeignBalance() public {
        MockFeeOnTransfer fot = new MockFeeOnTransfer();
        fot.mint(user, 100 ether);
        fot.mint(address(pool), 1_000 ether);
        fot.mint(address(swapper), 1_000 ether);
        pool.registerReserve(address(fot), address(aDebt), address(dDebt));

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        address[] memory swappers = new address[](1);
        swappers[0] = address(swapper);
        Looping fotLooping = new Looping(pools, swappers, address(this));

        vm.startPrank(user);
        fot.approve(address(fotLooping), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(fot);
        path[1] = address(yieldTok);
        vm.expectRevert();
        fotLooping.openPosition(
            address(pool),
            address(swapper),
            address(fot),
            address(yieldTok),
            10 ether,
            20 ether,
            1,
            path,
            false,
            0,
            block.timestamp + 600
        );
        vm.stopPrank();
    }
}
