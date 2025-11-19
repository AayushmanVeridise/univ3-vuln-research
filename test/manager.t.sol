// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../src/poolLauncher.sol";
import "../src/LiquidityProvider.sol";
import "../src/token.sol";
import "../src/CLM.sol";

contract DemoCLMVaultTest is Test {
    // ---- Mainnet Uniswap v3 addresses ----
    // Factory (Ethereum mainnet)
    address constant UNISWAP_V3_FACTORY =
        0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // NonfungiblePositionManager (Ethereum mainnet)
    address constant NONFUNGIBLE_POSITION_MANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // Uniswap V3 SwapRouter (Ethereum mainnet)
    address constant UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    PoolLauncher public poolLauncher;
    TestToken public token0;
    TestToken public token1;
    DemoCLMVault public vault;

    address public pool;

    function setUp() public {
        // --- fork mainnet ---
        // requires MAINNET_RPC_URL in .env
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // deploy helper contracts
        poolLauncher = new PoolLauncher(UNISWAP_V3_FACTORY);

        // deploy two custom ERC20s
        token0 = new TestToken("Vault Token 0", "VT0");
        token1 = new TestToken("Vault Token 1", "VT1");

        // mint tokens to this test contract (will act as user+admin)
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        // create & initialize Uniswap v3 pool via PoolLauncher
        // using your calculateSqrtPriceX96 helper: ~1:1 price, both 18 decimals
        uint160 sqrtPriceX96 = poolLauncher.calculateSqrtPriceX96(
            1e18, // price
            18,   // decimals0
            18    // decimals1
        );

        pool = poolLauncher.createAndInitializePool(
            address(token0),
            address(token1),
            3000,        // 0.3% fee tier
            sqrtPriceX96
        );

        // deploy DemoCLMVault
        vault = new DemoCLMVault(
            address(this),                // admin
            address(token0),
            address(token1),
            pool,
            NONFUNGIBLE_POSITION_MANAGER,
            UNISWAP_V3_SWAP_ROUTER        // unirouter (not used yet in tests)
        );
    }

    // ------------------------------------------------
    // Happy path: deposit + openPosition
    // ------------------------------------------------

    function testDepositAndOpenPosition() public {
        uint256 amount0 = 1_000 ether;
        uint256 amount1 = 1_000 ether;

        // approve vault to pull tokens
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);

        // user deposits into vault
        uint256 mintedShares = vault.deposit(amount0, amount1);
        assertGt(mintedShares, 0, "shares should be > 0");
        assertEq(vault.totalShares(), mintedShares, "totalShares mismatch");
        assertEq(vault.shares(address(this)), mintedShares, "user shares mismatch");

        // admin opens a Uniswap v3 position using vault funds
        vault.openPosition();

        uint256 tokenId = vault.currentPositionId();
        assertGt(tokenId, 0, "positionId should be > 0");

        // pool should now have some liquidity
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();
        assertGt(liquidity, 0, "pool liquidity should be > 0");
    }

    // ------------------------------------------------
    // Happy path: deposit + openPosition + rebalance
    // ------------------------------------------------

    function testRebalanceAfterOpenPosition() public {
        uint256 amount0 = 2_000 ether;
        uint256 amount1 = 2_000 ether;

        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);

        vault.deposit(amount0, amount1);

        // open initial position
        vault.openPosition();
        uint256 tokenIdBefore = vault.currentPositionId();
        assertGt(tokenIdBefore, 0, "no position after openPosition");

        uint128 liquidityBefore = IUniswapV3Pool(pool).liquidity();
        assertGt(liquidityBefore, 0, "no liquidity before rebalance");

        // rebalance via the "safe" path (uses onlyCalmPeriods / TWAP check)
        vault.rebalance();

        uint256 tokenIdAfter = vault.currentPositionId();
        uint128 liquidityAfter = IUniswapV3Pool(pool).liquidity();

        // We expect to still have a position and liquidity.
        // In this demo, we don't assert exact values, just that something exists.
        assertGt(tokenIdAfter, 0, "no position after rebalance");
        assertGt(liquidityAfter, 0, "no liquidity after rebalance");
    }

    // ------------------------------------------------
    // Sanity: setPositionWidth path redeploys without TWAP (future attack vector)
    // ------------------------------------------------

    function testSetPositionWidthRedeploysLiquidity() public {
        uint256 amount0 = 1_000 ether;
        uint256 amount1 = 1_000 ether;

        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);

        vault.deposit(amount0, amount1);

        // open initial position
        vault.openPosition();
        uint256 tokenIdBefore = vault.currentPositionId();
        assertGt(tokenIdBefore, 0, "no position after openPosition");

        uint128 liquidityBefore = IUniswapV3Pool(pool).liquidity();
        assertGt(liquidityBefore, 0, "no liquidity before setPositionWidth");

        int24 oldWidth = vault.positionWidth();
        int24 newWidth = oldWidth * 2;

        // This call:
        //  - claims earnings (stub right now)
        //  - removes liquidity
        //  - updates positionWidth
        //  - recomputes ticks from slot0
        //  - re-adds liquidity WITHOUT TWAP guard
        vault.setPositionWidth(newWidth);

        // Position ID should still be non-zero (may or may not change in this impl)
        uint256 tokenIdAfter = vault.currentPositionId();
        assertGt(tokenIdAfter, 0, "no position after setPositionWidth");

        uint128 liquidityAfter = IUniswapV3Pool(pool).liquidity();
        assertGt(liquidityAfter, 0, "no liquidity after setPositionWidth");

        // and width really changed
        assertEq(vault.positionWidth(), newWidth, "positionWidth not updated");

        // Later we’ll add an attack test that sandwiches this call.
    }
}
