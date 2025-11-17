// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {PoolLauncher} from "../src/poolLauncher.sol";
import {LiquidityProvider} from "../src/liquditiyProvider.sol";
import {TestToken} from "../src/token.sol";

contract UniTest is Test {
    address UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984; 
    address NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    PoolLauncher public poolLauncher; 
    LiquidityProvider public liquidityProvider;
    TestToken public Token0;
    TestToken public Token1;

    function setUp() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // deploy helper contracts 
        poolLauncher = new PoolLauncher(UNISWAP_V3_FACTORY); 
        liquidityProvider = new LiquidityProvider(NONFUNGIBLE_POSITION_MANAGER);

        // deploy tokens 
        Token0 = new TestToken("Test token 0", "TK0");
        Token1 = new TestToken("Test token 1","TK1");

        // mint tokens directly to liqudity provider
        Token0.mint(address(liquidityProvider), 1_000_000 ether); 
        Token1.mint(address(liquidityProvider), 1_000_000 ether); 
    }

    function testDeployPoolandAddLiqudity() public {

        uint160 sqrtPriceX96 = poolLauncher.calculateSqrtPriceX96(
            1e18,
            18,
            18
        );

        address pool = poolLauncher.createAndInitializePool(
            address(Token0),
            address(Token1),
            3000, 
            sqrtPriceX96
        );

        assertTrue(pool != address(0), "Pool is zero address"); 
        assertEq(pool, poolLauncher.pool(), "Stored Pool mismatch"); 


        // Add liqudity 
        int24 tickLower = -887220;
        int24 tickUpper = 887220; 

        uint256 amountA = 500 ether;
        uint256 amountB = 500 ether;

        uint256 tokenId = liquidityProvider.addLiquidity(
            address(Token0), 
            address(Token1), 
            3000, 
            tickLower, 
            tickUpper, 
            amountA, 
            amountB, 
            0,
            0
        );

        assertTrue(tokenId != 0, "tokenId should not be zero"); 


        // verify that tool has liqudity
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();
        assertGt(liquidity, 0, "pool liqudity should be > 0");
    }
}
