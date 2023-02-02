// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import { IUniswapV3Pool } from "./lib/interfaces/IUniswapV3Pool.sol";
import { Path } from "./lib/Path.sol";
import { PoolAddress } from "./lib/PoolAddress.sol";
import { TickMath } from "./lib/TickMath.sol";

/**
 * @title UniswapV3Quoter
 * @dev Contract that provides a way to quote prices for UniswapV3 swap paths
 */
contract UniswapV3Quoter {
    using Path for bytes;

    /**
     * @dev A struct that stores parameters for a single UniswapV3 swap quote
     */
    struct QuoteSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @dev The address of the UniswapV3 factory contract
     */
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    /**
     * @dev Quote prices for an UniswapV3 swap path
     * @param path A bytes object representing an UniswapV3 swap path
     * @param amountIn An unsigned integer (uint256) representing the amount of tokenIn to be swapped
     * @return A tuple of:
     *    amountOut: uint256 representing the amount of tokenOut received after swapping
     *    sqrtPriceX96AfterList: An array of uint160 representing the √(price ratio) after each swap in the path
     *    tickAfterList: An array of int24 representing the tick index after each swap in the path
     */
    function quote(bytes memory path, uint256 amountIn)
        public
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            int24[] memory tickAfterList
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        tickAfterList = new int24[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();

            (uint256 amountOut_, uint160 sqrtPriceX96After, int24 tickAfter) = quoteSingle(
                QuoteSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: 0
                })
            );

            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            tickAfterList[i] = tickAfter;
            amountIn = amountOut_;
            i++;

            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                amountOut = amountIn;
                break;
            }
        }
    }

    function quoteSingle(QuoteSingleParams memory params)
        public
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            int24 tickAfter
        )
    {
        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.fee);

        bool zeroForOne = params.tokenIn < params.tokenOut;

        try
            pool.swap(
                +address(this),
                zeroForOne,
                params.amountIn,
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(address(pool))
            )
        {} catch (bytes memory reason) {
            return abi.decode(reason, (uint256, uint160, int24));
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory data
    ) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter, , , ) = IUniswapV3Pool(pool).slot0();

        assembly {
            // Load the current memory pointer into the variable "ptr".
            let ptr := mload(0x40)

            // Store the value of "amountOut" at the current memory position pointed to by "ptr".
            mstore(ptr, amountOut)

            // Store the value of "sqrtPriceX96After" at the memory position located 0x20 bytes after the current position pointed to by "ptr".
            mstore(add(ptr, 0x20), sqrtPriceX96After)

            // Store the value of "tickAfter" at the memory position located 0x40 bytes after the current position pointed to by "ptr".
            mstore(add(ptr, 0x40), tickAfter)

            // Revert the current transaction and return the data stored in the memory region from the current position pointed to by "ptr" to a length of 96 bytes.
            revert(ptr, 96)
        }
    }

    function getPool(
        address token0,
        address token1,
        uint24 fee
    ) internal view returns (IUniswapV3Pool pool) {
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, fee));
    }
}
