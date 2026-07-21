const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  const nextId = await core.nextTradeId();
  
  console.log(`=== ALL ACTIVE TRADES (Next Trade ID: ${nextId}) ===`);
  
  let count = 0;
  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    if (Number(t.state) === 1) {
      console.log(`Trade #${t.id}:`);
      console.log(`  Trader:    `, t.trader);
      console.log(`  Asset ID:  `, t.assetId.toString());
      console.log(`  Direction: `, t.direction === 0 ? "SHORT" : "LONG");
      console.log(`  Margin:    `, t.margin.toString(), `(${Number(t.margin)/1e6} USDT)`);
      console.log(`  Leverage:  `, t.leverage.toString(), "x");
      console.log(`  OI:        `, (Number(t.margin) * Number(t.leverage)).toString(), `(${Number(t.margin) * Number(t.leverage) / 1e6} USDT)`);
      count++;
    }
  }
  console.log(`Total Active Trades found: ${count}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
