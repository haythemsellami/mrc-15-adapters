// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CloberAdapter} from "../../src/adapters/CloberAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    MockCloberBookManager,
    MockCloberBookViewer,
    MockCloberController,
    MockWrappedNative
} from "../mocks/MockClober.sol";

contract CloberAdapterUnitTest is Test {
    uint192 internal constant WNATIVE_FOR_USDC = 1;
    uint192 internal constant USDC_FOR_WNATIVE = 2;

    MockWrappedNative internal wrappedNative;
    MockERC20 internal usdc;
    MockCloberBookViewer internal viewer;
    MockCloberController internal controller;
    CloberAdapter internal adapter;

    address internal recipient = makeAddr("recipient");

    function setUp() public {
        wrappedNative = new MockWrappedNative();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockCloberBookManager manager = new MockCloberBookManager();
        viewer = new MockCloberBookViewer(address(manager));
        controller = new MockCloberController(address(manager));

        manager.setBook(WNATIVE_FOR_USDC, address(0), address(usdc), 1);
        manager.setBook(USDC_FOR_WNATIVE, address(usdc), address(0), 1);
        viewer.setRate(WNATIVE_FOR_USDC, 2, 1);
        viewer.setRate(USDC_FOR_WNATIVE, 1, 2);
        controller.setRate(WNATIVE_FOR_USDC, 2, 1);
        controller.setRate(USDC_FOR_WNATIVE, 1, 2);

        adapter = new CloberAdapter(
            address(manager),
            address(viewer),
            address(controller),
            address(wrappedNative),
            address(wrappedNative),
            address(usdc),
            WNATIVE_FOR_USDC,
            USDC_FOR_WNATIVE
        );

        vm.deal(address(this), 100 ether);
        vm.deal(address(controller), 100 ether);
        usdc.mint(address(controller), 1_000_000 ether);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) =
            address(adapter).staticcall(abi.encodeCall(adapter.getAmountOut, (true, 3 ether, bytes(""))));
        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, 6 ether);
        assertEq(swapData.length, 0);
    }

    function test_unwrapsInputAndForwardsErc20Output() public {
        uint256 amountIn = 3 ether;
        wrappedNative.deposit{value: amountIn}();
        wrappedNative.approve(address(adapter), amountIn);

        (uint256 quote, bytes memory swapData) = adapter.getAmountOut(true, amountIn, bytes(""));
        uint256 amountOut = adapter.swap(true, recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(usdc.balanceOf(recipient), quote);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function test_wrapsNativeOutputAndForwardsWrappedToken() public {
        uint256 amountIn = 4 ether;
        usdc.mint(address(this), amountIn);
        usdc.approve(address(adapter), amountIn);

        (uint256 quote, bytes memory swapData) = adapter.getAmountOut(false, amountIn, bytes(""));
        uint256 amountOut = adapter.swap(false, recipient, amountIn, quote, block.timestamp, swapData);

        assertEq(amountOut, quote);
        assertEq(wrappedNative.balanceOf(recipient), quote);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }

    function test_rejectsPartialExactInputQuote() public {
        viewer.setPartialFill(true);
        vm.expectRevert(CloberAdapter.IncompleteFill.selector);
        adapter.getAmountOut(true, 1 ether, bytes(""));
    }
}
