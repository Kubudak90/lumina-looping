require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");

const mnemonic = process.env.MNEMONIC;

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
        lighterEvmTestnet: {
            accounts: {
                mnemonic,
            },
            chainId: 998,
            url: 'https://rpc.hyperliquid-testnet.xyz/evm',
        },
        lighterEvm: {
            accounts: [process.env.PRIVATE_KEY_MAINNET || process.env.PRIVATE_KEY],
            chainId: 999,
            url: 'https://rpc.hyperliquid.xyz/evm',
        }
    },
    etherscan: {
        apiKey: {
            lighterEvmTestnet: "empty",
            lighterEvm: "empty"
        },
        customChains: [
            {
                network: "lighterEvmTestnet",
                chainId: 998,
                urls: {
                    apiURL: "https://explorer.lightlend.finance/api",
                    browserURL: "https://explorer.lightlend.finance"
                }
            },
            {
                network: "lighterEvm",
                chainId: 999,
                urls: {
                    apiURL: "https://hyperliquid.cloud.blockscout.com/api",
                    browserURL: "https://hyperliquid.cloud.blockscout.com"
                }
            }
        ]
    },
    sourcify: {
        enabled: true,
        apiUrl: "https://sourcify.parsec.finance",
        browserUrl: "https://purrsec.com/",
    }
};
