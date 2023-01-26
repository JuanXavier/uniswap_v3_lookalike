// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";
import { TestUtils } from "./TestUtils.sol";

contract UniswapV3PoolTest is Test, TestUtils {
    ///////////////////////////////////////////////////////
    //                SETUP
    ///////////////////////////////////////////////////////
    ERC20Mintable token0;
    ERC20Mintable token1;
    UniswapV3Pool pool;

    bool transferInMintCallback = true;
    bool transferInSwapCallback = true;

    struct TestCaseParams {
        uint256 wethBalance;
        uint256 usdcBalance;
        int24 currentTick;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint160 currentSqrtP;
        bool transferInMintCallback;
        bool transferInSwapCallback;
        bool mintLiquidity;
    }

    function setUp() public {
        token0 = new ERC20Mintable("Ether", "ETH", 18);
        token1 = new ERC20Mintable("USDC", "USDC", 18);
    }

    ///////////////////////////////////////////////////////
    //                TESTING
    ///////////////////////////////////////////////////////

    function testMintSuccess() public {
        // Declare parameters for this test case
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176, // ╗ sqrt of P  = sqrt of y/x.
            lowerTick: 84222, //   ║  With those results, sqrt of Price = log (srqt of 1.0001 * results)
            upperTick: 86129, //   ╝ (1 for current, 1 for lower bound, 1 for upper bound)
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: true,
            transferInSwapCallback: true,
            mintLiquidity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = _setupTestCase(params);

        /// AMOUNTS
        uint256 expectedAmount0 = 0.998976618347425280 ether;
        uint256 expectedAmount1 = 5000 ether;
        assertEq(poolBalance0, expectedAmount0, "incorrect token0 deposited amount");
        assertEq(poolBalance1, expectedAmount1, "incorrect token1 deposited amount");
        assertEq(token0.balanceOf(address(pool)), expectedAmount0, "Incorrect token0 balance amount");
        assertEq(token1.balanceOf(address(pool)), expectedAmount1, "Incorrect token1 balance amount");

        /// KEY
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), params.lowerTick, params.upperTick));
        uint128 posLiquidity = pool.positions(positionKey);
        assertEq(posLiquidity, params.liquidity);

        // LOWER TICK
        (bool tickInitialized, uint128 tickLiquidity) = pool.ticks(params.lowerTick);
        assertTrue(tickInitialized);
        assertEq(tickLiquidity, params.liquidity);

        // UPPER TICK
        (tickInitialized, tickLiquidity) = pool.ticks(params.upperTick);
        assertTrue(tickInitialized);
        assertEq(tickLiquidity, params.liquidity);

        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(sqrtPriceX96, 5602277097478614198912276234240, "invalid current sqrtP");
        assertEq(tick, 85176, "invalid current tick");
        assertEq(pool.liquidity(), 1517882343751509868544, "invalid current liquidity");
    }

    function testMintInvalidTickRangeLower() public {
        pool = new UniswapV3Pool(address(token0), address(token1), uint160(1), 0);
        vm.expectRevert(encodeError("InvalidTickRange()"));
        pool.mint(address(this), -887273, 0, 0, "");
    }

    /**************************************** */

    function testMintInvalidTickRangeUpper() public {
        pool = new UniswapV3Pool(address(token0), address(token1), uint160(1), 0);
        vm.expectRevert(encodeError("InvalidTickRange()"));
        pool.mint(address(this), 0, 887273, 0, "");
    }

    /**************************************** */
    function testMintZeroLiquidity() public {
        pool = new UniswapV3Pool(address(token0), address(token1), uint160(1), 0);
        vm.expectRevert(encodeError("ZeroLiquidity()"));
        pool.mint(address(this), 0, 1, 0, "");
    }

    /**************************************** */

    function testMintInsufficientTokenBalance() public {
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 0,
            usdcBalance: 0,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: false,
            transferInSwapCallback: true,
            mintLiquidity: false
        });
        _setupTestCase(params);

        pool.mint(address(this), params.lowerTick, params.upperTick, params.liquidity, "");
        vm.expectRevert(encodeError("InsufficientInputAmount()"));
    }

    /***************** SWAPPING *********************** */

    function testSwapBuyEth() public {
        // Declare params
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: true,
            transferInSwapCallback: true,
            mintLiquidity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = _setupTestCase(params);

        uint256 swapAmount = 42 ether; // 42 USDC
        token1.mint(address(this), swapAmount);
        token1.approve(address(this), swapAmount);

        UniswapV3Pool.CallbackData memory extra = UniswapV3Pool.CallbackData({
            token0: address(token0),
            token1: address(token1),
            payer: address(this)
        });

        int256 userBalance0Before = int256(token0.balanceOf(address(this)));

        (int256 amount0Delta, int256 amount1Delta) = pool.swap(address(this), abi.encode(extra));

        assertEq(amount0Delta, -0.008396714242162444 ether, "invalid ETH out");
        assertEq(amount1Delta, 42 ether, "invalid USDC in");

        assertEq(
            token0.balanceOf(address(this)),
            uint256(userBalance0Before - amount0Delta),
            "invalid user ETH balance"
        );
        assertEq(token1.balanceOf(address(this)), 0, "invalid user USDC balance");

        assertEq(
            token0.balanceOf(address(pool)),
            uint256(int256(poolBalance0) + amount0Delta),
            "invalid pool ETH balance"
        );
        assertEq(
            token1.balanceOf(address(pool)),
            uint256(int256(poolBalance1) + amount1Delta),
            "invalid pool USDC balance"
        );

        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(sqrtPriceX96, 5604469350942327889444743441197, "invalid current sqrtP");
        assertEq(tick, 85184, "invalid current tick");
        assertEq(pool.liquidity(), 1517882343751509868544, "invalid current liquidity");
    }

    /**************************************** */

    function testSwapInsufficientInputAmount() public {
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            transferInMintCallback: true,
            transferInSwapCallback: false,
            mintLiquidity: true
        });
        _setupTestCase(params);
        vm.expectRevert(encodeError("InsufficientInputAmount()"));
        pool.swap(address(this), "");
    }

    ///////////////////////////////////////////////////////
    //       CALLBACKS START
    ///////////////////////////////////////////////////////

    /**
     * @dev called when minting liquidity
     */
    // prettier-ignore
    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) public {
        if (transferInSwapCallback) {
            UniswapV3Pool.CallbackData memory extra = abi.decode(data, (UniswapV3Pool.CallbackData));
            if (amount0 > 0) IERC20(extra.token0).transferFrom(extra.payer, msg.sender, uint256(amount0));
            if (amount1 > 0) IERC20(extra.token1).transferFrom(extra.payer, msg.sender, uint256(amount1));
        }
    }

    /**
     * @dev called when minting liquidity
     */
    // prettier-ignore
    function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata _data) public {
        if (transferInMintCallback) {
            // Decode input data to correct format (UniswapV3Pool.CallbackData)
            UniswapV3Pool.CallbackData memory extra = abi.decode(_data, (UniswapV3Pool.CallbackData));

            // Transfer tokens from payer to caller of this function (Should be UniV3Pool)
            IERC20(extra.token0).transferFrom(extra.payer, msg.sender, _amount0);
            IERC20(extra.token1).transferFrom(extra.payer, msg.sender, _amount1);
        }
    }

    ///////////////////////////////////////////////////////
    //       CALLBACKS END
    ///////////////////////////////////////////////////////

    // prettier-ignore
    function _setupTestCase(TestCaseParams memory _params) internal returns (uint256 poolBalance0, uint256 poolBalance1) {
        // Mint both tokens to this contract
        token0.mint(address(this), _params.wethBalance);
        token1.mint(address(this), _params.usdcBalance);

        // Create a new pool with these tokens, sqrt of P and current tick
        pool = new UniswapV3Pool(address(token0), address(token1), _params.currentSqrtP, _params.currentTick);

        // If params want to mintLiquidity
        if (_params.mintLiquidity) {
            // Approve to this contract
            token0.approve(address(this), _params.wethBalance);
            token1.approve(address(this), _params.usdcBalance);

            // Declare data to pass to the mint function
            UniswapV3Pool.CallbackData memory extra = UniswapV3Pool.CallbackData({
                token0: address(token0),
                token1: address(token1),
                payer: address(this)
            });

            // Call mint() in UniswapV3Pool
            (poolBalance0, poolBalance1) = pool.mint(
                address(this),
                _params.lowerTick,
                _params.upperTick,
                _params.liquidity,
                abi.encode(extra)
            );
        }

        // Set the global params
        transferInMintCallback = _params.transferInMintCallback;
        transferInSwapCallback = _params.transferInSwapCallback;
    }
}
