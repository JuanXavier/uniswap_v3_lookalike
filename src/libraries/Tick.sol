// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { LiquidityMath } from "./LiquidityMath.sol";

library Tick {
    struct Info {
        bool initialized;
        // total liquidity at tick
        uint128 liquidityGross;
        // amount of liqudiity added or subtracted when tick is crossed
        int128 liquidityNet;
    }

    /**
     * @dev Update the liquidity of a specific tick in a smart pool.
     * @param _self A mapping of integers (int24) to a struct `Tick.Info` which stores information about a specific tick in the smart pool.
     * @param _tick An integer (int24) representing the specific tick for which the liquidity is to be updated.
     * @param _liquidityDelta An unsigned integer (uint128) representing the amount of liquidity to be added or removed from the specific tick.
     */
    function _update(
        mapping(int24 => Tick.Info) storage _self,
        int24 _tick,
        int128 _liquidityDelta,
        bool _upper
    ) internal returns (bool flipped_) {
        // Access Tick.Info in storage mapping with the given _tick
        Tick.Info storage tickInfo = _self[_tick];

        // Get the liquidity of it
        uint128 liquidityBefore = tickInfo.liquidityGross;

        // Update liquidity with input _liquidity delta
        uint128 liquidityAfter = LiquidityMath.addLiquidity(liquidityBefore, _liquidityDelta);

        flipped_ = (liquidityAfter == 0) != (liquidityBefore == 0);

        // Initialize if uninitialized
        if (liquidityBefore == 0) tickInfo.initialized = true;

        tickInfo.liquidityGross = liquidityAfter;

        // Update the liquidity in storage
        tickInfo.liquidityNet = _upper
            ? int128(int256(tickInfo.liquidityNet) - _liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + _liquidityDelta);
    }

    function cross(mapping(int24 => Tick.Info) storage _self, int24 _tick)
        internal
        view
        returns (int128 liquidityDelta)
    {
        Tick.Info storage info = _self[_tick];
        liquidityDelta = info.liquidityNet;
    }
}
