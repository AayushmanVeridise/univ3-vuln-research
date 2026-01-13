// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14; 

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./utils/ShareToken.sol";

contract CLM {
    address public immutable admin;
    address public immutable token0;
    address public immutable token1; 
    address public immutable pool;
    INonfungiblePositionManager public immutable positionManager;

    // rouer used for swapping during rebalances
    address public unirouter; 

    // Uniswap V3 LP NFT
    uint256 public currentPositionId;

    // width in ticks around current tick 
    int24 public positionWidth; 

    // Oracle / TWAP config
    uint32 public twapDuration; 
    uint256 public maxDeviationBps; 

    // Fee config
    uint256 public performanceFeeBps; // e.g. 2000 = 20%
    address public feeRecipient;

    bool public paused; 

    // Reward token
    ShareToken public shareToken;

    // -------------------------------------------------
    // Events 
    // -------------------------------------------------

    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares); 
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event PositionOpened(uint256 tokenId, int24 tickLower, int24 tickUpper);
    event TwapParamsSet(uint32 interval, uint256 maxDeviationBps);
    event UnirouterSet(address unirouter); 
    event PerformanceFeeSet(uint256 performanceFeeBps); 
    event Paused(); 
    event Unpaused(); 

    // -------------------------------------------------
    // Modifiers 
    // -------------------------------------------------

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not Admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    modifier onlyCalmPeriods() {
        _checkTwap();
        _;
    }

    // -------------------------------------------------
    // Constructor 
    // -------------------------------------------------

    constructor(
        address _admin,
        address _token0, 
        address _token1,
        address _pool, 
        address _positionManager,
        address _unirouter
    ) {
        require(_admin != address(0), "Invalid admin address");
        require(_token0 != address(0) && _token1 != address(0), "Invalid token address"); 
        require(_pool != address(0), "Invalid pool address");
        require(_positionManager != address(0), "Invalid pool manager address");


        admin = _admin; 
        token0 = _token0; 
        token1 = _token1;
        pool = _pool;
        positionManager = INonfungiblePositionManager(_positionManager);
        unirouter = _unirouter;

        // Deploy ShareToken contract
        shareToken = new ShareToken(address(this));

        // Default params (can be updated by admin later)
        positionWidth = 600;        // 10*60 tick spacing for a 0.3% pool
        twapDuration = 60;          // 60s TWAP by default. If 0 then twap check is disabled
        maxDeviationBps = 1_000;    // 10% deviation allowed
        performanceFeeBps = 0;      // Start at 0% fee
        feeRecipient = _admin;     // Default to admin, can be updated later
    }

    // -------------------------------------------------
    // User functions 
    // -------------------------------------------------

    /// @notice Users deposit token0 and token1 into the vault. 
    /// @dev Minimal accounting: Shares = amount0 + amount1 (assuming equal value)
    /// @param amount0 Amount of token0
    /// @param amount1 Amount of token1

    function deposit(uint256 amount0, uint256 amount1) external whenNotPaused returns (uint256 mintedShares) {
        require (amount0 > 0 || amount1 > 0, "Zero deposit"); 

        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0); 
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1); 
        }

        uint8 token0Decimals = IERC20Metadata(token0).decimals();
        uint8 token1Decimals = IERC20Metadata(token1).decimals();

        uint256 token0Normalized = _getNormalized(amount0, token0Decimals);
        uint256 token1Normalized = _getNormalized(amount1, token1Decimals);



        uint256 shares = token0Normalized + token1Normalized; 
        require(shares > 0, "Zero shares"); // sanity

        // Mint the shares to the user
        shareToken.mint(msg.sender, shares);

        mintedShares = shares;

        emit Deposit(msg.sender, amount0, amount1, mintedShares); 
    }

    /// @notice Users withdraw proportional share of fee (non-LP) balances. 
    /// @dev    For simplicity, this does NOT remove liqudity from Uniswap
    ///         user only get a share of tokens currently sitting idle in the vault
    /// @dev    Can only be called when vault is not paused
    /// @param shareAmount amount of shares to withdraw
    function withdraw(uint256 shareAmount) external whenNotPaused returns (uint256 amount0Out, uint256 amount1Out) {
        require(shareAmount > 0, "Zero shares"); 
        require(shareAmount <= shareToken.balanceOf(msg.sender), "Insufficient Shares"); 

        uint256 tokenAmounts = shareAmount / 2;
        require(tokenAmounts > 0); // sanity check

        uint256 vaultToken0Bal = IERC20(token0).balanceOf(address(this));
        uint256 vaulttoken1Bal = IERC20(token1).balanceOf(address(this));

        // Check if vault has enough token balances
        require(vaultToken0Bal >= tokenAmounts);
        require(vaulttoken1Bal >= tokenAmounts);

        // Take shares from user
        shareToken.transferFrom(msg.sender, address(this), shareAmount);

        // Transfer the appropriate amount of tokens from the users
        IERC20(token0).transfer(msg.sender, tokenAmounts); 
        IERC20(token1).transfer(msg.sender, tokenAmounts); 

        emit Withdraw(msg.sender, shareAmount, amount0Out, amount1Out); 
    }

    // -------------------------------------------------
    // Admin functions (Core CLM and Vault functionality)
    // -------------------------------------------------

    /// @notice Opens up a liquidity position in the Pool
    /// @dev uses slot0 for ticks calculation
    function openPosition() external onlyAdmin whenNotPaused {
        require(currentPositionId == 0, "Position exists");
        
        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();

        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));

        require(amount0 > 0 || amount1 > 0, "No funds");

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

        // Mint Position
        (currentPositionId, , ,) = positionManager.mint(params);

        emit PositionOpened(currentPositionId, tickLower, tickUpper);
    }

    /// @notice Rebalances a position into the current tick
    /// @dev uses slot0 for tick calculations
    function rebalance() external onlyAdmin whenNotPaused {
        require(currentPositionId != 0, "No position");

        _removeAllLiquidity();
        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        _addAllLiquidity(tickLower, tickUpper);
    }

    /// @notice changes positionWidth and redeploys liquidity
    /// @dev Ticks are computed from slot0
    function setPositionwidth(int24 _width) external onlyAdmin {
        _claimEarnings();
        _removeAllLiquidity();

        positionWidth = _width;

        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        _addAllLiquidity(tickLower, tickUpper);
    }

    /// @notice pause the vault and remove all liquidity (panic)
    function pause() external onlyAdmin {
        paused = true; 
        _removeAllLiquidity();
        emit Paused();
    }

    /// @notice Unpause the vault and redploy liquidty 
    function unpause() external onlyAdmin {
        paused = false; 
        _giveAllowances();
        (int24 tickLower, int24 tickUpper) = _computeTicksFromSlot0();
        emit Unpaused();
    }

    /// @notice Admin can update twap parameters 
    function checkTwapParams(uint32 _interval, uint256 _maxDeviationBps) external onlyAdmin {
        twapDuration = _interval; 
        maxDeviationBps = _maxDeviationBps; 
        emit TwapParamsSet(_interval, maxDeviationBps);
    }

    /// @notice
    function setUnirouter(address _unirouter) external onlyAdmin {
        unirouter = _unirouter;
        emit UnirouterSet(_unirouter);
    }

    function setPerformanceFeeBps(uint256 _performanceFeeBps) external onlyAdmin {
        require(_performanceFeeBps <= 5_000, "Fee too high");
        performanceFeeBps = _performanceFeeBps; 
        emit PerformanceFeeSet(_performanceFeeBps);
    }

    function setFeeRecipient(address _recipient) external onlyAdmin {
        require(_recipient != address(0), "Invalid recipient address");
        feeRecipient = _recipient;
    }
    // -------------------------------------------------
    // View functions 
    // -------------------------------------------------

    /// @notice Returns the shares of the user in the vault
    /// @param user The address to query the shares of
    ///
    function getShares(address user) external view returns (uint256 userShares) {
        userShares = shareToken.balanceOf(user);
    }

    function getTotalShares() external view returns (uint256 totalShares) {
        totalShares = shareToken.totalSupply();
    }

    function getLiquidity() external view returns (uint128 liquidity) {
        (, , , , , , , liquidity, , , , ) = positionManager.positions(currentPositionId);
    }

    // -------------------------------------------------
    // Internal helper functions 
    // -------------------------------------------------

    /// @notice Returns the upper and lower ticks
    /// @dev Uses slot0 for calculations
    function _computeTicksFromSlot0() internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        tickLower = currentTick - positionWidth;
        tickUpper = currentTick + positionWidth;
    }

    /// @notice Checks (via TWAP) if the price deviates outside the max allowed 
    /// @dev If twap check duration is 0s, then the check is effectively disabled
    function _checkTwap() internal view {
        if (twapDuration == 0) {
            return;
        }

        // current tick from slot0
        (, int24 currentTick, , , , ,) = IUniswapV3Pool(pool).slot0();

        // TWAP tick over [now - twapDuration, now]

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapDuration;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 twapTick = int24((delta / int56(int32(twapDuration))));

        int256 diff = currentTick - twapTick;
        int256 diffAbs = diff >=0 ? diff : -diff;

        uint256 deviationBps = uint256(diffAbs); // crude mapping: 1 tick ~ 1 bps-ish
        require(deviationBps <= maxDeviationBps);

    }

    function _addLiquidity() internal {
        // TODO
    }
    function _removeLiquidity() internal {
        // TODO
    }

    /// @notice Removes All liqudity from the pool
    function _removeAllLiquidity() internal {
        if (currentPositionId == 0) return; 

        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(currentPositionId);

        if (liquidity > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory dec = INonfungiblePositionManager.DecreaseLiquidityParams({
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

    /// @notice Adds all token balance into the LP
    function _addAllLiquidity(int24 tickLower, int24 tickUpper) internal {
        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));

        if (amount0 == 0 || amount1 == 0) {
            return;
        } 

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

        (uint256 tokenId, , ,) = positionManager.mint(params);
        currentPositionId = tokenId;
    }

    function _claimEarnings() internal {
        // TODO
        return;
    }

    function _giveAllowances() internal {
        IERC20(token0).approve(unirouter, type(uint256).max); 
        IERC20(token1).approve(unirouter, type(uint256).max);
    }

    /// @notice This function normalizes the tokenAmount to 8 decimals 
    function _getNormalized(uint256 tokenAmount, uint8 tokenDecimals) internal returns (uint256) {
        // Reward token decimals = 8

        uint256 normalizedDecimals = 8; 

        if (tokenDecimals > 8) {
            normalizedDecimals = 10 ** (tokenDecimals - 8);
        } else {
            normalizedDecimals = 10 ** (8 - tokenDecimals);
        }

        return (tokenAmount * normalizedDecimals);
    }
}