// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SafeTransferLib {
    error BalanceQueryFailed(address token);
    error TransferFailed(address token);
    error TransferFromFailed(address token);
    error ApproveFailed(address token);

    function safeBalanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory result) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!success || result.length != 32) revert BalanceQueryFailed(token);
        balance = abi.decode(result, (uint256));
    }

    function safeTransfer(address token, address to, uint256 amount) internal {
        if (!_callOptionalBool(token, abi.encodeWithSelector(0xa9059cbb, to, amount))) {
            revert TransferFailed(token);
        }
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (!_callOptionalBool(token, abi.encodeWithSelector(0x23b872dd, from, to, amount))) {
            revert TransferFromFailed(token);
        }
    }

    function forceApprove(address token, address spender, uint256 amount) internal {
        if (_callOptionalBool(token, abi.encodeWithSelector(0x095ea7b3, spender, amount))) return;
        if (!_callOptionalBool(token, abi.encodeWithSelector(0x095ea7b3, spender, 0))) {
            revert ApproveFailed(token);
        }
        if (!_callOptionalBool(token, abi.encodeWithSelector(0x095ea7b3, spender, amount))) {
            revert ApproveFailed(token);
        }
    }

    function _callOptionalBool(address token, bytes memory callData) private returns (bool) {
        (bool success, bytes memory result) = token.call(callData);
        return success && (result.length == 0 || (result.length == 32 && abi.decode(result, (bool))));
    }
}
