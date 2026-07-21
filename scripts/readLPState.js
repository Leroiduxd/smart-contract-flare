const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const USDT_ADDRESS = "0x1771cD797E23Fd3C7bcf8912110ac78084302961";
  const VAULT_ADDRESS = "0x9a1399F58F75E36424bD0E74744f562d513a0df6";
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";

  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  const usdtBal = await usdt.balanceOf(VAULT_ADDRESS);
  const totalSupply = await vault.totalSupply();
  const lpPrice = await vault.getLPPrice.staticCall();
  const totalUnrealizedPnL = await core.getTotalUnrealizedPnL.staticCall();
  const goldPrice = await core.getPriceExternal.staticCall(5500);

  console.log("=== VAULT STATE ===");
  console.log("USDT Balance:       ", usdtBal.toString(), `(${Number(usdtBal) / 1e6} USDT)`);
  console.log("LP Total Supply:    ", totalSupply.toString(), `(${Number(totalSupply) / 1e18} LP)`);
  console.log("LP Price (raw):     ", lpPrice.toString(), `(${Number(lpPrice) / 1e6} $)`);
  console.log("Total Unrealized PnL:", totalUnrealizedPnL.toString(), `(${Number(totalUnrealizedPnL) / 1e6} USDT)`);
  console.log("Gold Price:         ", goldPrice.toString(), `(${Number(goldPrice) / 1e6} $)`);

  console.log("\n=== EXPOSURES (Asset 5500) ===");
  const exp = await core.exposures(5500);
  console.log("OI Long:       ", exp.openInterestLong.toString(), `(${Number(exp.openInterestLong) / 1e6} USDT)`);
  console.log("OI Short:      ", exp.openInterestShort.toString(), `(${Number(exp.openInterestShort) / 1e6} USDT)`);
  console.log("Avg Entry Long:", exp.avgEntryPriceLong.toString(), `(${Number(exp.avgEntryPriceLong) / 1e6} $)`);
  console.log("Avg Entry Short:", exp.avgEntryPriceShort.toString(), `(${Number(exp.avgEntryPriceShort) / 1e6} $)`);

  console.log("\n=== ACTIVE TRADES ===");
  const nextId = await core.nextTradeId();
  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    if (Number(t.state) === 1) { // STATE_OPEN
      console.log(`Trade #${t.id}:`);
      console.log(`  Trader:    `, t.trader);
      console.log(`  AssetId:   `, t.assetId.toString());
      console.log(`  Direction: `, Number(t.direction) === 1 ? "LONG" : "SHORT");
      console.log(`  Margin:    `, t.margin.toString(), `(${Number(t.margin) / 1e6} USDT)`);
      console.log(`  Leverage:  `, t.leverage.toString());
      console.log(`  OpenPrice: `, t.openPrice.toString(), `(${Number(t.openPrice) / 1e6} $)`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
