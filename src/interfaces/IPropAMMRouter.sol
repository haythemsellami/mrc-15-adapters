// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title Proprietary AMM Router Adapter Interface
/// @notice Standard router-facing interface for exact-input propAMM swaps.
/// @dev A conforming adapter represents one fixed market.
///      `token0` and `token1` define the canonical token ordering.
///      `token0ForToken1 == true` means token0 -> token1.
///      `token0ForToken1 == false` means token1 -> token0.
interface IPropAMMRouter {
    /// @notice Emitted after a successful swap.
    /// @param sender The immediate caller that funded the swap.
    /// @param to The recipient credited with the output token.
    /// @param token0ForToken1 The executed direction.
    /// @param amountIn The exact input amount pulled from `sender`.
    /// @param amountOut The actual output amount credited to `to`.
    event PropAMMSwap(
        address indexed sender, address indexed to, bool indexed token0ForToken1, uint256 amountIn, uint256 amountOut
    );

    /// @notice Returns the first token in the adapter's canonical ordering.
    function token0() external view returns (address);

    /// @notice Returns the second token in the adapter's canonical ordering.
    function token1() external view returns (address);

    /// @notice Quotes an exact-input swap.
    /// @param token0ForToken1 True for token0 -> token1, false for token1 -> token0.
    /// @param amountIn The exact input amount.
    /// @param quoteData Opaque venue-specific quote input. May be empty.
    /// @return amountOut The expected output amount.
    /// @return swapData Opaque venue-specific data to supply to `swap`. May be empty.
    /// @dev This function is intentionally non-view. Integrating routers must
    ///      execute it in a call frame whose state changes are always reverted.
    function getAmountOut(bool token0ForToken1, uint256 amountIn, bytes calldata quoteData)
        external
        returns (uint256 amountOut, bytes memory swapData);

    /// @notice Executes an exact-input swap.
    /// @dev Before calling, `msg.sender` must grant this adapter an ERC-20
    ///      allowance of at least `amountIn` for the input token. The adapter
    ///      pulls exactly `amountIn` during this call and credits the actual
    ///      output to `to` before returning.
    /// @param token0ForToken1 True for token0 -> token1, false for token1 -> token0.
    /// @param to The recipient of the output token.
    /// @param amountIn The exact input amount pulled from `msg.sender`.
    /// @param amountOutMin The minimum output amount that must be credited to `to`.
    /// @param deadline The timestamp after which the swap must revert.
    /// @param swapData Opaque venue-specific execution data. May be empty.
    /// @return amountOut The actual output amount credited to `to`.
    function swap(
        bool token0ForToken1,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        bytes calldata swapData
    ) external returns (uint256 amountOut);
}
