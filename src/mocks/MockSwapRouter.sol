// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title MockSwapRouter
/// @notice Simplified Uniswap V3 SwapRouter mock for unit testing NectarVault.
///         Simulates a 1:1 swap rate by default (configurable via setRate).
contract MockSwapRouter {
    /// @dev Exchange rate in basis points (10_000 = 1:1)
    uint256 public rateBps = 10_000;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut)
    {
        // Pull input tokens
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Calculate output with configured rate
        amountOut = params.amountIn * rateBps / 10_000;

        require(amountOut >= params.amountOutMinimum, "MockSwap: slippage exceeded");

        // Transfer output tokens (must be pre-funded in this mock)
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }

    // ─── Test Helpers ────────────────────────────────────────────────────────

    /// @dev Set the exchange rate in basis points (10000 = 1:1, 9500 = 5% loss)
    function setRate(uint256 _rateBps) external {
        rateBps = _rateBps;
    }
}
