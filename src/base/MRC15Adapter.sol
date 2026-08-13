// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPropAMMRouter} from "../interfaces/IPropAMMRouter.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

abstract contract MRC15Adapter is IPropAMMRouter {
    using SafeTransferLib for address;

    error DeadlineExpired();
    error InvalidAmountIn();
    error InvalidRecipient();
    error InvalidTokenPair();
    error OutputBalanceMismatch();
    error Reentrancy();
    error SlippageExceeded();

    address public immutable override token0;
    address public immutable override token1;

    uint256 private _unlocked = 1;

    constructor(address token0_, address token1_) {
        if (
            token0_ == address(0) || token1_ == address(0) || token0_ == token1_ || token0_.code.length == 0
                || token1_.code.length == 0
        ) revert InvalidTokenPair();
        token0 = token0_;
        token1 = token1_;
    }

    modifier nonReentrant() {
        if (_unlocked != 1) revert Reentrancy();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function swap(
        bool token0ForToken1,
        address to,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        bytes calldata swapData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (to == address(0)) revert InvalidRecipient();
        if (amountIn == 0) revert InvalidAmountIn();
        if (block.timestamp > deadline) revert DeadlineExpired();

        address inputToken = token0ForToken1 ? token0 : token1;
        address outputToken = token0ForToken1 ? token1 : token0;
        uint256 recipientBalanceBefore = outputToken.safeBalanceOf(to);

        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 expectedAmountOut = _executeSwap(token0ForToken1, amountIn, amountOutMin, to, deadline, swapData);
        if (expectedAmountOut < amountOutMin) revert SlippageExceeded();

        uint256 recipientBalanceAfter = outputToken.safeBalanceOf(to);
        amountOut = recipientBalanceAfter - recipientBalanceBefore;
        if (amountOut != expectedAmountOut) revert OutputBalanceMismatch();

        emit PropAMMSwap(msg.sender, to, token0ForToken1, amountIn, amountOut);
    }

    function _deliver(address outputToken, address to, uint256 amount) internal {
        outputToken.safeTransfer(to, amount);
    }

    function _executeSwap(
        bool token0ForToken1,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline,
        bytes calldata swapData
    ) internal virtual returns (uint256 amountOut);
}
