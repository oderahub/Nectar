// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISwapRouter
/// @notice Minimal Uniswap V3 SwapRouter interface — only exactInputSingle.
/// @dev Celo mainnet: 0x5615CDAb3dDc9B98bF3031aA4BfA784364D36806
interface ISwapRouter {
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

    /// @notice Swaps `amountIn` of one token for as much as possible of another.
    /// @param params The parameters necessary for the swap.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}
