// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { LiquidityMath } from "./LiquidityMath.sol";

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidityGross; // total liquidity at tick
        int128 liquidityNet; // amount of liqudiity added or subtracted when tick is crossed
        // fee growth on the other side of this tick (relative to the current tick)
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /**
     * @dev Update the liquidity of a specific tick in a smart pool.
     * @param _self A mapping which stores information about a specific tick in the smart pool.
     * @param _tick An integer (int24) representing the specific tick for which the liquidity is to be updated.
     * @param _liquidityDelta The amount of liquidity to be added or removed from the specific tick.
     */
    function update(
        mapping(int24 => Tick.Info) storage _self,
        int24 _tick,
        int24 _currentTick,
        int128 _liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool _upper
    ) internal returns (bool flipped_) {
        // Access Tick.Info in storage mapping with the given _tick
        Tick.Info storage tickInfo = _self[_tick];

        // Get the liquidity of it
        uint128 liquidityBefore = tickInfo.liquidityGross;

        // Update liquidity with input _liquidityDelta
        uint128 liquidityAfter = LiquidityMath.addLiquidity(liquidityBefore, _liquidityDelta);

        // If liquidityAfter == 0 and liquidityBefore != 0, or vice versa, then flipped_ will be set to true.
        // This indicates that the tick has flipped from being initialized to uninitialized, or viceversa.
        flipped_ = (liquidityAfter == 0) != (liquidityBefore == 0);

        // If its uninitialized, then initialize it
        if (liquidityBefore == 0) {
            // by convention, assume that all previous fees were collected belowthe tick
            if (_tick <= _currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }

            tickInfo.initialized = true;
        }

        // Update the liquidityGross of the tickInfo variable with the new gross liquidity value.
        tickInfo.liquidityGross = liquidityAfter;

        // Update the liquidityNet in storage.
        // If tickInfo.liquidityNet = _upper, then the liquidity provider has removed liquidity from the upper tick,
        // so the code subtracts _liquidityDelta from the current liquidityNet value.
        // If tickInfo.liquidityNet != _upper, then the liquidity provider has added liquidity to the lower tick,
        // so the code adds _liquidityDelta to the current liquidityNet value.
        tickInfo.liquidityNet = _upper
            ? int128(int256(tickInfo.liquidityNet) - _liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + _liquidityDelta);
    }

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

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerTick.feeGrowthOutside1X128;
        }

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
