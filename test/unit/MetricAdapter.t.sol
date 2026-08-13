// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MetricAdapter} from "../../src/adapters/MetricAdapter.sol";
import {MRC15Adapter} from "../../src/base/MRC15Adapter.sol";
import {IPropAMMRouter} from "../../src/interfaces/IPropAMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    MockMalformedMetricPool,
    MockMetricPool,
    MockMetricPriceProvider,
    MockMetricRouter
} from "../mocks/MockMetric.sol";

contract MetricAdapterUnitTest is Test {
    uint128 private constant BID_PRICE_X64 = 1000;
    uint128 private constant ASK_PRICE_X64 = 2000;
    uint256 private constant AMOUNT_IN = 10 ether;
    uint256 private constant AMOUNT_OUT = 19 ether;
    uint256 private constant DEADLINE = 1_000_000;

    address private user = makeAddr("user");
    address private recipient = makeAddr("recipient");
    MockERC20 private token0;
    MockERC20 private token1;
    MockMetricPriceProvider private priceProvider;
    MockMetricPool private pool;
    MockMetricRouter private router;
    MetricAdapter private adapter;

    function setUp() public {
        token0 = new MockERC20("Token 0", "T0", 18);
        token1 = new MockERC20("Token 1", "T1", 18);
        priceProvider = new MockMetricPriceProvider(BID_PRICE_X64, ASK_PRICE_X64);
        pool = new MockMetricPool(address(priceProvider), address(token0), address(token1));
        router = new MockMetricRouter();
        adapter = new MetricAdapter(address(router), address(pool));

        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token0.mint(address(router), 1000 ether);
        token1.mint(address(router), 1000 ether);

        vm.startPrank(user);
        token0.approve(address(adapter), type(uint256).max);
        token1.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_constructorStoresValidatedConfiguration() public view {
        assertEq(adapter.router(), address(router));
        assertEq(adapter.pool(), address(pool));
        assertEq(adapter.priceProvider(), address(priceProvider));
        assertEq(adapter.token0(), address(token0));
        assertEq(adapter.token1(), address(token1));
    }

    function test_constructorRejectsInvalidDependencies() public {
        vm.expectRevert(MetricAdapter.InvalidRouter.selector);
        new MetricAdapter(makeAddr("invalid router"), address(pool));

        vm.expectRevert(MetricAdapter.InvalidPool.selector);
        new MetricAdapter(address(router), makeAddr("invalid pool"));

        MockMalformedMetricPool malformedPool = new MockMalformedMetricPool();
        vm.expectRevert(MetricAdapter.InvalidPool.selector);
        new MetricAdapter(address(router), address(malformedPool));
    }

    function test_getAmountOutUsesOrdinaryCallForStatefulQuote() public {
        router.configureQuote(int128(int256(AMOUNT_IN)), -int128(int256(AMOUNT_OUT)));
        bytes memory callData = abi.encodeCall(IPropAMMRouter.getAmountOut, (true, AMOUNT_IN, bytes("")));

        (bool staticSuccess,) = address(adapter).staticcall{gas: 300_000}(callData);
        assertFalse(staticSuccess);
        assertEq(router.quoteCalls(), 0);

        (uint256 amountOut, bytes memory swapData) = adapter.getAmountOut(true, AMOUNT_IN, bytes(""));
        assertEq(amountOut, AMOUNT_OUT);
        assertEq(swapData.length, 0);
        assertEq(router.quoteCalls(), 1);
        assertEq(router.lastPool(), address(pool));
        assertTrue(router.lastZeroForOne());
        assertEq(router.lastPriceLimitX64(), 1);
        assertEq(router.lastBidPriceX64(), BID_PRICE_X64);
        assertEq(router.lastAskPriceX64(), ASK_PRICE_X64);
    }

    function test_getAmountOutSupportsReverseDirection() public {
        router.configureQuote(-int128(int256(AMOUNT_OUT)), int128(int256(AMOUNT_IN)));

        (uint256 amountOut,) = adapter.getAmountOut(false, AMOUNT_IN, bytes(""));

        assertEq(amountOut, AMOUNT_OUT);
        assertFalse(router.lastZeroForOne());
        assertEq(router.lastPriceLimitX64(), type(uint128).max);
    }

    function test_getAmountOutRejectsPartialInputAndUnexpectedData() public {
        router.configureQuote(int128(int256(AMOUNT_IN - 1)), -int128(int256(AMOUNT_OUT)));
        vm.expectRevert(MetricAdapter.InvalidQuote.selector);
        adapter.getAmountOut(true, AMOUNT_IN, bytes(""));

        vm.expectRevert(MetricAdapter.UnexpectedQuoteData.selector);
        adapter.getAmountOut(true, AMOUNT_IN, hex"01");
    }

    function test_swapPullsExactInputAndCreditsRecipient() public {
        uint256 amountOutMin = AMOUNT_OUT - 1;
        router.configureSwap(AMOUNT_OUT, AMOUNT_IN, AMOUNT_IN, AMOUNT_OUT);

        vm.prank(user);
        uint256 amountOut = adapter.swap(true, recipient, AMOUNT_IN, amountOutMin, DEADLINE, bytes(""));

        assertEq(amountOut, AMOUNT_OUT);
        assertEq(token0.balanceOf(user), 990 ether);
        assertEq(token1.balanceOf(recipient), AMOUNT_OUT);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(router)), 0);
        assertEq(router.lastRecipient(), recipient);
        assertEq(router.lastAmountOutMin(), amountOutMin);
        assertEq(router.lastDeadline(), DEADLINE);
    }

    function test_swapRejectsReportedPartialInputUse() public {
        router.configureSwap(AMOUNT_OUT, AMOUNT_IN - 1, AMOUNT_IN, AMOUNT_OUT);

        vm.expectRevert(MetricAdapter.InvalidSwapResult.selector);
        vm.prank(user);
        adapter.swap(true, recipient, AMOUNT_IN, 0, DEADLINE, bytes(""));
    }

    function test_swapRejectsDishonestOutput() public {
        router.configureSwap(AMOUNT_OUT, AMOUNT_IN, AMOUNT_IN, AMOUNT_OUT - 1);

        vm.expectRevert(MRC15Adapter.OutputBalanceMismatch.selector);
        vm.prank(user);
        adapter.swap(true, recipient, AMOUNT_IN, 0, DEADLINE, bytes(""));
    }
}
