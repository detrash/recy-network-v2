import fs from 'node:fs';

const EIP_7825_TX_GAS_CAP = 16_777_216n;
const EXCLUDED_MOCKS = new Set(['MockERC20', 'MockSwapRouter', 'TestnetMockUSDC']);

const args = process.argv.slice(2).filter((p) => fs.existsSync(p));
if (args.length === 0) {
  console.error('No chain-1 dry-run JSON files found under broadcast/*/1/dry-run/run-latest.json.');
  process.exit(1);
}

const rpcUrl = process.env.ETH_MAINNET_RPC_URL || 'https://ethereum-rpc.publicnode.com';
const ethUsd = Number(process.env.ETH_USD || '1636.27');
const fundingMultiplier = Number(process.env.FUNDING_BUFFER || '1.30');

// Optional Mainnet launch add-ons: Uniswap V3 pool create+seed (~5.5M) + Merkle distributor (~800k)
const uniswapPoolGas = BigInt(process.env.UNISWAP_POOL_GAS || '5500000');
const merkleMigrationGas = BigInt(process.env.MERKLE_MIGRATION_GAS || '800000');

function parseBigIntGas(value) {
  if (value === undefined || value === null) return 0n;
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number') return BigInt(Math.trunc(value));
  const str = String(value).trim();
  return str.startsWith('0x') ? BigInt(str) : BigInt(str);
}

async function fetchLiveBaseFeeGwei(url) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'eth_getBlockByNumber',
      params: ['latest', false],
    }),
  });
  const json = await res.json();
  if (!json.result || !json.result.baseFeePerGas) {
    throw new Error('Could not read baseFeePerGas from RPC.');
  }
  return Number(BigInt(json.result.baseFeePerGas)) / 1e9;
}

const prodRows = [];
const skippedMockAddresses = new Set();
let totalProdGas = 0n;
let totalSkippedMockGas = 0n;
let capViolations = 0;

for (const filePath of args) {
  const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const txs = raw.transactions || [];

  for (const [idx, tx] of txs.entries()) {
    const gas = parseBigIntGas(tx.transaction?.gas);
    const contractName = tx.contractName || '';
    const txTo = (tx.transaction?.to || '').toLowerCase();
    const createdAddr = (tx.contractAddress || '').toLowerCase();

    if (EXCLUDED_MOCKS.has(contractName) || (txTo && skippedMockAddresses.has(txTo))) {
      if (createdAddr) skippedMockAddresses.add(createdAddr);
      totalSkippedMockGas += gas;
      continue;
    }

    totalProdGas += gas;
    const exceedsEip7825 = gas > EIP_7825_TX_GAS_CAP;
    if (exceedsEip7825) capViolations += 1;

    prodRows.push({
      script: filePath.split('/').slice(-4, -3)[0] || filePath,
      step: idx + 1,
      type: tx.transactionType || 'CALL',
      contract: contractName || tx.transaction?.to || '(unknown)',
      fn: tx.function || 'constructor()',
      gas: gas.toString(),
      eip7825: exceedsEip7825 ? 'EXCEEDS 16.77M' : 'OK',
    });
  }
}

console.log('\n=== Production Transactions (Mocks Excluded) ===');
console.table(prodRows);

console.log(`Core Suite Production Gas : ${totalProdGas.toLocaleString()} gas (${prodRows.length} txs)`);
console.log(`Excluded Testnet Mock Gas : ${totalSkippedMockGas.toLocaleString()} gas`);

if (capViolations > 0) {
  console.error(`\nERROR: ${capViolations} tx(s) exceed the EIP-7825 16.77M single-tx gas cap.`);
}

let liveBaseFeeGwei = 0.39;
try {
  liveBaseFeeGwei = await fetchLiveBaseFeeGwei(rpcUrl);
} catch (err) {
  console.warn(`Warning: ${err.message} Falling back to 0.39 gwei.`);
}

const livePriorityGwei = 0.04;
const liveEffectiveGwei = Number((liveBaseFeeGwei + livePriorityGwei).toFixed(4));

const fullLaunchGas = totalProdGas + uniswapPoolGas + merkleMigrationGas;

const scenarios = [
  { label: `Live Mainnet (${liveBaseFeeGwei.toFixed(3)} + ${livePriorityGwei})`, gwei: liveEffectiveGwei },
  { label: 'Low Congestion (1 Gwei)', gwei: 1 },
  { label: 'Moderate Traffic (5 Gwei)', gwei: 5 },
  { label: 'Elevated Traffic (15 Gwei)', gwei: 15 },
];

const summary = scenarios.map((s) => {
  const suiteEth = (Number(totalProdGas) * s.gwei) / 1e9;
  const fullEth = (Number(fullLaunchGas) * s.gwei) / 1e9;
  const fundEth = fullEth * fundingMultiplier;
  return {
    Scenario: s.label,
    Gwei: s.gwei,
    'Core Suite (ETH / USD)': `${suiteEth.toFixed(5)} / $${(suiteEth * ethUsd).toFixed(2)}`,
    'Suite + Pool + Merkle (ETH / USD)': `${fullEth.toFixed(5)} / $${(fullEth * ethUsd).toFixed(2)}`,
    'Fund Wallet (+30%)': `${fundEth.toFixed(5)} ETH ($${(fundEth * ethUsd).toFixed(2)})`,
  };
});

console.log(`\nFull Launch Total (Core + ~5.5M Uniswap V3 Pool + ~0.8M Merkle Claim): ${fullLaunchGas.toLocaleString()} gas`);
console.log(`Reference ETH/USD: $${ethUsd.toFixed(2)}\n`);
console.table(summary);
