const { ethers } = require("hardhat");

/**
 * Deploys the standalone VaultZapper helper.
 *
 * Looping and StrategyManagerFactory are NOT deployed here — the canonical
 * flow for those is ./scripts/deploy-lighter.sh → DeployLighterEVM.s.sol.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-vault-zapper.js --network <network>
 */
async function main() {
    const [deployer] = await ethers.getSigners();
    console.log(`Deploying VaultZapper with account: ${deployer.address}`);

    const VaultZapper = await ethers.getContractFactory("VaultZapper");
    const vaultZapper = await VaultZapper.deploy();
    await vaultZapper.waitForDeployment();
    console.log(`VaultZapper deployed to ${vaultZapper.target}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
