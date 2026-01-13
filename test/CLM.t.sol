// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../src/utils/PoolLauncher.sol";
import "../src/utils/TestToken.sol";
import "../src/CLM.sol";

contract CLMTest is Test {
    
    // -------------------------------------------------
    // /uniswap V3 Addresses (On ETH mainnet) 
    // -------------------------------------------------
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    PoolLauncher public poolLauncher; 
    TestToken public token0; 
    TestToken public token1; 
    CLM public clm; 
    IUniswapV3Pool public pool;
    INonfungiblePositionManager public positionManager;

    address public admin;
    address public user;
    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl); 
        vm.selectFork(forkId);

        // Deploy helper to create uniswapV3 pool
        poolLauncher = new PoolLauncher(UNISWAP_V3_FACTORY); 

        // // deploy two ERC20s 
        token0 = new TestToken("Vault Token 0", "VT0");
        token1 = new TestToken("Vault Token 1", "VT1");

        // initialize pool at ~1:1 price (both 18 decimals); 
        uint160 sqrtPriceX96 = poolLauncher.calculateSqrtPriceX96(
            1e18,   // Price
            18,     // decimals of token 0
            18     // decimals of token 1
         );

        address poolAddr = poolLauncher.createAndInitializePool(
            address(token0), 
            address(token1), 
            100, // 0.1% fee for now
            sqrtPriceX96
        );

        pool = IUniswapV3Pool(poolAddr); 

        // deploy CLM vault 

        admin = makeAddr("admin");

        clm = new CLM(
            admin,
            address(token0),
            address(token1), 
            address(pool), 
            NONFUNGIBLE_POSITION_MANAGER, 
            UNISWAP_V3_SWAP_ROUTER
        );

        // Setup  User in token contracts
        user = makeAddr("user");

        token0.mint(user, 1_000 ether);
        token1.mint(user, 1_000 ether);

        // sanity checks 
        assertEq(token0.balanceOf(user), 1_000 ether);
        assertEq(token1.balanceOf(user), 1_000 ether);

        vm.startPrank(user); 
        token0.approve(address(clm), 1_000 ether);
        token1.approve(address(clm), 1_000 ether);
        vm.stopPrank();

        positionManager = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER);
    }

    function test_Deployment() external {
        assertEq(clm.admin(), admin, "Admin missmatch");
        assertEq(clm.token0(), address(token0), "Token0 missmatch");
        assertEq(clm.token1(), address(token1), "Token1 missmatch");
    }

    function test_Deposit() external {

        // make a deposit as user
        vm.startPrank(user); 
        clm.deposit(1_000 ether, 1_000 ether);
        vm.stopPrank();

        // Check that tokens were moved
        assertEq(token0.balanceOf(user), 0);
        assertEq(token1.balanceOf(user), 0);

        assertEq(token0.balanceOf(address(clm)), 1_000 ether);
        assertEq(token1.balanceOf(address(clm)), 1_000 ether);
        
        // Check user's shares in the CLM vault
        assertEq(clm.getShares(user), 2_000 ether);
        assertEq(clm.getTotalShares(), 2_000 ether);
    }

    function test_Withdraw() external {

        vm.startPrank(user);

        // make a deposit first
        clm.deposit(1_000 ether, 1_000 ether);

        // now make a withdraw
        clm.withdraw(2_000 ether);

        vm.stopPrank();

        // Check that appropriate amount of tokens were moved
        assertEq(token0.balanceOf(user), 1_000 ether);
        assertEq(token1.balanceOf(user), 1_000 ether);

        // Check the shares in the CLM vault
        assertEq(clm.getShares(user), 0);
        assertEq(clm.getTotalShares(), 0);
        
    }

    function test_OpenPosition() external {

        // Get some token balance for vault
        // This can also be done by depositing
        token0.mint(address(clm), 1_000 ether);
        token1.mint(address(clm), 1_000 ether);

        vm.startPrank(admin);
        clm.openPosition();
        vm.stopPrank();

        assertGt(clm.currentPositionId(), 0);
        assertGt(clm.getLiquidity(), 0);
    }

    function test_Rebalance() external {

        // Open a position
        token0.mint(address(clm), 1_000 ether);
        token1.mint(address(clm), 1_000 ether);
        vm.startPrank(admin);
        clm.openPosition();
        vm.stopPrank();

        uint256 initialPositionId = clm.currentPositionId();
        uint256 initialLiquidity = clm.getLiquidity();
        
        
        // Add more tokens
        token0.mint(address(clm), 1_000 ether);
        token1.mint(address(clm), 1_000 ether);

        // rebalance
        vm.startPrank(admin);
        clm.rebalance();
        vm.stopPrank();
        // sanity checks
        assertGt(clm.currentPositionId(), initialPositionId);
        assertGt(clm.getLiquidity(), initialLiquidity);

    }


    function test_TwapAbuseRebalance() external {
        // Add CLM capital
        token0.mint(address(clm), 1_000 ether);
        token1.mint(address(clm), 1_000 ether);

        // Open the initial position
        vm.startPrank(admin);
        clm.openPosition();
        vm.stopPrank();

        // Sanity check to ensure position opened
        assertGt(clm.currentPositionId(), 0, "Position not opened");

        // Read initial pool tick and CLM's tick range
        (, int24 tickBefore, , , , , ) = IUniswapV3Pool(pool).slot0();

        (, , , , , int24 tickLowerBefore, int24 tickUpperBefore, , , , ,) = positionManager.positions(clm.currentPositionId());


        address attacker = makeAddr("attacker");

        // Fund token1 for attacker addr
        token1.mint(attacker, 10_000 ether); 

        vm.startPrank(attacker);
        IERC20(token1).approve(UNISWAP_V3_SWAP_ROUTER, 6_000 ether);

        // Attacker now swaps token1 -> token0 (buys token0, pushes its price up)
        _swapExactInputSingle(
            attacker, 
            address(token1),
            address(token0),
            100,
            1_000 ether // @note if this is high enough, it will cause a DOS also
        );

        vm.stopPrank();
        // Sanity check to see if tick moved 
        (, int24 tickAfter, , , , , ) = IUniswapV3Pool(pool).slot0();
        assertTrue(tickAfter != tickBefore, "Tick should have changed");

        // Now admin calls rebalance
        vm.startPrank(admin);
        clm.rebalance();
        vm.stopPrank();

        uint256 positionIdAfter = clm.currentPositionId();
        // Sanity check
        assertGt(positionIdAfter, 0, "Position not opened after rebalance");

        (, , , , , int24 tickLowerAfter, int24 tickUpperAfter, , , , ,) = positionManager.positions(positionIdAfter);
        int24 width = clm.positionWidth();
        int24 expectedLower = tickAfter - width;
        int24 expectedUpper = tickAfter + width;

        assertEq(tickLowerAfter, expectedLower, "Expected lower tick mismatch");
        assertEq(tickUpperAfter, expectedUpper, "Expected upper tick mismatch");
    }

    function _swapExactInputSingle(
        address trader, 
        address tokenIn, 
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {

        amountOut = ISwapRouter(UNISWAP_V3_SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut, 
                fee: fee,
                recipient: trader,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}