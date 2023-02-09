// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "./TestUtils.sol";

abstract contract UniswapV3PoolUtils is Test, TestUtils {
    struct LiquidityRange {
        int24 upperTick;
        uint128 amount;
    }

    struct TestCaseParams {
        uint256 wethBalance;
        uint256 usdcBalance;
        uint256 currentPrice;
        LiquidityRange[] liquidity;
        bool transferInMintCallback;
        bool transferInSwapCallback;
        bool mintLiqudity;
    }

    function liquidityRange(
        uint256 _lowerPrice,
        uint256 _upperPrice,
        uint256 _amount0,
        uint256 _amount1,
        uint256 _currentPrice
    ) internal pure returns (LiquidityRange memory range_) {
        range_ = LiquidityRange({
            lowerTick: tick(_lowerPrice),
            upperTick: tick(_upperPrice),
            amount: LiquidityMath.getLiquidityForAmounts(
                sqrtP(_currentPrice),
                sqrtP(_lowerPrice),
                sqrtP(_upperPrice),
                _amount0,
                _amount1
            )
        });
    }

    function liquidityRange(
        uint256 _lowerPrice,
        uint256 _upperPrice,
        uint128 _amount
    ) internal pure returns (LiquidityRange memory range) {
        range = LiquidityRange({ lowerTick: tick(_lowerPrice), upperTick: tick(_upperPrice), amount: _amount });
    }
}
