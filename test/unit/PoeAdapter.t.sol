// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MRC15Adapter} from "../../src/base/MRC15Adapter.sol";
import {PoeAdapter} from "../../src/adapters/PoeAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoePool} from "../mocks/MockPoePool.sol";

contract PoeAdapterUnitTest is Test {
    MockERC20 internal tokenX;
    MockERC20 internal tokenY;
    MockPoePool internal pool;
    PoeAdapter internal adapter;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);
        pool = new MockPoePool(address(tokenX), address(tokenY), 2, 1);
        adapter = new PoeAdapter(address(pool));

        tokenX.mint(user, 1_000_000 ether);
        tokenY.mint(user, 1_000_000 ether);
        tokenX.mint(address(pool), 2_000_000 ether);
        tokenY.mint(address(pool), 2_000_000 ether);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) =
            address(adapter).staticcall(abi.encodeCall(adapter.getAmountOut, (true, 3 ether, bytes(""))));
        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, 6 ether);
        assertEq(swapData.length, 0);
    }

    function test_swapPullsExactInputAndCreditsRecipient() public {
        uint256 amountIn = 3 ether;
        vm.startPrank(user);
        tokenX.approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(true, recipient, amountIn, 6 ether, block.timestamp, bytes(""));
        vm.stopPrank();

        assertEq(amountOut, 6 ether);
        assertEq(tokenX.balanceOf(user), 1_000_000 ether - amountIn);
        assertEq(tokenY.balanceOf(recipient), amountOut);
        assertEq(tokenX.balanceOf(address(adapter)), 0);
        assertEq(tokenY.balanceOf(address(adapter)), 0);
    }

    function test_swapDoesNotConsumePreexistingAdapterBalance() public {
        tokenX.mint(address(adapter), 7 ether);
        uint256 amountIn = 2 ether;

        vm.startPrank(user);
        tokenX.approve(address(adapter), amountIn);
        adapter.swap(true, recipient, amountIn, 0, block.timestamp, bytes(""));
        vm.stopPrank();

        assertEq(tokenX.balanceOf(address(adapter)), 7 ether);
    }

    function test_swapSupportsReverseDirection() public {
        uint256 amountIn = 4 ether;
        vm.startPrank(user);
        tokenY.approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(false, recipient, amountIn, 8 ether, block.timestamp, bytes(""));
        vm.stopPrank();

        assertEq(amountOut, 8 ether);
        assertEq(tokenX.balanceOf(recipient), amountOut);
    }

    function test_revertsAfterDeadline() public {
        vm.warp(100);
        vm.startPrank(user);
        tokenX.approve(address(adapter), 1 ether);
        vm.expectRevert(MRC15Adapter.DeadlineExpired.selector);
        adapter.swap(true, recipient, 1 ether, 0, 99, bytes(""));
        vm.stopPrank();
    }

    function test_revertsWhenRecipientGetsLessThanMinimum() public {
        vm.startPrank(user);
        tokenX.approve(address(adapter), 1 ether);
        vm.expectRevert(MRC15Adapter.SlippageExceeded.selector);
        adapter.swap(true, recipient, 1 ether, 2 ether + 1, block.timestamp, bytes(""));
        vm.stopPrank();
    }
}
