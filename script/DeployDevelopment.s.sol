// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Script.sol";
import "../test/ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";
import "../src/UniswapV3Manager.sol";

contract DeployDevelopment is Script {
    function run() public {
        // Params to use
        uint256 wethBalance = 1 ether;
        uint256 usdcBalance = 5042 ether;
        int24 currentTick = 85176;
        uint160 currentSqrtP = 5602277097478614198912276234240;

        /////////////////////////////////////////
        //          START
        /////////////////////////////////////////
        vm.startBroadcast();

        // Deploy tokens
        ERC20Mintable token0 = new ERC20Mintable("Wrapped Ether", "WETH", 18);
        ERC20Mintable token1 = new ERC20Mintable("USD Coin", "USDC", 18);

        // Deploy pool and manager
        UniswapV3Pool pool = new UniswapV3Pool(address(token0), address(token1), currentSqrtP, currentTick);
        UniswapV3Manager manager = new UniswapV3Manager();

        // Mint tokens to us
        //msg.sender in Foundry scripts is the address that sends transactions within the broadcast block.
        token0.mint(msg.sender, wethBalance);
        token1.mint(msg.sender, usdcBalance);

        vm.stopBroadcast();
        /////////////////////////////////////////
        //             END
        /////////////////////////////////////////

        console.log("WETH address", address(token0));
        console.log("USDC address", address(token1));
        console.log("Pool address", address(pool));
        console.log("Manager address", address(manager));
    }
}
