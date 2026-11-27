#!/usr/bin/env bash
# Public Celo Sepolia Testnet parameters (Chain ID 11142220 — NO private keys)

export CELO_SEPOLIA_RPC_URL="https://forno.celo-sepolia.celo-testnet.org"
export TESTNET_DEPLOYER="0x656CaB5127F4067Af0E0b60b070604cDCC0B307c"
export TESTNET_ADMIN="$TESTNET_DEPLOYER"
export TESTNET_TREASURY="$TESTNET_DEPLOYER"
export DEPLOYMENT_MANIFEST="./testnet/deployments/recy-11142220.json"
