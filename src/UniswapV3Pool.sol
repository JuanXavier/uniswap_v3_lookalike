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
    ///////////////////////////////////////////////
    //                 LIBRARIES
    ///////////////////////////////////////////////
    using Position for Position.Info;
    using Tick for mapping(int24 => Tick.Info);
    using Oracle for Oracle.Observation[65535];
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);

    ///////////////////////////////////////////////
    //                  ERRORS
    ///////////////////////////////////////////////

    error ZeroLiquidity();
    error InvalidTickRange();
    error FlashLoanNotPaid();
    error InvalidPriceLimit();
    error NotEnoughLiquidity();
    error AlreadyInitialized();
    error InsufficientInputAmount();

    ///////////////////////////////////////////////
    //                  EVENTS
    ///////////////////////////////////////////////

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

    // Ticks and fees
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    // Data structure for callback functions when interacting with pool (this contract)
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    // First slot will contain essential data
    struct Slot0 {
        uint160 sqrtPriceX96; // Current sqrt(P)
        int24 tick; // Current tick
        uint16 observationIndex; // Most recent observation index
        uint16 observationCardinality; // Maximum number of observations
        uint16 observationCardinalityNext; // Next maximum number of observations
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
        uint256 feeAmount;
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
        uint256 feeGrowthGlobalX128;
        uint128 liquidity;
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

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    /////////////////////////////////////////////////////////////////
    //                     MINT
    /////////////////////////////////////////////////////////////////
    /**
     * @dev mint tokens for liquidity providers
     * @param owner The address of the owner of the liquidity.
     * @param lowerTick Lower tick of the liquidity provision range.
     * @param upperTick Upper tick of the liquidity provision range.
     * @param amount The amount of liquidity being provided.
     * @param data Additional data passed through the call.
     * @return amount0 Amount of token0.
     * @return amount1 Amount of token1.
     */

    // The process of providing liquidity in Uniswap V2 is called minting.
    // The reason is that the V2 pool contract mints tokens (LP-tokens) in exchange for liquidity.
    // V3 doesn’t do that, but it still uses the same name for the function.
    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        // Sanity checks for validating tick range and liquidity
        if (lowerTick >= upperTick || lowerTick < MIN_TICK || upperTick > MAX_TICK) revert InvalidTickRange();
        if (amount == 0) revert ZeroLiquidity();

        // todo
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = _balance0();
        if (amount1 > 0) balance1Before = _balance1();

        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        if (amount0 > 0 && balance0Before + amount0 > _balance0()) revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > _balance1()) revert InsufficientInputAmount();

        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
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

    // This function simply transfers tokens from a pool and ensures that only valid
    // amounts can be transferred (one cannot transfer out more than they burned + fees they earned).

    // There’s also a way to collect fees only without burning liquidity: burn 0 amount of liquidity and then
    //  call collect. During burning, the position will be updated and token amounts it owes will be updated as well.

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
