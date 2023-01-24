// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

library Position {
    struct Info {
        uint128 liquidity;
    }

    /**
     * @dev Update the liquidity of the smart pool.
     * @param _self A struct Position.Info which stores information about the smart pool's liquidity.
     * @param _liquidityDelta An unsigned integer (uint128) representing the amount of liquidity to be added or removed from the smart pool.
     */
    function _update(Info storage _self, uint128 _liquidityDelta) internal {
        uint128 liquidityBefore = _self.liquidity;
        uint128 liquidityAfter = liquidityBefore + _liquidityDelta;
        _self.liquidity = liquidityAfter;
    }

    /**
     * @dev Retrieve the position information of an owner in the smart pool for a specific range of ticks.
     * @param _self A mapping of bytes32 to a struct `Info` which stores information about the smart pool.
     * @param _owner The address of the owner whose position is to be retrieved.
     * @param _lowerTick An integer (int24) representing the lower bound of the tick range.
     * @param _upperTick An integer (int24) representing the upper bound of the tick range.
     * @return position Position.Info struct representing the position of the owner in the smart pool for the specified tick range.
     */
    function _get(
        mapping(bytes32 => Info) storage _self,
        address _owner,
        int24 _lowerTick,
        int24 _upperTick
    ) internal view returns (Position.Info storage position) {
        position = _self[keccak256(abi.encodePacked(_owner, _lowerTick, _upperTick))];
    }
}
