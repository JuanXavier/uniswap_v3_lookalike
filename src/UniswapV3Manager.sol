// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import { Path } from "./libraries/Path.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { PoolAddress } from "./libraries/PoolAddress.sol";
import { IUniswapV3Pool } from "./interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Manager } from "./interfaces/IUniswapV3Manager.sol";
import { LiquidityMath, UniswapV3Pool, IERC20, TickMath } from "../src/UniswapV3Pool.sol";

contract UniswapV3Manager is IUniswapV3Manager {
    error SlippageCheckFailed(uint256 amount0, uint256 amount1);
    error TooLittleReceived(uint256 amountOut);

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function getPool(
        address token0,
        address token1,
        uint24 tickSpacing
    ) internal view returns (IUniswapV3Pool pool) {
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, tickSpacing));
    }

    /////////////////////////////////////////////////////////////////
    //                        MINT
    /////////////////////////////////////////////////////////////////
    function mint(MintParams calldata params) public returns (uint256 amount0, uint256 amount1) {
        // Get the address of the pool and declare it
        address poolAddress = PoolAddress.computeAddress(factory, params.tokenA, params.tokenB, params.tickSpacing);
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        //
        (uint160 sqrtPriceX96, ) = pool.slot0();
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(params.lowerTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(params.upperTick);

        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            params.amount0Desired,
            params.amount1Desired
        );

        (amount0, amount1) = pool.mint(
            msg.sender,
            params.lowerTick,
            params.upperTick,
            liquidity,
            abi.encode(IUniswapV3Pool.CallbackData({ token0: pool.token0(), token1: pool.token1(), payer: msg.sender }))
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert SlippageCheckFailed(amount0, amount1);
    }

    /////////////////////////////////////////////////////////////////
    //                         SWAPS
    /////////////////////////////////////////////////////////////////

    function swapSingle(SwapSingleParams calldata params) public returns (uint256 amountOut) {
        amountOut = _swap(
            params.amountIn,
            msg.sender,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenIn, params.tickSpacing, params.tokenOut),
                payer: msg.sender
            })
        );
    }

    function swap(SwapParams memory params) public returns (uint256 amountOut) {
        address payer = msg.sender;
        bool hasMultiplePools;

        while (true) {
            hasMultiplePools = params.path.hasMultiplePools();

            // Track the input amounts
            params.amountIn = _swap(
                params.amountIn, // amountIn
                hasMultiplePools ? address(this) : params.recipient, // recipient
                0, //price limit set to 0 to disable slippage protection in the Pool contract
                SwapCallbackData({ path: params.path.getFirstPool(), payer: payer })
            );

            // If there are multiple pools, recipient is the manager contract, it’ll store tokens between swaps
            if (hasMultiplePools) {
                payer = address(this);

                // Remove a processed pool from the path
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        // Slippage protection
        if (amountOut < params.minAmountOut) revert TooLittleReceived(amountOut);
    }

    function _swap(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) internal returns (uint256 amountOut) {
        (address tokenIn, address tokenOut, uint24 tickSpacing) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, tickSpacing).swap(
            recipient,
            zeroForOne,
            amountIn,
            sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            abi.encode(data)
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    /////////////////////////////////////////////////////////////////
    //                       CALLBACKS
    /////////////////////////////////////////////////////////////////

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        UniswapV3Pool.CallbackData memory extra = abi.decode(data, (UniswapV3Pool.CallbackData));
        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3FlashCallback(bytes calldata data) public {
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));
        if (amount0 > 0) token0.transfer(msg.sender, amount0);
        if (amount1 > 0) token1.transfer(msg.sender, amount1);
    }

    //  expects encoded SwapCallbackData with path and payer address.
    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data_
    ) public {
        // Extract pool tokens from the path
        SwapCallbackData memory data = abi.decode(data_, (SwapCallbackData));
        (address tokenIn, address tokenOut, ) = data.path.decodeFirstPool();

        // Figure out swap direction
        bool zeroForOne = tokenIn < tokenOut;
        int256 amount = zeroForOne ? amount0 : amount1;

        // If payer is the current contract (true when making consecutive swaps),
        // transfer tokens to the next pool (the one that called this callback) from current contract’s balance.
        if (data.payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, uint256(amount));
        }
        // If payer is a different address (the user that initiated the swap), it transfers tokens from user’s balance.
        else {
            IERC20(tokenIn).transferFrom(data.payer, msg.sender, uint256(amount));
        }
    }
}
