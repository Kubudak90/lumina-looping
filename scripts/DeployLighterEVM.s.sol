// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Looping} from "../contracts/Looping.sol";
import {StrategyManagerFactory} from "../contracts/StrategyManagerFactory.sol";

/**
 * @title DeployLighterEVM
 * @notice LightLend Looping deployment script for LighterEVM (chainId 304).
 * @dev Usage:
 *   forge script scripts/DeployLighterEVM.s.sol:DeployLighterEVM \
 *     --rpc-url $RPC_LIGHTER_EVM --broadcast --verify
 *
 *   1. POOL_ADDRESS must be updated after the core (Aave V3) deployment.
 *   2. Swappers are left empty; add them via Looping.setSwapper() after
 *      DEX adapter contracts are deployed.
 */
contract DeployLighterEVM is Script {
    // ---------------------------------------------------------------------------
    // LighterEVM placeholder addresses — update before mainnet deployment
    // ---------------------------------------------------------------------------

    /// @dev Pool address from core deployment. Replace with actual address.
    address constant POOL_ADDRESS = address(0);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // --- Prepare constructor arguments ---
        address[] memory pools = new address[](1);
        pools[0] = POOL_ADDRESS;

        // Swappers left empty — will be whitelisted after DEX adapter deployment
        address[] memory swappers = new address[](0);

        vm.startBroadcast(deployerPrivateKey);

        // --- Deploy Looping ---
        Looping looping = new Looping(pools, swappers, deployer);
        console.log("Looping deployed at:", address(looping));

        // --- Deploy StrategyManagerFactory ---
        StrategyManagerFactory factory = new StrategyManagerFactory();
        console.log("StrategyManagerFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // --- Summary ---
        console.log("-------- Deployment Summary --------");
        console.log("  Network:                 LighterEVM (304)");
        console.log("  Looping:                ", address(looping));
        console.log("  StrategyManagerFactory:  ", address(factory));
        console.log("  Pool (placeholder):     ", POOL_ADDRESS);
        console.log("  Owner:                  ", deployer);
        console.log("------------------------------------");
    }
}
