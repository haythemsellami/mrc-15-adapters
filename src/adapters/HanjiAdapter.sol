// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MRC15Adapter} from "../base/MRC15Adapter.sol";
import {FullMath} from "../libraries/FullMath.sol";

/// @notice Current configuration returned by a Hanji central-limit-order-book market.
struct HanjiMarketConfig {
    uint256 scalingFactorTokenX;
    uint256 scalingFactorTokenY;
    address tokenX;
    address tokenY;
    bool supportsNativeEth;
    bool isTokenXWeth;
    address askTrie;
    address bidTrie;
    uint64 adminCommissionRate;
    uint64 totalAggressiveCommissionRate;
    uint64 totalPassiveCommissionRate;
    uint64 passiveOrderPayoutRate;
    bool shouldInvokeOnTrade;
}

/// @notice Minimal Hanji market interface required for configuration and execution.
interface IHanjiMarket {
    /// @notice Returns the market's current token, scaling, native-settlement, and commission configuration.
    function getConfig() external view returns (HanjiMarketConfig memory config);

    /// @notice Places a market-only order for an exact number of token-X shares.
    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72 price,
        uint128 maxCommission,
        bool marketOnly,
        bool postOnly,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint64 orderId, uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);

    /// @notice Places a market-only order with an exact token-Y target value.
    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72 price,
        uint128 maxCommission,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint128 executedShares, uint128 executedValue, uint128 aggressiveFee);
}

/// @notice Minimal Hanji fast-quoter helper interface.
interface IHanjiFastQuoterHelper {
    /// @notice Assembles the currently visible virtual bid and ask ladders for one market.
    function assembleOrderbooksFromOrders(address market, uint24 maxPriceLevels)
        external
        view
        returns (
            uint72[] memory bidPrices,
            uint128[] memory bidShares,
            uint72[] memory askPrices,
            uint128[] memory askShares
        );
}

/// @notice Wrapped-native-token interface used to normalize Hanji native output.
interface IHanjiWrappedNative {
    function deposit() external payable;
}

