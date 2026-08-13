// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

interface IMockPoeCallback {
    function swapCallback(int256 deltaX, int256 deltaY, bytes calldata data) external returns (bytes4);
}

contract MockPoePool {
    address public immutable tokenX;
    address public immutable tokenY;
    uint256 public immutable numerator;
    uint256 public immutable denominator;

    constructor(address tokenX_, address tokenY_, uint256 numerator_, uint256 denominator_) {
        tokenX = tokenX_;
        tokenY = tokenY_;
        numerator = numerator_;
        denominator = denominator_;
    }

    function getTokens() external view returns (address, address) {
        return (tokenX, tokenY);
    }

    function getQuote(bool, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 actualAmountIn, uint256 feeIn, uint256 feeOut)
    {
        amountOut = amountIn * numerator / denominator;
        actualAmountIn = amountIn;
        feeIn = 0;
        feeOut = 0;
    }

    function swap(address recipient, bool swapXToY, uint256 amountIn, bytes calldata data)
        external
        returns (int256 deltaX, int256 deltaY)
    {
        uint256 amountOut = amountIn * numerator / denominator;
        address outputToken = swapXToY ? tokenY : tokenX;
        MockERC20(outputToken).transfer(recipient, amountOut);

        deltaX = swapXToY ? int256(amountIn) : -int256(amountOut);
        deltaY = swapXToY ? -int256(amountOut) : int256(amountIn);
        bytes4 response = IMockPoeCallback(msg.sender).swapCallback(deltaX, deltaY, data);
        require(response == IMockPoeCallback.swapCallback.selector, "CALLBACK");
    }
}
