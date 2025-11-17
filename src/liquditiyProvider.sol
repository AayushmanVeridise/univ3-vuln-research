pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityProvider {
    INonfungiblePositionManager public positionManager;

    constructor(address _positionManager) {
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    function addLiquidity(
        address tokenA, 
        address tokenB, 
        uint24 fee, 
        int24 tickLower,
        int24 tickUpper, 
        uint256 amountA, 
        uint256 amountB, 
        uint256 amountAMin,
        uint256 amountBMin
    ) external returns (uint256 tokenId) {

        IERC20(tokenA).approve(address(positionManager), amountA);
        IERC20(tokenB).approve(address(positionManager), amountB); 

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: tokenA < tokenB ? tokenA : tokenB, 
            token1: tokenA < tokenB ? tokenB : tokenA,
            fee: fee,
            tickLower: tickLower, 
            tickUpper: tickUpper, 
            amount0Desired: tokenA < tokenB ? amountA : amountB,
            amount1Desired: tokenA < tokenB ? amountB : amountA, 
            amount0Min: tokenA < tokenB ? amountAMin : amountBMin, 
            amount1Min: tokenA < tokenB ? amountBMin : amountAMin, 
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        // Mint position
        (tokenId, , ,) = positionManager.mint(params); 

        return tokenId;
    }
}