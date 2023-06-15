// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { LiquidityMath } from "./LiquidityMath.sol";

library Tick {
    struct Info {
        bool initialized; // a boolean indicating whether or not the tick has been initialized.
        uint128 liquidityGross; // total liquidity at tick
        int128 liquidityNet; // amount of liqudiity added or subtracted when tick is crossed
        uint256 feeGrowthOutside0X128; // fee growth on the other side of this tick (relative to the current tick)
        uint256 feeGrowthOutside1X128; // fee growth on the other side of this tick (relative to the current tick)
    }

    /**
     * @dev Update the liquidity of a specific tick in a smart pool.
     * @param self A mapping which stores information about a specific tick in the smart pool.
     * @param tick Specific tick for which the liquidity is to be updated.
     * @param liquidityDelta The amount of liquidity to be added or removed from the specific tick.
     * @param feeGrowthGlobal0X128 The global fee growth of token0 in the pool.
     * @param feeGrowthGlobal1X128 The global fee growth of token1 in the pool.
     * @param upper A boolean indicating whether the tick is the upper or lower tick.
     * @return flipped_ A boolean indicating whether the tick is initialized or not.
     */
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper
    ) internal returns (bool flipped_) {
        // Access Tick.Info in storage mapping with the given tick
        Tick.Info storage tickInfo = self[tick];

        // Get the liquidity of that tick
        uint128 liquidityBefore = tickInfo.liquidityGross;

        // Update liquidity with input liquidityDelta
        uint128 liquidityAfter = LiquidityMath.addLiquidity(liquidityBefore, liquidityDelta);

        // If liquidityAfter == 0 and liquidityBefore != 0, or vice versa, then flipped_ will be set to true.
        // This indicates that the tick has flipped from being initialized to uninitialized, or viceversa.
        flipped_ = (liquidityAfter == 0) != (liquidityBefore == 0);

        // If its uninitialized, then initialize it
        if (liquidityBefore == 0) {
            // by convention, assume that all previous fees were collected belowthe tick
            if (tick <= currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }

            tickInfo.initialized = true;
        }

        // Update the liquidityGross of the tickInfo variable with the new gross liquidity value.
        tickInfo.liquidityGross = liquidityAfter;

        // Update the liquidityNet in storage.
        // If tickInfo.liquidityNet = upper, then the liquidity provider has removed liquidity from the upper tick,
        // so the code subtracts liquidityDelta from the current liquidityNet value.
        // If tickInfo.liquidityNet != upper, then the liquidity provider has added liquidity to the lower tick,
        // so the code adds liquidityDelta to the current liquidityNet value.
        tickInfo.liquidityNet = upper
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }

    /**
     * @dev Cross the specific tick of a smart pool. Update fee growth of the tick and return liquidityDelta.
     * @param self A mapping which stores information about a specific tick in the smart pool.
     * @param tick Specific tick for which to perform the cross operation.
     * @param feeGrowthGlobal0X128 Fee growth on the other side of the tick (relative to the current tick).
     * @param feeGrowthGlobal1X128 Fee growth on the other side of the tick (relative to the current tick).
     * @return liquidityDelta The amount of liquidity to be added or removed from the specific tick when it is crossed.
     */
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityDelta) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        liquidityDelta = info.liquidityNet;
    }

    /**
     * @dev Computes the amount of fee growth inside a tick range.
     * @param self Mapping of ticks to tick information.
     * @param lowerTick_ The lower tick of the range.
     * @param upperTick_ The upper tick of the range.
     * @param currentTick The current tick.
     * @param feeGrowthGlobal0X128 The global fee growth of token0.
     * @param feeGrowthGlobal1X128 The global fee growth of token1.
     * @return feeGrowthInside0X128 The fee growth inside the tick range for token0.
     * @return feeGrowthInside1X128 The fee growth inside the tick range for token1.
     */
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 lowerTick_,
        int24 upperTick_,
        int24 currentTick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Tick.Info storage lowerTick = self[lowerTick_];
        Tick.Info storage upperTick = self[upperTick_];

        /* -------------- FEE GROWTH ABOVE -------------- */

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;

        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerTick.feeGrowthOutside1X128;
        }

        /* -------------- FEE GROWTH BELOW -------------- */

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;

        if (currentTick < upperTick_) {
            feeGrowthAbove0X128 = upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperTick.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperTick.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }
}
