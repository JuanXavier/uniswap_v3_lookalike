// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    /**
     * @dev Computes the next step of a swap.
     * @param _sqrtPriceCurrentX96 The current square root of price.
     * @param _sqrtPriceTargetX96 The target square root of price.
     * @param _liquidity The current liquidity.
     * @param _amountRemaining The amount remaining to be swapped.
     * @return sqrtPriceNextX96_ The next square root of price.
     * @return amountIn_ amount going into the swap.
     * @return amountOut_ amount going out of the swap.
     */
    function computeSwapStep(
        uint160 _sqrtPriceCurrentX96,
        uint160 _sqrtPriceTargetX96,
        uint128 _liquidity,
        uint256 _amountRemaining
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96_,
            uint256 amountIn_,
            uint256 amountOut_
        )
    {
        bool zeroForOne = _sqrtPriceCurrentX96 >= _sqrtPriceTargetX96;

        sqrtPriceNextX96_ = Math.getNextSqrtPriceFromInput(
            _sqrtPriceCurrentX96,
            _liquidity,
            _amountRemaining,
            zeroForOne
        );

        amountIn_ = Math.calcAmount0Delta(_sqrtPriceCurrentX96, sqrtPriceNextX96_, _liquidity);
        amountOut_ = Math.calcAmount1Delta(_sqrtPriceCurrentX96, sqrtPriceNextX96_, _liquidity);

        if (!zeroForOne) (amountIn_, amountOut_) = (amountOut_, amountIn_);
    }
}
