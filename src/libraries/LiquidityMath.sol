// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "prb-math/Core.sol";
import "./FixedPoint96.sol";

/// Calculate liquidity when token amounts and price ranges are known
// When a price range includes the current price, we calculate
// getLiquidityForAmount0 and getLiquidityForAmount1, and pick the smaller of them
library LiquidityMath {
    ///////////////////////////////////////////////
    ///       △x * (√P.upper * √P.lower)
    /// L =  ───────────────────────────
    ///         √P.upper - √P.lower
    ///////////////////////////////////////////////
    ///          amount0 * intermediate
    /// L =  ───────────────────────────────
    ///       sqrtPriceBX96 - sqrtPriceAX96
    ///////////////////////////////////////////////
    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        liquidity = uint128(mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    ///////////////////////////////////////////////
    ///                △y
    /// L =  ──────────────────────
    ///        √P.upper - √P.lower
    ///////////////////////////////////////////////
    ///                   amount1
    /// L =  ───────────────────────────────────
    ///        sqrtPriceBX96 - sqrtPriceAX96
    ///////////////////////////////////////////////
    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        liquidity = uint128(mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice Computes the liquidity corresponding to a given amount of tokens for a given price range.
     * @param sqrtPriceX96 The current square root price of the token0/token1 pair.
     * @param sqrtPriceAX96 The square root price of the token0/token1 pair at the lower price boundary of the range.
     * @param sqrtPriceBX96 The square root price of the token0/token1 pair at the upper price boundary of the range.
     * @param amount0 The amount of token0 to calculate liquidity for.
     * @param amount1 The amount of token1 to calculate liquidity for.
     * @return liquidity The computed liquidity.
     */
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        // When current price is below the lower bound of a price range
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        }
        // When current price is within a range, we’re picking the smaller L
        else if (sqrtPriceX96 <= sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        // When current price is above the price range
        else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function addLiquidity(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            z = x - uint128(-y);
        } else {
            z = x + uint128(y);
        }
    }
}
