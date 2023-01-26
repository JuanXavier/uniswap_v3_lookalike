// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { UniswapV3Pool } from "../src/UniswapV3Pool.sol";

contract TestUtils {
    function encodeError(string memory error) internal pure returns (bytes memory encoded) {
        encoded = abi.encodeWithSignature(error);
    }

    function encodeExtra(
        address token0_,
        address token1_,
        address payer
    ) internal pure returns (bytes memory) {
        return abi.encode(UniswapV3Pool.CallbackData({ token0: token0_, token1: token1_, payer: payer }));
    }
}
