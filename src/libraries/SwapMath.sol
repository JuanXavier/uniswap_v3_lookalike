// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import { Math } from "./Math.sol";

library SwapMath {
    /**
     * @dev Core logic of swapping. Computes the next step of a swap. It calculates swap amounts within one price range and respecting available liquidity.
     * @param _sqrtPriceCurrentX96 The current square root of price.
     * @param _sqrtPriceTargetX96 The target square root of price.
     * @param _liquidity The current liquidity.
     * @param _amountRemaining The amount remaining to be swapped.
     * @return sqrtPriceNextX96_ The next square root of new price.
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
        // Compare the square root of the current price with the target square root of price
        bool zeroForOne = _sqrtPriceCurrentX96 >= _sqrtPriceTargetX96;

        // Calculate the input amount the range can satisfy
        amountIn_ = zeroForOne
            ? Math.calcAmount0Delta(_sqrtPriceCurrentX96, _sqrtPriceTargetX96, _liquidity)
            : Math.calcAmount1Delta(_sqrtPriceCurrentX96, _sqrtPriceTargetX96, _liquidity);

        // Get the next square root of price by calling Math.getNextSqrtPriceFromInput and passing the current square root of price, the current liquidity and the amount remaining to be swapped and zeroForOne as arguments
        if (_amountRemaining >= amountIn_) sqrtPriceNextX96_ = _sqrtPriceTargetX96;
        else
            sqrtPriceNextX96_ = Math.getNextSqrtPriceFromInput(
                _sqrtPriceCurrentX96,
                _liquidity,
                _amountRemaining,
                zeroForOne
            );

        // Re Calculate the amount going into the swap by calling Math.calcAmount0Delta and passing the current square root of price, the next square root of price and the current liquidity as arguments
        amountIn_ = Math.calcAmount0Delta(_sqrtPriceCurrentX96, sqrtPriceNextX96_, _liquidity);

        // Calculate the amount going out of the swap by calling Math.calcAmount1Delta and passing the current square root of price, the next square root of price and the current liquidity as arguments
        amountOut_ = Math.calcAmount1Delta(_sqrtPriceCurrentX96, sqrtPriceNextX96_, _liquidity);

        // If the square root of the current price is not greater than or equal to the target square root of price, swap the values of amountIn_ and amountOut_
        if (!zeroForOne) (amountIn_, amountOut_) = (amountOut_, amountIn_);
    }
}
