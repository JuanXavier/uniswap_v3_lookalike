TODO:

- change compiler version
- Update and add natspec for every function
- add formulas for every math function
- Fix remappings bug in toml file
- Generate tree

.
├── interfaces
│ ├── IERC20.sol
│ ├── IUniswapV3FlashCallback.sol
│ ├── IUniswapV3Manager.sol
│ ├── IUniswapV3MintCallback.sol
│ ├── IUniswapV3Pool.sol
│ ├── IUniswapV3PoolDeployer.sol
│ └── IUniswapV3SwapCallback.sol
│
├── libraries
│ ├── BitMath.sol
│ ├── FixedPoint128.sol
│ ├── FixedPoint96.sol
│ ├── LiquidityMath.sol
│ ├── Math.sol
│ ├── Oracle.sol
│ ├── Path.sol
│ ├── PoolAddress.sol
│ ├── Position.sol
│ ├── SwapMath.sol
│ ├── Tick.sol
│ ├── TickBitmap.sol
│ └── TickMath.sol
│
├── UniswapV3Factory.sol
├── UniswapV3Manager.sol
├── UniswapV3NFTManager.sol
├── UniswapV3Pool.sol
└── UniswapV3Quoter.sol
