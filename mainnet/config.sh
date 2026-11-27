#!/usr/bin/env bash
# Public Ethereum Mainnet deployment parameters (NO private keys or API secrets)

export ETH_MAINNET_RPC_URL="https://ethereum-rpc.publicnode.com"
export MAINNET_DEPLOYER="0x656CaB5127F4067Af0E0b60b070604cDCC0B307c"

export PROTOCOL_SAFE="0xC33B034E3847CEeFa5989a13af5bd611daFF6D1b"
export TREASURY_SAFE="0x1EF3a7ba64f313a9b32A2B1519250E6C1D476356"

# Protocol Safe: governance, upgrades, and 10% protocol cRECY share
export MAINNET_PROTOCOL_WALLET="$PROTOCOL_SAFE"
export MAINNET_SAFE_MULTISIG="$PROTOCOL_SAFE"
export MAINNET_PROTOCOL_ADMIN="$PROTOCOL_SAFE"

# Treasury Safe: OTC inventory/USDC settlement and 30% traceability certificate USDC fees
export DETRASH_TREASURY_ADDRESS="$TREASURY_SAFE"
export MAINNET_ADMIN_WALLET="$TREASURY_SAFE"
export TREASURY_OPERATOR_ADDRESS="$TREASURY_SAFE"
export MAINNET_TREASURY_SAFE="$TREASURY_SAFE"

# Exact genesis supply cap: 484,891.69691 cRECY
export INITIAL_MAINNET_MINT="484891696910000000000000"
export GENESIS_REPORT_SEED="0"
export STAKING_REWARD_SEED="0"
export OTC_INITIAL_ALLOWANCE="0"
export INITIAL_CRECY_PRICE_MICRO_USDC="50000"
export INITIALIZE_V4_POOL="true"
export DEPLOYMENT_MANIFEST="./mainnet/deployments/recy-eth-mainnet-1.json"