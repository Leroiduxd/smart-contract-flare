const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const VAULT_ADDRESS = "0x9a1399F58F75E36424bD0E74744f562d513a0df6";
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  const currentBlock = await provider.getBlockNumber();
  
  let allDeposits = [];
  let allTrades = [];
  
  const CHUNK_SIZE = 30;
  const TOTAL_BLOCKS = 1000;
  
  const startBlock = currentBlock - TOTAL_BLOCKS;
  
  console.log(`Querying events from block ${startBlock} to ${currentBlock} in chunks of ${CHUNK_SIZE}...`);
  
  for (let from = startBlock; from < currentBlock; from += CHUNK_SIZE) {
    const to = Math.min(from + CHUNK_SIZE - 1, currentBlock);
    
    // Vault Deposits
    const depositFilter = vault.filters.Deposit();
    const deposits = await vault.queryFilter(depositFilter, from, to);
    allDeposits = allDeposits.concat(deposits);
    
    // Core Trades
    const tradeFilter = core.filters.TradeEvent();
    const trades = await core.queryFilter(tradeFilter, from, to);
    allTrades = allTrades.concat(trades);
  }

  console.log("=== VAULT DEPOSIT EVENTS ===");
  for (const d of allDeposits) {
    console.log(`Block ${d.blockNumber}:`);
    console.log(`  User:      `, d.args.user);
    console.log(`  Amount:    `, d.args.amountIn.toString(), `(${Number(d.args.amountIn) / 1e6} USDT)`);
    console.log(`  LPMinted:  `, d.args.lpMinted.toString(), `(${Number(d.args.lpMinted) / 1e18} LP)`);
    console.log(`  Price:     `, d.args.priceAtDeposit.toString(), `(${Number(d.args.priceAtDeposit) / 1e6} $)`);
  }

  console.log("\n=== CORE TRADE EVENT LOGS ===");
  for (const t of allTrades) {
    console.log(`Block ${t.blockNumber}: Trade ID ${t.args.tradeId.toString()}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
