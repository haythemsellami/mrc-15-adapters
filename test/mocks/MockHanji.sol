// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HanjiMarketConfig, IHanjiFastQuoterHelper, IHanjiMarket} from "../../src/adapters/HanjiAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockHanjiWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped Monad", "WMON", 18) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}

contract MockHanjiFastQuoter is IHanjiFastQuoterHelper {
    address public expectedMarket;

    uint72[] private _bidPrices;
    uint128[] private _bidShares;
    uint72[] private _askPrices;
    uint128[] private _askShares;

    constructor(address expectedMarket_) {
        expectedMarket = expectedMarket_;
    }

    function setOrderbook(
        uint72[] calldata bidPrices_,
        uint128[] calldata bidShares_,
        uint72[] calldata askPrices_,
        uint128[] calldata askShares_
    ) external {
        require(bidPrices_.length == bidShares_.length, "BID_LENGTH");
        require(askPrices_.length == askShares_.length, "ASK_LENGTH");
        _bidPrices = bidPrices_;
        _bidShares = bidShares_;
        _askPrices = askPrices_;
        _askShares = askShares_;
    }

    function assembleOrderbooksFromOrders(address market, uint24 maxPriceLevels)
        external
        view
        returns (
            uint72[] memory bidPrices,
            uint128[] memory bidShares,
            uint72[] memory askPrices,
            uint128[] memory askShares
        )
    {
        require(market == expectedMarket, "MARKET");
        uint256 bidLength = _bidPrices.length < maxPriceLevels ? _bidPrices.length : maxPriceLevels;
        uint256 askLength = _askPrices.length < maxPriceLevels ? _askPrices.length : maxPriceLevels;
        bidPrices = new uint72[](bidLength);
        bidShares = new uint128[](bidLength);
        askPrices = new uint72[](askLength);
        askShares = new uint128[](askLength);

        for (uint256 i; i < bidLength; ++i) {
            bidPrices[i] = _bidPrices[i];
            bidShares[i] = _bidShares[i];
        }
        for (uint256 i; i < askLength; ++i) {
            askPrices[i] = _askPrices[i];
            askShares[i] = _askShares[i];
        }
    }
}

contract MockHanjiMarket is IHanjiMarket {
    struct Execution {
        uint128 shares;
        uint128 value;
        uint128 fee;
        uint256 inputSpent;
        uint256 outputTransferred;
    }

    HanjiMarketConfig private _config;
    Execution public sellExecution;
    Execution public buyExecution;
    bool public deliverBuyOutputAsNative;

    uint128 public lastQuantity;
    uint72 public lastPrice;
    uint128 public lastMaxCommission;
    bool public lastIsAsk;
    bool public lastMarketOnly;
    bool public lastPostOnly;
    bool public lastTransferExecutedTokens;
    uint256 public lastExpires;
    uint128 public lastTargetTokenYValue;

    constructor(address tokenX_, address tokenY_, uint256 scalingFactorTokenX_, uint256 scalingFactorTokenY_) {
        _config.scalingFactorTokenX = scalingFactorTokenX_;
        _config.scalingFactorTokenY = scalingFactorTokenY_;
        _config.tokenX = tokenX_;
        _config.tokenY = tokenY_;
        _config.supportsNativeEth = true;
        _config.isTokenXWeth = true;
        _config.totalAggressiveCommissionRate = 1e14;
    }

    receive() external payable {}

    function setScalingFactors(uint256 scalingFactorTokenX_, uint256 scalingFactorTokenY_) external {
        _config.scalingFactorTokenX = scalingFactorTokenX_;
        _config.scalingFactorTokenY = scalingFactorTokenY_;
    }

    function setSellExecution(uint128 shares, uint128 value, uint128 fee, uint256 inputSpent, uint256 outputTransferred)
        external
    {
        sellExecution = Execution({
            shares: shares, value: value, fee: fee, inputSpent: inputSpent, outputTransferred: outputTransferred
        });
    }

    function setBuyExecution(
        uint128 shares,
        uint128 value,
        uint128 fee,
        uint256 inputSpent,
        uint256 outputTransferred,
        bool asNative
    ) external {
        buyExecution = Execution({
            shares: shares, value: value, fee: fee, inputSpent: inputSpent, outputTransferred: outputTransferred
        });
        deliverBuyOutputAsNative = asNative;
    }

    function getConfig() external view returns (HanjiMarketConfig memory config) {
        return _config;
    }

    function placeOrder(
        bool isAsk,
        uint128 quantity,
        uint72 price,
        uint128 maxCommission,
        bool marketOnly,
        bool postOnly,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint64 orderId, uint128 executedShares, uint128 executedValue, uint128 aggressiveFee) {
        lastIsAsk = isAsk;
        lastQuantity = quantity;
        lastPrice = price;
        lastMaxCommission = maxCommission;
        lastMarketOnly = marketOnly;
        lastPostOnly = postOnly;
        lastTransferExecutedTokens = transferExecutedTokens;
        lastExpires = expires;

        Execution memory execution = sellExecution;
        if (execution.inputSpent != 0) {
            require(MockERC20(_config.tokenX).transferFrom(msg.sender, address(this), execution.inputSpent));
        }
        if (execution.outputTransferred != 0) {
            require(MockERC20(_config.tokenY).transfer(msg.sender, execution.outputTransferred));
        }
        return (0, execution.shares, execution.value, execution.fee);
    }

    function placeMarketOrderWithTargetValue(
        bool isAsk,
        uint128 targetTokenYValue,
        uint72 price,
        uint128 maxCommission,
        bool transferExecutedTokens,
        uint256 expires
    ) external payable returns (uint128 executedShares, uint128 executedValue, uint128 aggressiveFee) {
        lastIsAsk = isAsk;
        lastTargetTokenYValue = targetTokenYValue;
        lastPrice = price;
        lastMaxCommission = maxCommission;
        lastTransferExecutedTokens = transferExecutedTokens;
        lastExpires = expires;

        Execution memory execution = buyExecution;
        if (execution.inputSpent != 0) {
            require(MockERC20(_config.tokenY).transferFrom(msg.sender, address(this), execution.inputSpent));
        }
        if (execution.outputTransferred != 0) {
            if (deliverBuyOutputAsNative) {
                (bool success,) = msg.sender.call{value: execution.outputTransferred}("");
                require(success, "NATIVE_TRANSFER");
            } else {
                require(MockERC20(_config.tokenX).transfer(msg.sender, execution.outputTransferred));
            }
        }
        return (execution.shares, execution.value, execution.fee);
    }
}