/// @title Hanji routing adapter
/// @notice Provides a simulation-gated integration for one Hanji order-book market.
/// @dev Quotes reject helper-visible partial fills and token-Y targets that leave predictable residual input. Because
///      the helper ladder is not always an executable preview, integrations must simulate the complete router call.
///      Every successful execution still satisfies MRC-15 exact-input settlement.
contract HanjiAdapter is MRC15Adapter {
    using SafeERC20 for IERC20;

    uint256 private constant COMMISSION_SCALE = 1e18;
    uint72 private constant MIN_PRICE = 1;
    uint72 private constant MAX_PRICE = 999_999_000_000_000_000_000;

    /// @notice The Hanji market served by this adapter.
    address public immutable market;

    /// @notice The Hanji helper used to read the virtual order-book ladder.
    address public immutable helper;

    /// @notice The wrapped native token used to normalize native market output.
    address public immutable wrappedNative;

    /// @notice The maximum number of helper price levels considered on each side.
    uint24 public immutable maxPriceLevels;

    /// @notice The token-X base-unit amount represented by one Hanji share.
    uint256 public immutable scalingFactorTokenX;

    /// @notice The token-Y base-unit amount represented by one Hanji value unit.
    uint256 public immutable scalingFactorTokenY;

    /// @notice Whether the configured market supports native-currency settlement.
    bool public immutable supportsNativeEth;

    /// @notice Whether token X is the configured wrapped-native side.
    bool public immutable isTokenXWrappedNative;

    error IncompleteInputConsumption();
    error InsufficientHelperDepth();
    error InvalidConfiguration();
    error InvalidExecution();
    error InvalidQuote();
    error InvalidShareAmount();
    error NativeBalanceMismatch();
    error QuoteAmountOverflow();
    error UnexpectedData();
    error UnexpectedNativeTransfer();

    /// @notice Configures one Hanji market and captures its canonical token and scaling configuration.
    constructor(address market_, address helper_, uint24 maxPriceLevels_)
        MRC15Adapter(_readMarketToken(market_, true), _readMarketToken(market_, false))
    {
        if (helper_.code.length == 0 || maxPriceLevels_ == 0 || market_.code.length == 0) {
            revert InvalidConfiguration();
        }

        HanjiMarketConfig memory config = _readMarketConfig(market_);
        address wrappedNative_ =
            config.supportsNativeEth ? (config.isTokenXWeth ? config.tokenX : config.tokenY) : address(0);
        _validateConfig(config, wrappedNative_);

        market = market_;
        helper = helper_;
        wrappedNative = wrappedNative_;
        maxPriceLevels = maxPriceLevels_;
        scalingFactorTokenX = config.scalingFactorTokenX;
        scalingFactorTokenY = config.scalingFactorTokenY;
        supportsNativeEth = config.supportsNativeEth;
        isTokenXWrappedNative = config.isTokenXWeth;
    }

    /// @notice Receives native output from the configured Hanji market.
    receive() external payable {
        if (!supportsNativeEth || msg.sender != market) revert UnexpectedNativeTransfer();
    }

    function getAmountOut(bool token0ForToken1, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        if (quoteData.length != 0) revert UnexpectedData();

        uint256 feeRate = _validateCurrentConfig();
        (uint72[] memory bidPrices, uint128[] memory bidShares, uint72[] memory askPrices, uint128[] memory askShares) =
            IHanjiFastQuoterHelper(helper).assembleOrderbooksFromOrders(market, maxPriceLevels);

        if (bidPrices.length != bidShares.length || askPrices.length != askShares.length) revert InvalidQuote();

        amountOut = token0ForToken1
            ? _quoteTokenXForTokenY(amountIn, feeRate, bidPrices, bidShares)
            : _quoteTokenYForTokenX(amountIn, feeRate, askPrices, askShares);
        swapData = bytes("");
    }

    function _executeSwap(
        bool token0ForToken1,
        uint256 amountIn,
        uint256,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedData();
        _validateCurrentConfig();

        IERC20 inputToken = IERC20(token0ForToken1 ? token0 : token1);
        IERC20 outputToken = IERC20(token0ForToken1 ? token1 : token0);
        uint256 inputBalanceBefore = inputToken.balanceOf(address(this));
        uint256 outputBalanceBefore = outputToken.balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;

        inputToken.forceApprove(market, amountIn);
        if (token0ForToken1) {
            IHanjiMarket(market)
                .placeOrder(true, _tokenXShares(amountIn), MIN_PRICE, type(uint128).max, true, false, true, deadline);
        } else {
            IHanjiMarket(market)
                .placeMarketOrderWithTargetValue(
                    false, _tokenYTarget(amountIn), MAX_PRICE, type(uint128).max, true, deadline
                );
        }
        inputToken.forceApprove(market, 0);

        _wrapNativeDelta(nativeBalanceBefore, address(outputToken));

        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != amountIn) {
            revert IncompleteInputConsumption();
        }

        uint256 outputBalanceAfter = outputToken.balanceOf(address(this));
        if (outputBalanceAfter <= outputBalanceBefore) revert InvalidExecution();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        _deliver(address(outputToken), to, amountOut);
    }

    function _quoteTokenXForTokenY(uint256 amountIn, uint256 feeRate, uint72[] memory prices, uint128[] memory shares)
        private
        view
        returns (uint256 amountOut)
    {
        uint256 requestedShares = _tokenXShares(amountIn);
        uint256 remainingShares = requestedShares;
        uint256 grossValue;

        for (uint256 i; i < prices.length && remainingShares != 0; ++i) {
            if (prices[i] == 0) revert InvalidQuote();
            uint256 availableShares = shares[i];
            uint256 takenShares = remainingShares < availableShares ? remainingShares : availableShares;
            grossValue += takenShares * uint256(prices[i]);
            remainingShares -= takenShares;
        }

        if (remainingShares != 0) revert InsufficientHelperDepth();
        uint256 fee = _fee(grossValue, feeRate);
        if (grossValue <= fee) revert InvalidQuote();
        amountOut = (grossValue - fee) * scalingFactorTokenY;
        if (amountOut == 0) revert InvalidQuote();
    }

    function _quoteTokenYForTokenX(uint256 amountIn, uint256 feeRate, uint72[] memory prices, uint128[] memory shares)
        private
        view
        returns (uint256 amountOut)
    {
        uint256 targetValue = _tokenYTarget(amountIn);
        uint256 grossBudget = FullMath.mulDiv(targetValue, COMMISSION_SCALE, COMMISSION_SCALE + feeRate);
        uint256 remainingBudget = grossBudget;
        uint256 executedShares;
        uint256 grossValue;

        for (uint256 i; i < prices.length && remainingBudget != 0; ++i) {
            uint256 price = prices[i];
            if (price == 0) revert InvalidQuote();
            uint256 affordableShares = remainingBudget / price;
            uint256 availableShares = shares[i];
            uint256 takenShares = affordableShares < availableShares ? affordableShares : availableShares;
            executedShares += takenShares;
            uint256 levelValue = takenShares * price;
            grossValue += levelValue;
            remainingBudget -= levelValue;
            if (takenShares < availableShares) break;
        }

        if (executedShares == 0 || executedShares > type(uint128).max) revert InvalidQuote();
        if (grossValue + _fee(grossValue, feeRate) != targetValue) revert InvalidQuote();

        amountOut = executedShares * scalingFactorTokenX;
        if (amountOut == 0) revert InvalidQuote();
    }

    function _tokenXShares(uint256 amount) private view returns (uint128 shares) {
        if (amount % scalingFactorTokenX != 0) revert InvalidShareAmount();
        uint256 shareCount = amount / scalingFactorTokenX;
        if (shareCount == 0 || shareCount > type(uint128).max) revert QuoteAmountOverflow();
        shares = uint128(shareCount);
    }

    function _tokenYTarget(uint256 amount) private view returns (uint128 target) {
        if (amount % scalingFactorTokenY != 0) revert InvalidShareAmount();
        uint256 targetValue = amount / scalingFactorTokenY;
        if (targetValue == 0 || targetValue > type(uint128).max) revert QuoteAmountOverflow();
        target = uint128(targetValue);
    }

    function _fee(uint256 grossValue, uint256 feeRate) private pure returns (uint256 fee) {
        fee = FullMath.mulDiv(grossValue, feeRate, COMMISSION_SCALE, FullMath.Rounding.Ceil);
    }

    function _validateCurrentConfig() private view returns (uint256 feeRate) {
        HanjiMarketConfig memory config = _readMarketConfig(market);
        _validateConfig(config, wrappedNative);
        if (
            config.tokenX != token0 || config.tokenY != token1 || config.scalingFactorTokenX != scalingFactorTokenX
                || config.scalingFactorTokenY != scalingFactorTokenY || config.supportsNativeEth != supportsNativeEth
                || config.isTokenXWeth != isTokenXWrappedNative
        ) {
            revert InvalidConfiguration();
        }

        feeRate = uint256(config.totalAggressiveCommissionRate) + uint256(config.passiveOrderPayoutRate);
        if (feeRate >= COMMISSION_SCALE) revert InvalidConfiguration();
    }

    function _wrapNativeDelta(uint256 nativeBalanceBefore, address outputToken) private {
        uint256 nativeBalanceAfter = address(this).balance;
        if (nativeBalanceAfter < nativeBalanceBefore) revert NativeBalanceMismatch();
        uint256 nativeDelta = nativeBalanceAfter - nativeBalanceBefore;
        if (nativeDelta == 0) return;
        if (!supportsNativeEth || outputToken != wrappedNative) revert InvalidExecution();
        IHanjiWrappedNative(wrappedNative).deposit{value: nativeDelta}();
    }

    function _readMarketToken(address market_, bool readTokenX) private view returns (address token) {
        HanjiMarketConfig memory config = _readMarketConfig(market_);
        token = readTokenX ? config.tokenX : config.tokenY;
    }

    function _readMarketConfig(address market_) private view returns (HanjiMarketConfig memory config) {
        if (market_.code.length == 0) revert InvalidConfiguration();

        (bool success, bytes memory returnData) = market_.staticcall(abi.encodeCall(IHanjiMarket.getConfig, ()));
        if (!success || returnData.length != 13 * 32) revert InvalidConfiguration();
        config = abi.decode(returnData, (HanjiMarketConfig));
    }

    function _validateConfig(HanjiMarketConfig memory config, address wrappedNative_) private view {
        if (config.scalingFactorTokenX == 0 || config.scalingFactorTokenY == 0) revert InvalidConfiguration();
        if (
            config.supportsNativeEth
                && (wrappedNative_ == address(0)
                    || (config.isTokenXWeth ? config.tokenX : config.tokenY) != wrappedNative_
                    || wrappedNative_.code.length == 0)
        ) {
            revert InvalidConfiguration();
        }
    }
}
