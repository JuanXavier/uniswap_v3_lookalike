// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "./lib/interfaces/IERC20.sol";
import { IUniswapV3MintCallback } from "./lib/interfaces/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "./lib/interfaces/IUniswapV3SwapCallback.sol";

import { Position } from "./lib/Position.sol";
import { Tick } from "./lib/Tick.sol";

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    ///////////////////////////////////////////////
    //            ERRORS
    ///////////////////////////////////////////////

    error InsufficientInputAmount();
    error InvalidTickRange();
    error ZeroLiquidity();

    ///////////////////////////////////////////////
    //             EVENTS
    ///////////////////////////////////////////////

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    ///////////////////////////////////////////////
    //     STATE VARIABLES
    ///////////////////////////////////////////////

    // Minimum and maximum ticks
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Pool tokens contract addresses
    address public immutable token0;
    address public immutable token1;

    // First slot will contain essential data
    struct Slot0 {
        uint160 sqrtPriceX96; // Current sqrt(P)
        int24 tick; // Current tick
    }
    Slot0 public slot0;

    // Data structure for callback functions when interacting with Pool
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    // Liquidity, ticks and positions
    uint128 public liquidity;
    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    ///////////////////////////////////////////////
    //       CONSTRUCTOR
    ///////////////////////////////////////////////

    constructor(
        address _token0,
        address _token1,
        uint160 _sqrtPriceX96,
        int24 _tick
    ) {
        token0 = _token0;
        token1 = _token1;
        slot0 = Slot0({ sqrtPriceX96: _sqrtPriceX96, tick: _tick });
    }

    ///////////////////////////////////////////////
    //           EXTERNAL
    ///////////////////////////////////////////////

    /*********************** MINT ******************** */

    /**
     * @dev mint tokens for liquidity providers
     * @param _owner The address of the owner of the tokens.
     * @param _lowerTick Lower tick of the liquidity provision range.
     * @param _upperTick Upper tick of the liquidity provision range.
     * @param _amount The amount of liquidity being provided.
     * @param _data Additional data passed through the call.
     * @return amount0 Amount of token0.
     * @return amount1 Amount of token1.
     */
    function mint(
        address _owner,
        int24 _lowerTick,
        int24 _upperTick,
        uint128 _amount,
        bytes calldata _data
    ) external returns (uint256 amount0, uint256 amount1) {
        // Sanity checks for validating ticks and liquidity
        if (_lowerTick >= _upperTick || _lowerTick < MIN_TICK || _upperTick > MAX_TICK) revert InvalidTickRange();
        if (_amount == 0) revert ZeroLiquidity();

        // Update ticks for the range
        ticks._update(_lowerTick, _amount);
        ticks._update(_upperTick, _amount);

        // Update the position
        Position.Info storage position = positions._get(_owner, _lowerTick, _upperTick);
        position._update(_amount);

        // Declare the amounts
        amount0 = 0.998976618347425280 ether; // TODO: replace with calculation
        amount1 = 5000 ether; // TODO: replace with calculation

        // Update the liquidity
        liquidity += uint128(_amount);

        // Update balances from
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = _balance0();
        if (amount1 > 0) balance1Before = _balance1();

        // Make external call to sender contract (manager)
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, _data);

        if (amount0 > 0 && balance0Before + amount0 > _balance0()) revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > _balance1()) revert InsufficientInputAmount();

        emit Mint(msg.sender, _owner, _lowerTick, _upperTick, _amount, amount0, amount1);
    }

    /*********************** SWAP ******************** */
    function swap(address _recipient, bytes calldata _data) public returns (int256 amount0, int256 amount1) {
        int24 nextTick = 85184;
        uint160 nextPrice = 5604469350942327889444743441197;

        amount0 = -0.008396714242162444 ether;
        amount1 = 42 ether;

        (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);

        IERC20(token0).transfer(_recipient, uint256(-amount0));

        uint256 balance1Before = _balance1();
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, _data);
        if (balance1Before + uint256(amount1) > _balance1()) revert InsufficientInputAmount();

        emit Swap(msg.sender, _recipient, amount0, amount1, slot0.sqrtPriceX96, liquidity, slot0.tick);
    }

    ///////////////////////////////////////////////
    //          INTERNAL
    ///////////////////////////////////////////////
    function _balance0() internal view returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function _balance1() internal view returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
