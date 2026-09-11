require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");

const TEST_MNEMONIC = "test test test test test test test test test test test junk";
const mnemonic = process.env.MNEMONIC || TEST_MNEMONIC;

function deployerAccounts() {
    const key = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
    return key ? [key] : [];
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version: "0.8.24",
        settings: {
            evmVersion: "cancun",
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 200,
            },
        },
    },
    networks: {
        hardhat: {
            gas: "auto",
            accounts: {
                mnemonic,
            },
            chainId: 1337,
        },
        baseSepolia: {
            accounts: deployerAccounts(),
            chainId: 84532,
            url: "https://sepolia.base.org",
        },
    },
    etherscan: {
        apiKey: {
            baseSepolia: process.env.ETHERSCAN_API_KEY_BASE || process.env.ETHERSCAN_API_KEY || "",
        },
    },
};
