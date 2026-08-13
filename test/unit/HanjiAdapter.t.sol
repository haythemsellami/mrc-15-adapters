// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HanjiAdapter} from "../../src/adapters/HanjiAdapter.sol";
import {MRC15Adapter} from "../../src/base/MRC15Adapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockHanjiFastQuoter, MockHanjiMarket, MockHanjiWrappedNative} from "../mocks/MockHanji.sol";

contract HanjiAdapterUnitTest is Test {
    uint24 internal constant MAX_PRICE_LEVELS = 60;
    uint256 internal constant SCALING_X = 1 ether;
    uint256 internal constant SCALING_Y = 1;
    uint256 internal constant SELL_SHARES = 4;
    uint256 internal constant SELL_VALUE = 7_800_000;
    uint256 internal constant SELL_FEE = 780;
    uint256 internal constant SELL_OUTPUT = SELL_VALUE - SELL_FEE;
    uint256 internal constant BUY_SHARES = 4;
    uint256 internal constant BUY_VALUE = 8_600_000;
    uint256 internal constant BUY_FEE = 860;
    uint256 internal constant BUY_INPUT = BUY_VALUE + BUY_FEE;
    uint256 internal constant BUY_OUTPUT = BUY_SHARES * SCALING_X;

    MockHanjiWrappedNative internal wrappedNative;
    MockERC20 internal usdc;
    MockHanjiMarket internal market;
    MockHanjiFastQuoter internal helper;
    HanjiAdapter internal adapter;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        wrappedNative = new MockHanjiWrappedNative();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new MockHanjiMarket(address(wrappedNative), address(usdc), SCALING_X, SCALING_Y);
        helper = new MockHanjiFastQuoter(address(market));
        adapter = new HanjiAdapter(address(market), address(helper), MAX_PRICE_LEVELS);
        _setMultilevelBook();

        usdc.mint(address(market), 1_000_000_000_000);
        vm.deal(address(market), 1_000_000 ether);
        wrappedNative.mint(user, 1_000_000 ether);
        usdc.mint(user, 1_000_000_000_000);

        vm.startPrank(user);
        wrappedNative.approve(address(adapter), type(uint256).max);
        usdc.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_exposesValidatedConfiguration() public view {
        assertEq(adapter.token0(), address(wrappedNative));
        assertEq(adapter.token1(), address(usdc));
        assertEq(adapter.market(), address(market));
        assertEq(adapter.helper(), address(helper));
        assertEq(adapter.maxPriceLevels(), MAX_PRICE_LEVELS);
        assertEq(adapter.scalingFactorTokenX(), SCALING_X);
        assertEq(adapter.scalingFactorTokenY(), SCALING_Y);
        assertEq(adapter.wrappedNative(), address(wrappedNative));
        assertTrue(adapter.supportsNativeEth());
        assertTrue(adapter.isTokenXWrappedNative());
    }

    function test_quotesBothDirectionsAcrossMultipleLevels() public view {
        (uint256 sellAmountOut, bytes memory sellData) = adapter.getAmountOut(true, SELL_SHARES * SCALING_X, bytes(""));
        (uint256 buyAmountOut, bytes memory buyData) = adapter.getAmountOut(false, BUY_INPUT, bytes(""));

        assertEq(sellAmountOut, SELL_OUTPUT);
        assertEq(buyAmountOut, BUY_OUTPUT);
        assertEq(sellData.length, 0);
        assertEq(buyData.length, 0);
    }

    function test_quoteCompletesUnderStaticcall() public view {
        (bool success, bytes memory result) =
            address(adapter).staticcall(abi.encodeCall(adapter.getAmountOut, (false, BUY_INPUT, bytes(""))));
        assertTrue(success);
        (uint256 amountOut, bytes memory swapData) = abi.decode(result, (uint256, bytes));
        assertEq(amountOut, BUY_OUTPUT);
        assertEq(swapData.length, 0);
    }

    function test_quotesCeilingFee() public {
        uint72[] memory bidPrices = new uint72[](1);
        bidPrices[0] = 10_001;
        uint128[] memory bidShares = new uint128[](1);
        bidShares[0] = 1;
        helper.setOrderbook(bidPrices, bidShares, new uint72[](0), new uint128[](0));

        (uint256 amountOut,) = adapter.getAmountOut(true, SCALING_X, bytes(""));
        assertEq(amountOut, 9999);
    }

    function test_quoteRejectsInvalidAmountsAndInsufficientDepth() public {
        vm.expectRevert(HanjiAdapter.InvalidShareAmount.selector);
        adapter.getAmountOut(true, SCALING_X + 1, bytes(""));

        vm.expectRevert(HanjiAdapter.InsufficientHelperDepth.selector);
        adapter.getAmountOut(true, 6 * SCALING_X, bytes(""));

        vm.expectRevert(HanjiAdapter.InvalidQuote.selector);
        adapter.getAmountOut(false, BUY_INPUT + 1, bytes(""));
    }

    function test_sellExecutesErc20Settlement() public {
        market.setSellExecution(
            uint128(SELL_SHARES), uint128(SELL_VALUE), uint128(SELL_FEE), SELL_SHARES * SCALING_X, SELL_OUTPUT
        );

        vm.prank(user);
        uint256 amountOut =
            adapter.swap(true, recipient, SELL_SHARES * SCALING_X, SELL_OUTPUT, block.timestamp, bytes(""));

        assertEq(amountOut, SELL_OUTPUT);
        assertEq(usdc.balanceOf(recipient), SELL_OUTPUT);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wrappedNative.allowance(address(adapter), address(market)), 0);
        assertEq(market.lastQuantity(), SELL_SHARES);
        assertEq(market.lastPrice(), 1);
        assertTrue(market.lastIsAsk());
        assertTrue(market.lastMarketOnly());
        assertFalse(market.lastPostOnly());
        assertTrue(market.lastTransferExecutedTokens());
    }

    function test_buyWrapsNativeOutput() public {
        _configureExactNativeBuy();

        vm.prank(user);
        uint256 amountOut = adapter.swap(false, recipient, BUY_INPUT, BUY_OUTPUT, block.timestamp, bytes(""));

        assertEq(amountOut, BUY_OUTPUT);
        assertEq(wrappedNative.balanceOf(recipient), BUY_OUTPUT);
        assertEq(wrappedNative.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(usdc.allowance(address(adapter), address(market)), 0);
        assertEq(market.lastTargetTokenYValue(), BUY_INPUT);
        assertEq(market.lastPrice(), 999_999_000_000_000_000_000);
        assertFalse(market.lastIsAsk());
    }

    function test_buyRejectsResidualInput() public {
        market.setBuyExecution(
            uint128(BUY_SHARES), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT - 1, BUY_OUTPUT, true
        );

        vm.expectRevert(HanjiAdapter.IncompleteInputConsumption.selector);
        vm.prank(user);
        adapter.swap(false, recipient, BUY_INPUT, 0, block.timestamp, bytes(""));
    }

    function test_buyEnforcesQuotedMinimum() public {
        market.setBuyExecution(
            uint128(BUY_SHARES - 1), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT, BUY_OUTPUT - SCALING_X, true
        );

        vm.expectRevert(MRC15Adapter.SlippageExceeded.selector);
        vm.prank(user);
        adapter.swap(false, recipient, BUY_INPUT, BUY_OUTPUT, block.timestamp, bytes(""));
    }

    function test_quoteRejectsChangedConfiguration() public {
        market.setScalingFactors(SCALING_X, 2);

        vm.expectRevert(HanjiAdapter.InvalidConfiguration.selector);
        adapter.getAmountOut(true, SCALING_X, bytes(""));
    }

    function test_rejectsUnauthorizedNativeTransfer() public {
        (bool success, bytes memory returnData) = address(adapter).call{value: 1}("");
        assertFalse(success);
        assertEq(bytes4(returnData), HanjiAdapter.UnexpectedNativeTransfer.selector);
    }

    function _setMultilevelBook() internal {
        uint72[] memory bidPrices = new uint72[](2);
        bidPrices[0] = 2_000_000;
        bidPrices[1] = 1_900_000;
        uint128[] memory bidShares = new uint128[](2);
        bidShares[0] = 2;
        bidShares[1] = 3;

        uint72[] memory askPrices = new uint72[](2);
        askPrices[0] = 2_100_000;
        askPrices[1] = 2_200_000;
        uint128[] memory askShares = new uint128[](2);
        askShares[0] = 2;
        askShares[1] = 3;

        helper.setOrderbook(bidPrices, bidShares, askPrices, askShares);
    }

    function _configureExactNativeBuy() internal {
        market.setBuyExecution(uint128(BUY_SHARES), uint128(BUY_VALUE), uint128(BUY_FEE), BUY_INPUT, BUY_OUTPUT, true);
    }
}
