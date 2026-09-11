// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Looping} from "../contracts/Looping.sol";
import {StrategyManagerFactory} from "../contracts/StrategyManagerFactory.sol";

/**
 * @title DeployLooping
 * @notice Looping deployment script for a verified EVM (Base Sepolia in development).
 * @dev Usage:
 *   forge script scripts/DeployLighterEVM.s.sol:DeployLooping \
 *     --rpc-url $RPC_BASE_SEPOLIA --broadcast --verify
 *
 *   Lighter REST (`mainnet.zklighter.elliot.ai`) is not an EVM RPC and must not
 *   be used as --rpc-url.
 */
contract DeployLooping is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @dev Pool address from core deployment. Replace with actual address.
    address constant POOL_ADDRESS = address(0);

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "deploy only on Base Sepolia");
        require(POOL_ADDRESS != address(0), "POOL_ADDRESS placeholder");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        address[] memory pools = new address[](1);
        pools[0] = POOL_ADDRESS;

        address[] memory swappers = new address[](0);

        vm.startBroadcast(deployerPrivateKey);

        Looping looping = new Looping(pools, swappers, deployer);
        console.log("Looping deployed at:", address(looping));

        StrategyManagerFactory factory = new StrategyManagerFactory();
        console.log("StrategyManagerFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("-------- Deployment Summary --------");
        console.log("  Network:                 Base Sepolia (84532)");
        console.log("  Looping:                ", address(looping));
        console.log("  StrategyManagerFactory:  ", address(factory));
        console.log("  Pool:                    ", POOL_ADDRESS);
        console.log("  Owner:                   ", deployer);
        console.log("------------------------------------");
    }
}

/**
 * @dev Kept so old forge script selectors fail closed instead of targeting Lighter REST.
 */
contract DeployLighterEVM is Script {
    function run() external pure {
        revert("Lighter is not a general-purpose EVM. Use DeployLooping against Base Sepolia.");
    }
}
