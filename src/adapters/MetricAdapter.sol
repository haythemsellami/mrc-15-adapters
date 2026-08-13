// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MRC15Adapter} from "../base/MRC15Adapter.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

/// @notice Immutable configuration returned by a legacy Metric OMM pool.
struct MetricPoolImmutables {
    address factory;
    address priceProvider;
    address token0;
    address token1;
    uint104 a;
    uint104 b;
    uint104 c;
    bool reportSwapToPriceProvider;
    uint256 maxDriftE8;
    uint256 maxDriftDecayPerSecondE8;
    int16 lowestBin;
    int16 highestBin;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
}

/// @notice Minimal interface for a legacy Metric OMM pool.
interface IMetricLegacyPool {
    /// @notice Returns the pool's immutable configuration.
    function getImmutables() external view returns (MetricPoolImmutables memory poolImmutables);
}

/// @notice Minimal interface for a legacy Metric price provider.
interface IMetricLegacyPriceProvider {
    /// @notice Returns the current oracle bid and ask prices in Q64.64 format.
    function getBidAndAskPrice() external view returns (uint128 bidPriceX64, uint128 askPriceX64);
}

/// @notice Minimal interface for the legacy Metric OMM swap router.
interface IMetricLegacyRouter {
    /// @notice Simulates an exact-input swap and returns its signed token deltas.
    function quoteSwap(
        address pool,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint128 bidPriceX64,
        uint128 askPriceX64
    ) external returns (int128 amount0Delta, int128 amount1Delta);

    /// @notice Executes an exact-input swap.
    function swapExactInput(
        address pool,
        address recipient,
        bool zeroForOne,
        uint128 amountIn,
        uint128 priceLimitX64,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable returns (uint256 amountOut, uint256 amountInUsed);
}

/// @title Metric legacy MRC-15 adapter
/// @notice Adapts one legacy Metric OMM pool to the MRC-15 exact-input interface.
contract MetricAdapter is MRC15Adapter {
    using SafeTransferLib for address;

    uint128 private constant MIN_PRICE_LIMIT_X64 = 1;
    uint128 private constant MAX_PRICE_LIMIT_X64 = type(uint128).max;
    uint256 private constant MAX_QUOTE_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice The legacy Metric OMM swap router.
    address public immutable router;

    /// @notice The Metric OMM pool adapted by this contract.
    address public immutable pool;

    /// @notice The pool's oracle price provider.
    address public immutable priceProvider;

    error InvalidPool();
    error InvalidPriceProvider();
    error InvalidQuote();
    error InvalidRouter();
    error InvalidSwapResult();
    error QuoteAmountOverflow();
    error SwapAmountOverflow();
    error UnexpectedQuoteData();
    error UnexpectedSwapData();

    /// @notice Initializes an adapter for one legacy Metric OMM pool.
    /// @param router_ The legacy Metric OMM swap router.
    /// @param pool_ The legacy Metric OMM pool to adapt.
    constructor(address router_, address pool_)
        MRC15Adapter(_readPoolToken(pool_, true), _readPoolToken(pool_, false))
    {
        if (router_.code.length == 0) {
            revert InvalidRouter();
        }

        MetricPoolImmutables memory poolImmutables = _readPoolImmutables(pool_);
        if (poolImmutables.token0 != token0 || poolImmutables.token1 != token1) revert InvalidPool();
        if (poolImmutables.priceProvider.code.length == 0) revert InvalidPriceProvider();

        router = router_;
        pool = pool_;
        priceProvider = poolImmutables.priceProvider;
    }

    /// @notice Quotes through Metric's state-changing legacy quote path.
    /// @dev This call must be made through an ordinary CALL inside an unconditional rollback boundary.
    function getAmountOut(bool token0ForToken1, uint256 amountIn, bytes calldata quoteData)
        external
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        if (quoteData.length != 0) revert UnexpectedQuoteData();
        if (amountIn > MAX_QUOTE_AMOUNT) revert QuoteAmountOverflow();

        (uint128 bidPriceX64, uint128 askPriceX64) = IMetricLegacyPriceProvider(priceProvider).getBidAndAskPrice();
        (int128 amount0Delta, int128 amount1Delta) = IMetricLegacyRouter(router)
            .quoteSwap(
                pool, token0ForToken1, int128(uint128(amountIn)), _priceLimit(token0ForToken1), bidPriceX64, askPriceX64
            );

        int128 inputDelta = token0ForToken1 ? amount0Delta : amount1Delta;
        int128 outputDelta = token0ForToken1 ? amount1Delta : amount0Delta;
        if (inputDelta != int128(uint128(amountIn)) || outputDelta >= 0) revert InvalidQuote();

        amountOut = uint256(-int256(outputDelta));
        swapData = bytes("");
    }

    function _executeSwap(
        bool token0ForToken1,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal override returns (uint256 amountOut) {
        if (swapData.length != 0) revert UnexpectedSwapData();
        if (amountIn > MAX_QUOTE_AMOUNT) revert SwapAmountOverflow();

        address inputToken = token0ForToken1 ? token0 : token1;
        inputToken.forceApprove(router, amountIn);

        uint256 amountInUsed;
        (amountOut, amountInUsed) = IMetricLegacyRouter(router)
            .swapExactInput(
                pool, to, token0ForToken1, uint128(amountIn), _priceLimit(token0ForToken1), amountOutMin, deadline
            );

        inputToken.forceApprove(router, 0);
        if (amountInUsed != amountIn || amountOut == 0) revert InvalidSwapResult();
    }

    function _priceLimit(bool token0ForToken1) private pure returns (uint128 priceLimitX64) {
        return token0ForToken1 ? MIN_PRICE_LIMIT_X64 : MAX_PRICE_LIMIT_X64;
    }

    function _readPoolToken(address pool_, bool readToken0) private view returns (address token) {
        MetricPoolImmutables memory poolImmutables = _readPoolImmutables(pool_);
        return readToken0 ? poolImmutables.token0 : poolImmutables.token1;
    }

    function _readPoolImmutables(address pool_) private view returns (MetricPoolImmutables memory poolImmutables) {
        if (pool_.code.length == 0) revert InvalidPool();

        (bool success, bytes memory returnData) = pool_.staticcall(abi.encodeCall(IMetricLegacyPool.getImmutables, ()));
        if (!success || returnData.length != 14 * 32) revert InvalidPool();

        poolImmutables = abi.decode(returnData, (MetricPoolImmutables));
    }
}
