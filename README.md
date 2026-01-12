# Project setup
1. in `lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol` change 
    ```
    import '@openzeppelin/contracts/token/ERC721/IERC721Metadata.sol';
    import '@openzeppelin/contracts/token/ERC721/IERC721Enumerable.sol';
    ```
    to 
    ```
    import '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';
    import '@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol';
    ```
2. in `/home/onion/research/univ3-vuln-research/lib/v3-periphery/contracts/libraries/PoolAddress.sol` change the `computeAddress` function to the following:
    ```
        function computeAddress(address factory, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1);
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            factory,
                            keccak256(abi.encode(key.token0, key.token1, key.fee)),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
    ```
3. Add an RPC url in `.env`