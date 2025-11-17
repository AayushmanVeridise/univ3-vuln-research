pragma solidity ^0.8.14;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
// import "@uniswap/v3-core/contracts/interfaces/IUniswapV3PoolDeployer.sol";
// import "../src/interfaces/IERC20.sol";

contract PoolLauncher {

    address public factory;
    address public pool;



// Addresses for Ethereum mainnet
// address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
// address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
// uint24 fee = 3000; // 0.3%
 
// // Calculate sqrtPriceX96 for 2000 USDC per ETH
// // WETH has 18 decimals, USDC has 6 decimals
// uint256 price = 2000 * 10**6; // 2000 with USDC's 6 decimals
// uint160 sqrtPriceX96 = calculateSqrtPriceX96(price, 6, 18);
 
// Create and initialize the pool
// address pool = createAndInitializePool(USDC, WETH, fee, sqrtPriceX96);
    constructor(address _factory) {
        factory = _factory; 
    }


    function calculateSqrtPriceX96(uint256 price, uint8 decimals0, uint8 decimals1) public pure returns (uint160) {
        uint256 adjustedPrice = price * 10**(decimals0 - decimals1);

        uint256 sqrtPrice = sqrt(adjustedPrice * 10**18); 

        return uint160((sqrtPrice * (2**96)) / 10**9);
    }

    function createAndInitializePool(
        address tokenA, 
        address tokenB, 
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address) {
        pool = IUniswapV3Factory(factory).createPool(tokenA, tokenB, fee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        return pool;
    }

    function sqrt(uint256 x) internal pure returns(uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2; 
        uint256 y = x; 

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return y;
    }
}