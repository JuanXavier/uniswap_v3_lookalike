// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./FixedPoint96.sol";
import "prb-math/Core.sol";

library Math {
    /**
     * @dev Finds △x
     * TODO: round down when removing liquidity
     * @param sqrtPriceAX96 The sqrt price A in 96 bits fixed point format.
     * @param sqrtPriceBX96 The sqrt price B in 96 bits fixed point format.
     * @param liquidity The amount of liquidity.
     * @return amount0 The amount of token0.
     */
    function calcAmount0Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        // Sort the prices to ensure we don’t underflow when subtracting.
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceAX96 == 0) revert();

        amount0 = divRoundingUp(
            mulDivRoundingUp(
                (uint256(liquidity) << FixedPoint96.RESOLUTION), // Convert liquidity to a Q96.64 number by multiplying it by 2**96
                (sqrtPriceBX96 - sqrtPriceAX96), // Multiply it by the difference of the prices
                sqrtPriceBX96 // and divide it by the bigger price
            ),
            sqrtPriceAX96 //Then, we divide by the smaller price
        );
    }

    /**
     * @dev Finds △y
     * TODO: round down when removing liquidity
     * @param sqrtPriceAX96 The sqrt price A in 96 bits fixed point format.
     * @param sqrtPriceBX96 The sqrt price B in 96 bits fixed point format.
     * @param liquidity The amount of liquidity.
     * @return amount1 The amount of token1.
     */
    function calcAmount1Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        amount1 = mulDivRoundingUp(liquidity, (sqrtPriceBX96 - sqrtPriceAX96), FixedPoint96.Q96);
    }

    /**
     * @dev Gets the next sqrt price from input, rounding up for amount0 and rounding down for amount1.
     * @param sqrtPriceX96 The current sqrt price in 96 bits fixed point format.
     * @param liquidity The amount of liquidity.
     * @param amountIn The amount of input.
     * @param zeroForOne Whether to calculate the price for amount0 or amount1.
     * @return sqrtPriceNextX96 The next sqrt price in 96 bits fixed point format.
     */
    function getNextSqrtPriceFromInput(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtPriceNextX96) {
        sqrtPriceNextX96 = zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPriceX96, liquidity, amountIn)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, liquidity, amountIn);
    }

    /**
     * @dev Gets the next sqrt price from amount0, rounding up.
     * @param sqrtPriceX96 The current sqrt price in 96 bits fixed point format.
     * @param liquidity The amount of liquidity.
     * @param amountIn The amount of input.
     * @return The next sqrt price in 96 bits fixed point format.
     */
    function getNextSqrtPriceFromAmount0RoundingUp(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountIn
    ) internal pure returns (uint160) {
        uint256 numerator = uint256(liquidity) << FixedPoint96.RESOLUTION;
        uint256 product = amountIn * sqrtPriceX96;

        // If product doesn't overflow, use the precise formula.
        if (product / amountIn == sqrtPriceX96) {
            uint256 denominator = numerator + product;
            if (denominator >= numerator) {
                return uint160(mulDivRoundingUp(numerator, sqrtPriceX96, denominator));
            }
        }

        // If product overflows, use a less precise formula.
        return uint160(divRoundingUp(numerator, (numerator / sqrtPriceX96) + amountIn));
    }

    /**
     * @dev Gets the next sqrt price from amount1, rounding down.
     *
     * @param sqrtPriceX96 The current sqrt price in 96 bits fixed point format.
     * @param liquidity The amount of liquidity.
     * @param amountIn The amount of input.
     * @return The next sqrt price in 96 bits fixed point format.
     */
    function getNextSqrtPriceFromAmount1RoundingDown(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountIn
    ) internal pure returns (uint160) {
        return sqrtPriceX96 + uint160((amountIn << FixedPoint96.RESOLUTION) / liquidity);
    }

    /**
     * @dev Calculates the result of a / b, rounding up.
     * @param a Integer A.
     * @param b Integer B,.
     * @param denominator The denominator.
     * @return result The result of a / b, rounded up.
     */
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    /**
     * @dev Calculates the result of a / b, rounding up.
     * @param numerator The numerator.
     * @param denominator The denominator.
     * @return result The result of a / b, rounded up.
     */
    function divRoundingUp(uint256 numerator, uint256 denominator) internal pure returns (uint256 result) {
        assembly {
            result := add(div(numerator, denominator), gt(mod(numerator, denominator), 0))
        }
    }
}
