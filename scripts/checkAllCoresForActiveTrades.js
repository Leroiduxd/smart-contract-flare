const hre = require("hardhat");

async function main() {
  const cores = [
    "0x6681166D8Ab9fCE59B65A14379299a7D1B7b547F",
    "0x3125392eCF85354eDCA8E02649d84EC3E9710dA4",
    "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa",
    "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8"
  ];

  for (const CORE_ADDRESS of cores) {
    console.log(`Checking Core: ${CORE_ADDRESS}...`);
    try {
      const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
      const nextId = await core.nextTradeId();
      let count = 0;
      for (let i = 1; i < Number(nextId); i++) {
        const t = await core.trades(i);
        if (Number(t.state) === 1) {
          console.log(`  Trade #${t.id}:`);
          console.log(`    Trader:    `, t.trader);
          console.log(`    Asset ID:  `, t.assetId.toString());
          console.log(`    Direction: `, t.direction === 0 ? "SHORT" : "LONG");
          console.log(`    Margin:    `, (Number(t.margin)/1e6).toFixed(2), "USDT");
          console.log(`    Leverage:  `, t.leverage.toString(), "x");
          count++;
        }
      }
      console.log(`  Total Active Trades: ${count}`);
    } catch (e) {
      console.log(`  ❌ Failed to query Core at ${CORE_ADDRESS}`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
