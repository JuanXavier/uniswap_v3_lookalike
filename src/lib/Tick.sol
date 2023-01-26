// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidity;
    }

    /**
     * @dev Update the liquidity of a specific tick in a smart pool.
     * @param _self A mapping of integers (int24) to a struct `Tick.Info` which stores information about a specific tick in the smart pool.
     * @param _tick An integer (int24) representing the specific tick for which the liquidity is to be updated.
     * @param _liquidityDelta An unsigned integer (uint128) representing the amount of liquidity to be added or removed from the specific tick.
     */
    // prettier-ignore
    function _update(mapping(int24 => Tick.Info) storage _self, int24 _tick, uint128 _liquidityDelta) internal {
        // Access Tick.Info in storage mapping with the given _tick
        Tick.Info storage tickInfo = _self[_tick];
        
        // Get the liquidity of it 
        uint128 liquidityBefore = tickInfo.liquidity;
        
        // Update liquidity with input _liquidity delta
        uint128 liquidityAfter = liquidityBefore + _liquidityDelta;

        // Initialize if uninitialized
        if (liquidityBefore == 0) tickInfo.initialized = true;
        
        // Update the liquidity in storage
        tickInfo.liquidity = liquidityAfter;
    }
}
