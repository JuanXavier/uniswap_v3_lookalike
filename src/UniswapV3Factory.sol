// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import { IUniswapV3PoolDeployer } from "./interfaces/IUniswapV3PoolDeployer.sol";
import { UniswapV3Pool } from "./UniswapV3Pool.sol";

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    ///////////////////////////////////////////////
    //            ERRORS AND EVENTS
    ///////////////////////////////////////////////
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedFee();

    event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, address pool);

    PoolParameters public parameters;

    /// @dev Maps the tokens and fees of a pool to the pool contract address.
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;
    mapping(uint24 => uint24) public fees;

    constructor() {
        fees[500] = 10;
        fees[3000] = 60;
    }

    /**
     * @notice Creates a new Uniswap V3 pool with the given tokens and fee.
     * @param tokenX The address of the first token.
     * @param tokenY The address of the second token.
     * @param fee The fee amount for the new pool.
     * @return The address of the newly created pool contract.
     */
    function createPool(
        address tokenX,
        address tokenY,
        uint24 fee
    ) public returns (address pool) {
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        if (fees[fee] == 0) revert UnsupportedFee();

        // Sort tokens by smaller-to-larger address
        (tokenX, tokenY) = tokenX < tokenY ? (tokenX, tokenY) : (tokenY, tokenX);

        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        if (pools[tokenX][tokenY][fee] != address(0)) revert PoolAlreadyExists();

        parameters = PoolParameters({
            factory: address(this),
            token0: tokenX,
            token1: tokenY,
            tickSpacing: fees[fee],
            fee: fee
        });

        pool = address(new UniswapV3Pool{ salt: keccak256(abi.encodePacked(tokenX, tokenY, fee)) }());

        delete parameters;

        pools[tokenX][tokenY][fee] = pool;
        pools[tokenY][tokenX][fee] = pool;

        emit PoolCreated(tokenX, tokenY, fee, pool);
    }
}
