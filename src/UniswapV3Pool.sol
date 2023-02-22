// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { Tick } from "./libraries/Tick.sol";
import { Oracle } from "./libraries/Oracle.sol";
import { TickMath } from "./libraries/TickMath.sol";
import { Position } from "./libraries/Position.sol";
import { TickBitmap } from "./libraries/TickBitmap.sol";
import { Math, SwapMath } from "./libraries/SwapMath.sol";
import { LiquidityMath } from "./libraries/LiquidityMath.sol";
import { FixedPoint128 } from "./libraries/FixedPoint128.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IUniswapV3MintCallback } from "./interfaces/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "./interfaces/IUniswapV3SwapCallback.sol";
import { IUniswapV3PoolDeployer } from "./interfaces/IUniswapV3PoolDeployer.sol";
import { IUniswapV3FlashCallback } from "./interfaces/IUniswapV3FlashCallback.sol";

import "prb-math/Core.sol";

//Position is a range betweeen 2 ticks

// Fee amounts are hundredths of the basis point. That is, 1 fee unit is 0.0001%, 500 is 0.05%, and 3000 is 0.3%.

/// Pools also track (L), which is the total liquidity provided by all price ranges that include current price.
contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    ///////////////////////////////////////////////
    //            ERRORS AND EVENTS
    ///////////////////////////////////////////////

    error InsufficientInputAmount();
    error InvalidTickRange();
    error ZeroLiquidity();
    error InvalidPriceLimit();
    error NotEnoughLiquidity();
    error FlashLoanNotPaid();
    error AlreadyInitialized();

    /* ------------------------------ */

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0_,
        uint256 amount1_
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0_,
        int256 amount1_,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );
    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    ///////////////////////////////////////////////
    //     STATE VARIABLES
    ///////////////////////////////////////////////

    // Minimum and maximum ticks
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Pool tokens contract addresses
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    // First slot will contain essential data
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
        // // Most recent observation index
        // uint16 observationIndex;
        // // Maximum number of observations
        // uint16 observationCardinality;
        // // Next maximum number of observations
        // uint16 observationCardinalityNext;
    }

    // Data structure for callback functions when interacting with Pool
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    /**
     * @dev Struct for maintaining the current state of a swap.
     * @param amountSpecifiedRemaining  Tracks the remaining amount of tokens to be bought by the pool.
     *                                  When zero, the swap is completed.
     * @param amountCalculated  calculated output amount by the contract.
     * @param sqrtPriceX96  new current price after
     * @param tick tick
     */
    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    /**
     * @dev Maintains the current state of a swap step. It tracks the state of one iteration of an “order filling”.
     * @param sqrtPriceStartX96  tracks the starting price of the iteration.
     * @param nextTick  the next initialized tick that will provide liquidity for the swap.
     * @param sqrtPriceNextX96  the price at the next tick.
     * @param amountIn  the amount that can be provided by the liquidity of the current iteration.
     * @param amountOut  the output amount that can be provided by the liquidity of the current iteration.
     */
    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        bool initialized;
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
    Oracle.Observation[65535] public observations;

    ///////////////////////////////////////////////
    //       CONSTRUCTOR
    ///////////////////////////////////////////////

    constructor() {
        (factory, token0, token1, tickSpacing, fee) = IUniswapV3PoolDeployer(msg.sender).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        slot0 = Slot0({ sqrtPriceX96: sqrtPriceX96, tick: tick });
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
     * @return amount0_ Amount of token0.
     * @return amount1_ Amount of token1.
     */
    function mint(
        address _owner,
        int24 _lowerTick,
        int24 _upperTick,
        uint128 _amount,
        bytes calldata _data
    ) external returns (uint256 amount0_, uint256 amount1_) {
        // Sanity checks for validating ticks and liquidity
        if (_lowerTick >= _upperTick || _lowerTick < MIN_TICK || _upperTick > MAX_TICK) revert InvalidTickRange();
        if (_amount == 0) revert ZeroLiquidity();

        // Update ticks for the range
        bool flippedLower = ticks.update(_lowerTick, int128(_amount), false);
        bool flippedUpper = ticks.update(_upperTick, int128(_amount), true);

        if (flippedLower) tickBitmap.flipTick(_lowerTick, 1);
        if (flippedUpper) tickBitmap.flipTick(_upperTick, 1);

        // Update the position
        Position.Info storage position = positions.get(_owner, _lowerTick, _upperTick);
        position.update(_amount);

        Slot0 memory slot0_ = slot0;

        /**
         * To support all the kinds of price ranges, we need to know whether the current price is
         *below, inside, or above the price range specified by user and calculate token amounts
         *accordingly. If the price range is above the current price, we want the liquidity to be composed of token x:
         */
        if (slot0_.tick < _lowerTick) {
            amount0_ = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(_lowerTick),
                TickMath.getSqrtRatioAtTick(_upperTick),
                _amount
            );
        }
        /**
         * When the price range includes the current price, we want both tokens in amounts proportional to the price
         * Notice that this is the only scenario where we want to update liquidity since the variable tracks
         * liquidity that’s available immediately.
         */
        else if (slot0_.tick < _upperTick) {
            amount0_ = Math.calcAmount0Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(_upperTick), _amount);

            amount1_ = Math.calcAmount1Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(_lowerTick), _amount);

            liquidity = LiquidityMath.addLiquidity(liquidity, int128(_amount));
            // TODO: amount is negative when removing liquidity
        }
        /*
         * In all other cases, when price range is below the current price, we want the range to contain only token y:
         */
        else {
            amount1_ = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(_lowerTick),
                TickMath.getSqrtRatioAtTick(_upperTick),
                _amount
            );
        }

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0_ > 0) balance0Before = _balance0();
        if (amount1_ > 0) balance1Before = _balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0_, amount1_, _data);
        if (amount0_ > 0 && balance0Before + amount0_ > _balance0()) revert InsufficientInputAmount();
        if (amount1_ > 0 && balance1Before + amount1_ > _balance1()) revert InsufficientInputAmount();

        emit Mint(msg.sender, _owner, _lowerTick, _upperTick, _amount, amount0_, amount1_);
    }

    /////////////////////////////////////////////////////////////////
    //                       MODIFY
    /////////////////////////////////////////////////////////////////

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        // gas optimizations
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;

        position = positions.get(params.owner, params.lowerTick, params.upperTick);

        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            false
        );
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true
        );

        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            params.lowerTick,
            params.upperTick,
            slot0_.tick,
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_
        );

        position.update(params.liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        if (slot0_.tick < params.lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                slot0_.sqrtPriceX96,
                params.liquidityDelta
            );

            liquidity = LiquidityMath.addLiquidity(liquidity, params.liquidityDelta);
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    /////////////////////////////////////////////////////////////////
    //                       BURN
    /////////////////////////////////////////////////////////////////

    function burn(
        int24 lowerTick,
        int24 upperTick,
        uint128 amount
    ) public returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: -(int128(amount))
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }

    /////////////////////////////////////////////////////////////////
    //                       COLLECT
    /////////////////////////////////////////////////////////////////

    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(msg.sender, lowerTick, upperTick);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, lowerTick, upperTick, amount0, amount1);
    }

    /////////////////////////////////////////////////////////////////
    //                     SWAP
    /////////////////////////////////////////////////////////////////

    /**
     * @dev Function to execute a swap between two tokens in a smart pool.
     * @param recipient Address of the recipient to receive the output tokens.
     * @param zeroForOne Flag to control swap direction. IF true, token0 is traded in for token1;
     * if false, it’s the opposite.
     * @param amountSpecified Unsigned integer representing the amount of the input token specified for the swap.
     * @param sqrtPriceLimitX96 Unsigned integer (uint160) representing the limit of the sqrt price.
     * @param data A byte array to pass extra data for the swap.
     * @return amount0_ A byte array to pass extra data for the swap.
     * @return amount1_  A byte array to pass extra data for the swap.
     */
    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public returns (int256 amount0_, int256 amount1_) {
        // Caching for gas saving
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;

        // When selling token x (zeroForOne is true), sqrtPriceLimitX96 must be between
        // the current price and the minimal √P since selling token X moves the price down.
        // Likewise, when selling token y, sqrtPriceLimitX96 must be between
        // the current price and the maximal √P because price moves up.
        if (
            zeroForOne
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 || sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 || sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        // Declare a new swap state
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: liquidity_
        });

        // Loop until amountSpecifiedRemaining is 0, which will mean that the pool has enough liquidity to buy
        // amountSpecified tokens from user.
        // we set up a price range that should provide liquidity for the swap
        // The range is from state.sqrtPriceX96 to step.sqrtPriceNextX96,
        // where the latter is the price at the next initialized tick
        // (as returned by nextInitializedTickWithinOneWord.
        // Two conditions:
        // 1. Full swap amount has not been filled, and
        // 2. Current price isn’t equal to sqrtPriceLimitX96
        //Uniswap V3 pools don’t fail when slippage tolerance gets hit and simply executes swap partially.
        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            // Declare a new swap step
            StepState memory step;

            // Assign the START PRICE from the swap state
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // Look out for the next initialized tick in the tickBitmap mapping
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(state.tick, int24(tickSpacing), zeroForOne);

            // Get the NEXT PRICE at tick obtained in previous calculation
            //  equation ===> ( sqrt(1.0001^tick) * 2^96 )
            // A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
            // at the given tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            // Compute the price, amountIn and amountOut
            // we’re calculating: the amounts that can be provided by the current price range,
            // and the new current price the swap will result in.
            // ensure that computeSwapStep never calculates swap amounts outside of sqrtPriceLimitX96
            // this guarantees that the current price will never cross the limiting price.
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            //  amount of tokens the price range can buy from user
            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;

            // related number of the other token the pool can sell to user
            state.amountCalculated += step.amountOut;

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            // state.sqrtPriceX96 is the new current price, i.e. the price that will be set after the current swap
            // step.sqrtPriceNextX96 is the price at the next initialized tick
            // If these are equal, we have reached a price range boundary
            //  when this happens, we want to update  L (add or remove liquidity)
            // and continue the swap using the boundary tick as the current tick.

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                    (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                );

                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta);

                if (state.liquidity == 0) revert NotEnoughLiquidity();

                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        //
        if (state.tick != slot0_.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0_.observationIndex,
                _blockTimestamp(),
                slot0_.tick,
                slot0_.observationCardinality,
                slot0_.observationCardinalityNext
            );

            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        ///
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;

        // Update the global fee trackers
        if (zeroForOne) feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        else feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;

        // Calculate swap amounts based on swap direction and the amounts calculated during the swap loop.
        (amount0_, amount1_) = zeroForOne
            ? (int256(amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(amountSpecified - state.amountSpecifiedRemaining));

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1_));

            uint256 balance0Before = _balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0_, amount1_, data);
            if (balance0Before + uint256(amount0_) > _balance0()) revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0_));

            uint256 balance1Before = _balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0_, amount1_, data);
            if (balance1Before + uint256(amount1_) > _balance1()) revert InsufficientInputAmount();
        }

        emit Swap(msg.sender, recipient, amount0_, amount1_, slot0.sqrtPriceX96, state.liquidity, slot0.tick);
    }

    /////////////////////////////////////////////////////////////////
    //                  FLASH LOANS
    /////////////////////////////////////////////////////////////////

    /**
     * @notice Executes a flash swap of tokens from this contract to the caller's address,
     * invoking `uniswapV3FlashCallback()` on the caller with the swap's fee and additional data.
     * @param amount0 The amount of token0 to swap from this contract to the caller's address.
     * @param amount1 The amount of token1 to swap from this contract to the caller's address.
     * @param data Additional data to pass to the `uniswapV3FlashCallback` function.
     * @dev The caller must implement the `uniswapV3FlashCallback` function to receive the flash swap results.
     * @dev This function charges a fee on the amount of tokens swapped, calculated as `fee` / 1e6,
     * and transfers the fee to this contract.
     * @dev If the flash swap succeeds, this function emits a `Flash` event.
     * @dev If the flash swap fails, this function reverts and emits a `FlashLoanNotPaid` event.
     */

    function flash(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        if (IERC20(token0).balanceOf(address(this)) < balance0Before + fee0) revert FlashLoanNotPaid();
        if (IERC20(token1).balanceOf(address(this)) < balance1Before + fee1) revert FlashLoanNotPaid();

        emit Flash(msg.sender, amount0, amount1);
    }

    /////////////////////////////////////////////////////////////////
    //                       OBSERVE
    /////////////////////////////////////////////////////////////////

    function observe(uint32[] calldata secondsAgos) public view returns (int56[] memory tickCumulatives) {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            );
    }

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) public {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );

        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
        }
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

    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
    }
}
