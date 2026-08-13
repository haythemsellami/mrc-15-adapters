// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SignedDeltaMath {
    error NonNegativeDelta();

    function magnitude(int256 negativeDelta) internal pure returns (uint256) {
        if (negativeDelta >= 0) revert NonNegativeDelta();
        unchecked {
            return uint256(-(negativeDelta + 1)) + 1;
        }
    }
}
