// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import { UniswapV3Pool, IERC20 } from "./UniswapV3Pool.sol";

contract UniswapV3Manager {
    function mint(
        address poolAddress_,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        bytes calldata data
    ) public {
        UniswapV3Pool(poolAddress_).mint(msg.sender, lowerTick, upperTick, liquidity, data);
    }

    function swap(address poolAddress_, bytes calldata data) public {
        UniswapV3Pool(poolAddress_).swap(msg.sender, data);
    }

    ///////////////////////////////////////////////////////
    //       CALLBACKS START
    ///////////////////////////////////////////////////////

    /**
     * @dev called when minting liquidity
     */
    // prettier-ignore
    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) public {
            UniswapV3Pool.CallbackData memory extra = abi.decode(data, (UniswapV3Pool.CallbackData));
            if (amount0 > 0) IERC20(extra.token0).transferFrom(extra.payer, msg.sender, uint256(amount0));
            if (amount1 > 0) IERC20(extra.token1).transferFrom(extra.payer, msg.sender, uint256(amount1));
    }

    /**
     * @dev called when minting liquidity
     */
    // prettier-ignore
    function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata _data) public {
            // Decode input data to correct format (UniswapV3Pool.CallbackData)
            UniswapV3Pool.CallbackData memory extra = abi.decode(_data, (UniswapV3Pool.CallbackData));

            // Transfer tokens from payer to caller of this function (Should be UniV3Pool)
            IERC20(extra.token0).transferFrom(extra.payer, msg.sender, _amount0);
            IERC20(extra.token1).transferFrom(extra.payer, msg.sender, _amount1);
    }

    ///////////////////////////////////////////////////////
    //       CALLBACKS END
    ///////////////////////////////////////////////////////
}
