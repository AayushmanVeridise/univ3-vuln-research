// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Demo Concentrated Liquidity Manager Vault (intentionally unsafe)
/// @notice Users deposit token0/token1 into the vault; admin manages a single Uniswap V3 position.
///         This contract is meant to showcase common CLM pitfalls, not to be safe.
contract DemoCLMVault {
    // ------------------------------------------------
    // Roles / config
    // ------------------------------------------------

    address public immutable admin;
    address public immutable token0;
    address public immutable token1;
    address public immutable pool;
    INonfungiblePositionManager public immutable positionManager;

    // router used for swapping during rebalances (for later tests)
    address public unirouter;

    // Uniswap v3 LP NFT
    uint256 public currentPositionId;

    // "width" in ticks around current tick
    int24 public positionWidth;

    // Oracle / TWAP config (admin-controlled; can be abused)
    uint32 public twapInterval;        // in seconds
    uint256 public maxDeviationBps;    // allowed deviation between spot & TWAP

    // Fee config (admin-controlled; can be abused retroactively)
    uint256 public performanceFeeBps;  // e.g. 2000 = 20%
    address public feeRecipient;

    // Basic share accounting
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    bool public paused;

    // ------------------------------------------------
    // Events
    // ------------------------------------------------

    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event PositionOpened(uint256 tokenId, int24 tickLower, int24 tickUpper);
    event PositionWidthSet(int24 oldWidth, int24 newWidth);
    event TwapParamsSet(uint32 interval, uint256 maxDeviationBps);
    event UnirouterSet(address unirouter);
    event PerformanceFeeSet(uint256 performanceFeeBps);
    event Paused();
    event Unpaused();

    // ------------------------------------------------
    // Modifiers
    // ------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // TWAP/slot0 check used only in some paths (others intentionally omit it)
    modifier onlyCalmPeriods() {
        _checkTwap();
        _;
    }

    // ------------------------------------------------
    // Constructor
    // ------------------------------------------------

    constructor(
        address _admin,
        address _token0,
        address _token1,
        address _pool,
        address _positionManager,
        address _unirouter
    ) {
        require(_admin != address(0), "admin=0");
        require(_token0 != address(0) && _token1 != address(0), "token=0");
        require(_pool != address(0), "pool=0");
        require(_positionManager != address(0), "pm=0");

        admin = _admin;
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
        positionManager = INonfungiblePositionManager(_positionManager);
        unirouter = _unirouter;

        // some default params (can be changed later by admin)
        positionWidth = 600;       // e.g. 10 * 60 tick spacing for a 0.3% pool
        twapInterval = 60;         // 60s TWAP by default
        maxDeviationBps = 1_000;   // 10% deviation allowed
        performanceFeeBps = 0;     // start at 0%
        feeRecipient = _admin;     // default to admin, can change later
    }

    // ------------------------------------------------
    // User functions
    // ------------------------------------------------

    /// @notice Users deposit token0 & token1 into the vault.
    /// @dev Minimal accounting: shares = amount0 + amount1 (assuming equal value),
    ///      this is intentionally simplistic and can lead to mispricing.
    function deposit(uint256 amount0, uint256 amount1) external whenNotPaused returns (uint256 mintedShares) {
        require(amount0 > 0 || amount1 > 0, "zero deposit");

        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }

        // simplistic share calculation (for demo only)
        mintedShares = amount0 + amount1;

        if (totalShares == 0) {
            shares[msg.sender] = mintedShares;
        } else {
            shares[msg.sender] += mintedShares;
        }
        totalShares += mintedShares;

        emit Deposit(msg.sender, amount0, amount1, mintedShares);
    }

    /// @notice Users withdraw proportional share of free (non-LP) balances.
    /// @dev For simplicity, this does NOT remove liquidity from Uniswap; users
    ///      only get a share of tokens currently sitting idle in the vault.
    function withdraw(uint256 shareAmount) external whenNotPaused returns (uint256 amount0Out, uint256 amount1Out) {
        require(shareAmount > 0, "zero shares");
        require(shareAmount <= shares[msg.sender], "insufficient shares");

        uint256 vaultToken0Bal = IERC20(token0).balanceOf(address(this));
        uint256 vaultToken1Bal = IERC20(token1).balanceOf(address(this));

        amount0Out = (vaultToken0Bal * shareAmount) / totalShares;
        amount1Out = (vaultToken1Bal * shareAmount) / totalShares;

        require(amount0Out > 0 || amount1Out > 0, "nothing to withdraw");

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        if (amount0Out > 0) IERC20(token0).transfer(msg.sender, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(msg.sender, amount1Out);

        emit Withdraw(msg.sender, shareAmount, amount0Out, amount1Out);
    }

    // ------------------------------------------------
    // Admin functions (management & vulnerabilities)
    // ------------------------------------------------

    /// @notice Admin can open a new position using all idle balances.
    /// @dev Uses slot0 and positionWidth to set ticks, but DOES NOT apply TWAP check.
    function openPosition() external onlyAdmin whenNotPaused {
        require(currentPositionId == 0, "position exists");

        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();

        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));

        require(amount0 > 0 || amount1 > 0, "no funds");

        IERC20(token0).approve(address(positionManager), amount0);
        IERC20(token1).approve(address(positionManager), amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0 < token1 ? token0 : token1,
            token1: token0 < token1 ? token1 : token0,
            fee: IUniswapV3Pool(pool).fee(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0 < token1 ? amount0 : amount1,
            amount1Desired: token0 < token1 ? amount1 : amount0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        (uint256 tokenId, , , ) = positionManager.mint(params);
        currentPositionId = tokenId;

        emit PositionOpened(tokenId, tickLower, tickUpper);
    }

    /// @notice Admin rebalances position in a "safe" way (with TWAP check).
    function rebalance() external onlyAdmin whenNotPaused onlyCalmPeriods {
        require(currentPositionId != 0, "no position");
        _removeAllLiquidity();
        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        _addAllLiquidity(tickLower, tickUpper);
    }

    /// @notice Admin changes positionWidth and redeploys liquidity WITHOUT TWAP check.
    function setPositionWidth(int24 _width) external onlyAdmin {
        emit PositionWidthSet(positionWidth, _width);
        _claimEarnings();
        _removeAllLiquidity();

        positionWidth = _width;

        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        _addAllLiquidity(tickLower, tickUpper);
    }

    /// @notice Pause the vault and remove liquidity (panic).
    function pause() external onlyAdmin {
        paused = true;
        _removeAllLiquidity();
        emit Paused();
    }

    /// @notice Unpause the vault and redeploy liquidity WITHOUT TWAP check.
    function unpause() external onlyAdmin {
        paused = false;
        _giveAllowances();
        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        _addAllLiquidity(tickLower, tickUpper);
        emit Unpaused();
    }

    /// @notice Admin sets TWAP parameters (can render TWAP check ineffective).
    function setTwapParams(uint32 _interval, uint256 _maxDeviationBps) external onlyAdmin {
        twapInterval = _interval;
        maxDeviationBps = _maxDeviationBps;
        emit TwapParamsSet(_interval, _maxDeviationBps);
    }

    /// @notice Admin updates the router address (does NOT revoke old approvals).
    function setUnirouter(address _unirouter) external onlyAdmin {
        unirouter = _unirouter;
        emit UnirouterSet(_unirouter);
    }

    /// @notice Admin updates performance fee.
    function setPerformanceFeeBps(uint256 _performanceFeeBps) external onlyAdmin {
        require(_performanceFeeBps <= 5_000, "fee too high");
        performanceFeeBps = _performanceFeeBps;
        emit PerformanceFeeSet(_performanceFeeBps);
    }

    function setFeeRecipient(address _recipient) external onlyAdmin {
        require(_recipient != address(0), "recipient=0");
        feeRecipient = _recipient;
    }

    // ------------------------------------------------
    // Internal helpers
    // ------------------------------------------------

    function _computeTicksFromSlot0() internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        tickLower = currentTick - positionWidth;
        tickUpper = currentTick + positionWidth;
    }

    function _removeAllLiquidity() internal {
        if (currentPositionId == 0) return;

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(currentPositionId);

        if (liquidity > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory dec = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                    tokenId: currentPositionId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 15 minutes
                });

            positionManager.decreaseLiquidity(dec);

            INonfungiblePositionManager.CollectParams memory col = INonfungiblePositionManager.CollectParams({
                tokenId: currentPositionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            positionManager.collect(col);
        }
    }

    function _addAllLiquidity(int24 tickLower, int24 tickUpper) internal {
        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));
        if (amount0 == 0 && amount1 == 0) return;

        IERC20(token0).approve(address(positionManager), amount0);
        IERC20(token1).approve(address(positionManager), amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0 < token1 ? token0 : token1,
            token1: token0 < token1 ? token1 : token0,
            fee: IUniswapV3Pool(pool).fee(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0 < token1 ? amount0 : amount1,
            amount1Desired: token0 < token1 ? amount1 : amount0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        (uint256 tokenId, , , ) = positionManager.mint(params);
        currentPositionId = tokenId;
    }

    function _claimEarnings() internal {
        // placeholder for fee collection logic
    }

    /// @dev Naive TWAP vs spot check. Can be disabled/abused via setTwapParams.
    function _checkTwap() internal view {
        if (twapInterval == 0) {
            // interval=0: effectively disabled, but we intentionally allow it
            return;
        }

        // Spot tick
        (, int24 spotTick, , , , , ) = IUniswapV3Pool(pool).slot0();

        // TWAP tick over [now - twapInterval, now]
        
        uint32[] memory secondsAgos = new uint32[](2);

        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulative, ) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 delta = tickCumulative[1] - tickCumulative[0];
        int24 twapTick = int24(delta / int56(int32(twapInterval)));

        int256 diff = spotTick - twapTick;
        int256 diffAbs = diff >= 0 ? diff : -diff;

        uint256 deviationBps = uint256(diffAbs); // crude mapping: 1 tick ~ 1 bps-ish
        require(deviationBps <= maxDeviationBps, "twap deviation too high");
    }

    function _giveAllowances() internal {
        IERC20(token0).approve(unirouter, type(uint256).max);
        IERC20(token1).approve(unirouter, type(uint256).max);
    }
}
