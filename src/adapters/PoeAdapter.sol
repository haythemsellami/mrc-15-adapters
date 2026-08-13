// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MRC15Adapter} from "../base/MRC15Adapter.sol";
import {SignedDeltaMath} from "../libraries/SignedDeltaMath.sol";

interface IPoePool {
    function getTokens() external view returns (address tokenX, address tokenY);
    function swap(address recipient, bool swapXToY, uint256 amountIn, bytes calldata data)
        external
        returns (int256 deltaX, int256 deltaY);
}

contract PoeAdapter is MRC15Adapter {
    using SafeERC20 for IERC20;

    error CallbackNotCompleted();
    error InvalidCallback();
    error InvalidPool();
    error InvalidQuote();
    error UnexpectedData();

    bytes4 private constant GET_QUOTE_SELECTOR = bytes4(keccak256("getQuote(bool,uint256)"));

    address public immutable pool;

    uint256 private _callbackAmount;
    bool private _callbackDirection;
    bool private _callbackCompleted;

    constructor(address pool_) MRC15Adapter(_readTokens(pool_, true), _readTokens(pool_, false)) {
        if (pool_.code.length == 0) revert InvalidPool();
        pool = pool_;
    }

    function getAmountOut(bool token0ForToken1, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        if (quoteData.length != 0) revert UnexpectedData();

        (bool success, bytes memory result) =
            pool.staticcall(abi.encodeWithSelector(GET_QUOTE_SELECTOR, token0ForToken1, amountIn));
        if (!success) _bubbleRevert(result);
        if (result.length < 64) revert InvalidQuote();

        uint256 actualAmountIn;
        assembly ("memory-safe") {
            amountOut := mload(add(result, 0x20))
            actualAmountIn := mload(add(result, 0x40))
        }
        if (amountOut == 0 || actualAmountIn != amountIn) revert InvalidQuote();
        swapData = bytes("");
    }

    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata data) external returns (bytes4) {
        if (msg.sender != pool || _callbackAmount == 0 || _callbackCompleted || data.length != 32) {
            revert InvalidCallback();
        }

        address expectedToken = _callbackDirection ? token0 : token1;
        if (abi.decode(data, (address)) != expectedToken) revert InvalidCallback();

        int256 inputDelta = _callbackDirection ? deltaX : deltaY;
        int256 outputDelta = _callbackDirection ? deltaY : deltaX;
        if (inputDelta <= 0 || uint256(inputDelta) != _callbackAmount || outputDelta >= 0) {
            revert InvalidCallback();
        }

        _callbackCompleted = true;
        _callbackAmount = 0;
        IERC20(expectedToken).safeTransfer(pool, uint256(inputDelta));
        return this.swapCallback.selector;
    }

    function _executeSwap(bool token0ForToken1, uint256 amountIn, uint256, address to, uint256, bytes calldata swapData)
        internal
        override
        returns (uint256 amountOut)
    {
        if (swapData.length != 0) revert UnexpectedData();

        _callbackAmount = amountIn;
        _callbackDirection = token0ForToken1;
        _callbackCompleted = false;

        (int256 deltaX, int256 deltaY) =
            IPoePool(pool).swap(to, token0ForToken1, amountIn, abi.encode(token0ForToken1 ? token0 : token1));
        if (!_callbackCompleted || _callbackAmount != 0) revert CallbackNotCompleted();

        int256 inputDelta = token0ForToken1 ? deltaX : deltaY;
        int256 outputDelta = token0ForToken1 ? deltaY : deltaX;
        if (inputDelta <= 0 || uint256(inputDelta) != amountIn || outputDelta >= 0) revert InvalidCallback();
        amountOut = SignedDeltaMath.magnitude(outputDelta);
        if (amountOut == 0) revert InvalidQuote();
    }

    function _readTokens(address pool_, bool first) private view returns (address token) {
        if (pool_.code.length == 0) revert InvalidPool();
        (address tokenX, address tokenY) = IPoePool(pool_).getTokens();
        token = first ? tokenX : tokenY;
    }

    function _bubbleRevert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
