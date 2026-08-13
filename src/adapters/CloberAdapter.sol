// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MRC15Adapter} from "../base/MRC15Adapter.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

interface ICloberWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface ICloberBookManager {
    struct BookKey {
        address base;
        uint64 unitSize;
        address quote;
        uint24 makerPolicy;
        address hooks;
        uint24 takerPolicy;
    }

    function getBookKey(uint192 id) external view returns (BookKey memory);
}

interface ICloberBookViewer {
    struct SpendOrderParams {
        uint192 id;
        uint256 limitPrice;
        uint256 baseAmount;
        uint256 minQuoteAmount;
        bytes hookData;
    }

    function bookManager() external view returns (address);
    function getExpectedOutput(SpendOrderParams calldata params)
        external
        view
        returns (uint256 takenQuoteAmount, uint256 spentBaseAmount);
}

interface ICloberController {
    struct SpendOrderParams {
        uint192 id;
        uint256 limitPrice;
        uint256 baseAmount;
        uint256 minQuoteAmount;
        bytes hookData;
    }

    struct PermitSignature {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct ERC20PermitParams {
        address token;
        uint256 permitAmount;
        PermitSignature signature;
    }

    function bookManager() external view returns (address);
    function spend(
        SpendOrderParams[] calldata orderParamsList,
        address[] calldata tokensToSettle,
        ERC20PermitParams[] calldata permitParamsList,
        uint64 deadline
    ) external payable;
}

contract CloberAdapter is MRC15Adapter {
    using SafeTransferLib for address;

    error IncompleteFill();
    error InvalidBook();
    error InvalidConfiguration();
    error InvalidExecution();
    error InvalidQuote();
    error NativeBalanceMismatch();
    error UnexpectedData();
    error UnexpectedNativeTransfer();

    address public immutable bookManager;
    address public immutable bookViewer;
    address public immutable controller;
    address public immutable wrappedNative;
    address public immutable currency0;
    address public immutable currency1;
    uint192 public immutable bookId0For1;
    uint192 public immutable bookId1For0;

    constructor(
        address bookManager_,
        address bookViewer_,
        address controller_,
        address wrappedNative_,
        address token0_,
        address token1_,
        uint192 bookId0For1_,
        uint192 bookId1For0_
    ) MRC15Adapter(token0_, token1_) {
        if (
            bookManager_.code.length == 0 || bookViewer_.code.length == 0 || controller_.code.length == 0
                || wrappedNative_.code.length == 0 || bookId0For1_ == 0 || bookId1For0_ == 0
                || bookId0For1_ == bookId1For0_
        ) revert InvalidConfiguration();
        if (
            ICloberBookViewer(bookViewer_).bookManager() != bookManager_
                || ICloberController(controller_).bookManager() != bookManager_
        ) revert InvalidConfiguration();

        ICloberBookManager.BookKey memory zeroForOne = ICloberBookManager(bookManager_).getBookKey(bookId0For1_);
        ICloberBookManager.BookKey memory oneForZero = ICloberBookManager(bookManager_).getBookKey(bookId1For0_);
        if (
            oneForZero.base != zeroForOne.quote || oneForZero.quote != zeroForOne.base
                || _normalize(zeroForOne.base, wrappedNative_) != token0_
                || _normalize(zeroForOne.quote, wrappedNative_) != token1_
                || _normalize(oneForZero.base, wrappedNative_) != token1_
                || _normalize(oneForZero.quote, wrappedNative_) != token0_
        ) revert InvalidBook();

        bookManager = bookManager_;
        bookViewer = bookViewer_;
        controller = controller_;
        wrappedNative = wrappedNative_;
        currency0 = zeroForOne.base;
        currency1 = zeroForOne.quote;
        bookId0For1 = bookId0For1_;
        bookId1For0 = bookId1For0_;
    }

    receive() external payable {
        if (msg.sender != bookManager && msg.sender != controller && msg.sender != wrappedNative) {
            revert UnexpectedNativeTransfer();
        }
    }

    function getAmountOut(bool token0ForToken1, uint256 amountIn, bytes calldata quoteData)
        external
        view
        override
        returns (uint256 amountOut, bytes memory swapData)
    {
        if (quoteData.length != 0) revert UnexpectedData();

        ICloberBookViewer.SpendOrderParams memory params = ICloberBookViewer.SpendOrderParams({
            id: token0ForToken1 ? bookId0For1 : bookId1For0,
            limitPrice: 0,
            baseAmount: amountIn,
            minQuoteAmount: 0,
            hookData: bytes("")
        });
        uint256 spentBaseAmount;
        (amountOut, spentBaseAmount) = ICloberBookViewer(bookViewer).getExpectedOutput(params);
        if (amountOut == 0) revert InvalidQuote();
        if (spentBaseAmount != amountIn) revert IncompleteFill();
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
        if (swapData.length != 0) revert UnexpectedData();

        address inputToken = token0ForToken1 ? token0 : token1;
        address outputToken = token0ForToken1 ? token1 : token0;
        address inputCurrency = token0ForToken1 ? currency0 : currency1;
        address outputCurrency = token0ForToken1 ? currency1 : currency0;
        uint192 bookId = token0ForToken1 ? bookId0For1 : bookId1For0;
        uint256 outputBalanceBefore = outputToken.safeBalanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;
        uint256 callValue;

        if (inputCurrency == address(0)) {
            ICloberWrappedNative(wrappedNative).withdraw(amountIn);
            callValue = amountIn;
        } else {
            inputToken.forceApprove(controller, amountIn);
        }

        ICloberController.SpendOrderParams[] memory params = new ICloberController.SpendOrderParams[](1);
        params[0] = ICloberController.SpendOrderParams({
            id: bookId, limitPrice: 0, baseAmount: amountIn, minQuoteAmount: amountOutMin, hookData: bytes("")
        });
        address[] memory tokensToSettle = _tokensToSettle(inputCurrency, outputCurrency);
        ICloberController.ERC20PermitParams[] memory permits = new ICloberController.ERC20PermitParams[](0);
        uint64 controllerDeadline = deadline > type(uint64).max ? type(uint64).max : uint64(deadline);

        ICloberController(controller).spend{value: callValue}(params, tokensToSettle, permits, controllerDeadline);
        if (inputCurrency != address(0)) inputToken.forceApprove(controller, 0);

        _wrapNativeDelta(nativeBalanceBefore);
        uint256 outputBalanceAfter = outputToken.safeBalanceOf(address(this));
        if (outputBalanceAfter < outputBalanceBefore) revert InvalidExecution();
        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut == 0) revert InvalidExecution();
        _deliver(outputToken, to, amountOut);
    }

    function _tokensToSettle(address inputCurrency, address outputCurrency)
        private
        pure
        returns (address[] memory tokens)
    {
        uint256 count = (inputCurrency == address(0) ? 0 : 1) + (outputCurrency == address(0) ? 0 : 1);
        tokens = new address[](count);
        uint256 index;
        if (inputCurrency != address(0)) tokens[index++] = inputCurrency;
        if (outputCurrency != address(0)) tokens[index] = outputCurrency;
    }

    function _wrapNativeDelta(uint256 nativeBalanceBefore) private {
        uint256 nativeBalanceAfter = address(this).balance;
        if (nativeBalanceAfter < nativeBalanceBefore) revert NativeBalanceMismatch();
        uint256 nativeDelta = nativeBalanceAfter - nativeBalanceBefore;
        if (nativeDelta != 0) ICloberWrappedNative(wrappedNative).deposit{value: nativeDelta}();
    }

    function _normalize(address currency, address wrappedNative_) private pure returns (address) {
        return currency == address(0) ? wrappedNative_ : currency;
    }
}
