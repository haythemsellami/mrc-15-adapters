// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICloberBookManager, ICloberBookViewer, ICloberController} from "../../src/adapters/CloberAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped Native", "WNATIVE", 18) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        uint256 balance = balanceOf[msg.sender];
        require(balance >= amount, "BALANCE");
        balanceOf[msg.sender] = balance - amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "NATIVE_TRANSFER");
    }
}

contract MockCloberBookManager is ICloberBookManager {
    mapping(uint192 => BookKey) private _bookKeys;

    function setBook(uint192 id, address base, address quote, uint64 unitSize) external {
        _bookKeys[id] =
            BookKey({base: base, unitSize: unitSize, quote: quote, makerPolicy: 0, hooks: address(0), takerPolicy: 0});
    }

    function getBookKey(uint192 id) external view returns (BookKey memory) {
        return _bookKeys[id];
    }
}

contract MockCloberBookViewer is ICloberBookViewer {
    address public immutable override bookManager;
    mapping(uint192 => uint256) public numerator;
    mapping(uint192 => uint256) public denominator;
    bool public partialFill;

    constructor(address bookManager_) {
        bookManager = bookManager_;
    }

    function setRate(uint192 id, uint256 numerator_, uint256 denominator_) external {
        require(denominator_ != 0, "DENOMINATOR");
        numerator[id] = numerator_;
        denominator[id] = denominator_;
    }

    function setPartialFill(bool partialFill_) external {
        partialFill = partialFill_;
    }

    function getExpectedOutput(SpendOrderParams calldata params)
        external
        view
        returns (uint256 takenQuoteAmount, uint256 spentBaseAmount)
    {
        spentBaseAmount = partialFill ? params.baseAmount - 1 : params.baseAmount;
        takenQuoteAmount = spentBaseAmount * numerator[params.id] / denominator[params.id];
    }
}

    contract MockCloberController is ICloberController {
        address public immutable override bookManager;
        mapping(uint192 => uint256) public numerator;
        mapping(uint192 => uint256) public denominator;

        constructor(address bookManager_) {
            bookManager = bookManager_;
        }

        receive() external payable {}

        function setRate(uint192 id, uint256 numerator_, uint256 denominator_) external {
            require(denominator_ != 0, "DENOMINATOR");
            numerator[id] = numerator_;
            denominator[id] = denominator_;
        }

        function spend(
            SpendOrderParams[] calldata orderParamsList,
            address[] calldata,
            ERC20PermitParams[] calldata,
            uint64 deadline
        ) external payable {
            require(block.timestamp <= deadline, "DEADLINE");
            require(orderParamsList.length == 1, "ORDERS");

            SpendOrderParams calldata params = orderParamsList[0];
            ICloberBookManager.BookKey memory key = ICloberBookManager(bookManager).getBookKey(params.id);
            uint256 amountOut = params.baseAmount * numerator[params.id] / denominator[params.id];
            require(amountOut >= params.minQuoteAmount, "MIN_OUTPUT");

            if (key.base == address(0)) {
                require(msg.value == params.baseAmount, "VALUE");
            } else {
                require(msg.value == 0, "VALUE");
                MockERC20(key.base).transferFrom(msg.sender, address(this), params.baseAmount);
            }

            if (key.quote == address(0)) {
                (bool success,) = msg.sender.call{value: amountOut}("");
                require(success, "NATIVE_TRANSFER");
            } else {
                MockERC20(key.quote).transfer(msg.sender, amountOut);
            }
        }
    }
