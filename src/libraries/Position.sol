// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { LiquidityMath } from "./LiquidityMath.sol";
import { FixedPoint128 } from "./FixedPoint128.sol";
import "prb-math/Core.sol";

library Position {
    struct Info {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /**
     * @dev Update the liquidity of the smart pool and calculate any fees owed to the liquidity provider.
     * Updates the liquidity of the smart pool with the given liquidity delta. It also calculates any fees owed to the
     * liquidity provider based on the difference in the fee growth between the last update and the current update.
     * @param self A reference to the struct `Position.Info`, which stores information about the smart pool's liquidity.
     * @param liquidityDelta The amount of liquidity to be added or removed from the smart pool.
     * @param feeGrowthInside0X128 The accumulated fee growth of token0 inside the tick range.
     * @param feeGrowthInside1X128 The accumulated fee growth of token1 inside the tick range.
     */

    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        uint128 tokensOwed0 = uint128(
            mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, self.liquidity, FixedPoint128.Q128)
        );
        uint128 tokensOwed1 = uint128(
            mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, self.liquidity, FixedPoint128.Q128)
        );

        self.liquidity = LiquidityMath.addLiquidity(self.liquidity, liquidityDelta);
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }

    /**
     * @dev Retrieve the position information of an owner in the smart pool for a specific range of ticks.
     * @param _self A mapping of bytes32 to a struct `Info` which stores information about the smart pool.
     * @param _owner The address of the owner whose position is to be retrieved.
     * @param _lowerTick An integer (int24) representing the lower bound of the tick range.
     * @param _upperTick An integer (int24) representing the upper bound of the tick range.
     * @return position Position of the owner in the smart pool for the specified tick range.
     */
    function get(
        mapping(bytes32 => Info) storage _self,
        address _owner,
        int24 _lowerTick,
        int24 _upperTick
    ) internal view returns (Position.Info storage position) {
        position = _self[keccak256(abi.encodePacked(_owner, _lowerTick, _upperTick))];
    }
}
