// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import { BytesLib } from "bytes-utils/BytesLib.sol";

/**
 * @title BytesLibExt
 * @dev Library for extracting uint24 from bytes
 */
library BytesLibExt {
    /**
     * @notice Extracts a uint24 from a byte array
     * @param _bytes The byte array to extract the uint24 from
     * @param _start The start index of the uint24 in the byte array
     * @return tempUint The uint24 extracted from the byte array
     */
    function toUint24(bytes memory _bytes, uint256 _start) internal pure returns (uint24 tempUint) {
        require(_bytes.length >= _start + 3, "toUint24_outOfBounds");

        assembly {
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }
    }
}


library Path {
    using BytesLib for bytes;
    using BytesLibExt for bytes;

    /// @dev The length the bytes encoded address
    uint256 private constant ADDR_SIZE = 20;

    /// @dev The length the bytes encoded fee
    uint256 private constant FEE_SIZE = 3;

    /// @dev The offset of a single token address + fee
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + FEE_SIZE;

    /// @dev The offset of an encoded pool key (tokenIn + fee + tokenOut)
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;

    /// @dev The minimum length of a path that contains 2 or more pools;
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    /**
     * @notice Check if the provided path contains more than one pool
     * @param path The path to check
     * @return Whether the path contains more than one pool
     */
    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    /**
     * @notice Get the number of pools in the provided path
     * @param path The path to check
     * @return The number of pools in the path
     */
    function numPools(bytes memory path) internal pure returns (uint256) {
        return (path.length - ADDR_SIZE) / NEXT_OFFSET;
    }

    /**
     * @notice Get the first pool in the provided path
     * @param path The path to check
     * @return The first pool in the path
     */
    function getFirstPool(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(0, POP_OFFSET);
    }

    /**
     * @notice Skip the first token in the provided path
     * @param path The path to check
     * @return The path without the first token
     */
    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
    }

    /**
     * @notice Decode the first pool in the provided path
     * @param path The path to check
     * @return The addresses and fee of the first pool in the path
     */
    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (
            address tokenIn,
            address tokenOut,
            uint24 fee
        )
    {
        tokenIn = path.toAddress(0);
        fee = path.toUint24(ADDR_SIZE);
        tokenOut = path.toAddress(NEXT_OFFSET);
    }
}
}
