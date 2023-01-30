// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "./lib/interfaces/IERC20.sol";
import { IUniswapV3MintCallback } from "./lib/interfaces/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "./lib/interfaces/IUniswapV3SwapCallback.sol";

import { Math, SwapMath } from "./lib/SwapMath.sol";
import { Position } from "./lib/Position.sol";
import { Tick } from "./lib/Tick.sol";
import { TickMath } from "./lib/TickMath.sol";
import { TickBitmap } from "./lib/TickBitmap.sol";

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
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

    // Data structure for callback functions when interacting with Pool
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    // maintains current swap’s state.
    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    // maintains current swap step’s state.
    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    Slot0 public slot0;

    // Liquidity, ticks and positions
    uint128 public liquidity;
    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
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

    /////////////////////////////////////////////////////////////////
    //                     MINT
    /////////////////////////////////////////////////////////////////
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
        bool flippedLower = ticks._update(_lowerTick, _amount);
        bool flippedUpper = ticks._update(_upperTick, _amount);
        if (flippedLower) tickBitmap.flipTick(_lowerTick, 1);
        if (flippedUpper) tickBitmap.flipTick(_upperTick, 1);

        // Update the position
        Position.Info storage position = positions._get(_owner, _lowerTick, _upperTick);
        position._update(_amount);

        Slot0 memory slot0_ = slot0;

        // Declare the amounts
        amount0 = Math.calcAmount0Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(_upperTick),
            _amount
        );

        amount1 = Math.calcAmount1Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(_lowerTick),
            _amount
        );

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

    /////////////////////////////////////////////////////////////////
    //                     SWAP
    /////////////////////////////////////////////////////////////////

    function swap(
        address _recipient,
        bool _zeroForOne, //  flag that controls swap direction: when true, token0 is traded in for token1; when false, it’s the opposite
        uint256 _amountSpecified,
        bytes calldata _data
    ) public returns (int256 amount0_, int256 amount1_) {
        Slot0 memory slot0_ = slot0;

        // Declare a new swap state
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: _amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        // While the amount specified is greater than 0
        while (state.amountSpecifiedRemaining > 0) {
            // Declare a new swap step
            StepState memory step;

            // Assign the START PRICE from the swap state
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // Look out for the next tick in the tickBitmap mapping
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick, // tick
                1, // tickSpacing
                _zeroForOne // lte
            );

            // Get the NEXT PRICE at tick obtained in previous calculation
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            //
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
                step.sqrtPriceStartX96, // current price
                step.sqrtPriceNextX96, // target price
                liquidity, // liquidity of this pool
                state.amountSpecifiedRemaining // remaining
            );

            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }

        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        (amount0_, amount1_) = _zeroForOne
            ? (int256(_amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(_amountSpecified - state.amountSpecifiedRemaining));

        if (_zeroForOne) {
            IERC20(token1).transfer(_recipient, uint256(-amount1_));

            uint256 balance0Before = _balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0_, amount1_, _data);
            if (balance0Before + uint256(amount0_) > _balance0()) revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(_recipient, uint256(-amount0_));

            uint256 balance1Before = _balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0_, amount1_, _data);
            if (balance1Before + uint256(amount1_) > _balance1()) revert InsufficientInputAmount();
        }

        emit Swap(msg.sender, _recipient, amount0_, amount1_, slot0.sqrtPriceX96, liquidity, slot0.tick);
    }

    /////////////////////////////////////////////////////////////////
    //                  BALANCES
    /////////////////////////////////////////////////////////////////

    function _balance0() internal view returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function _balance1() internal view returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
