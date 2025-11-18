pragma solidity ^0.8.14;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract ConcentratedLiqudityManager {

    address public admin; 
    address public Token0; 
    address public Token1; 
    address public Pool;

    uint256 public Fee;

    constructor(address _Token0, address _Token1, address _Pool, uint256 _Fee) {
        admin = msg.sender; 
        Token0 = _Token0;
        Token1 = _Token1;
        Pool = _Pool;
        Fee = _Fee;
    }

    modifier onlyAdmin {
        require(msg.sender == admin, "Not authorized");
        _;
    }

    // User functions
    function deposit() external {}
    function withdraw() external {}

    // Admin functions
    function rebalance() external onlyAdmin {}

    function pause() external onlyAdmin {}

    function unpause() external onlyAdmin {}

    function setTwapParams() external onlyAdmin {}

    // Internal functions 


}