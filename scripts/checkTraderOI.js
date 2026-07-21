const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x6681166D8Ab9fCE59B65A14379299a7D1B7b547F";
  const USER_ADDRESS = "0xca30CD2760E48af1Be32C8420e71803DA6735142";

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  
  const traderOI = await core.traderOpenInterest(5600, USER_ADDRESS);
  const assetConfig = await core.assets(5600);

  console.log("=== BTC ASSET CONFIG & TRADER OI ===");
  console.log("Trader Current OI on BTC:", traderOI.toString(), `(${Number(traderOI)/1e6} USDT)`);
  console.log("Asset config details:");
  console.log("  listed:", assetConfig.listed);
  console.log("  minLeverage:", assetConfig.minLeverage.toString());
  console.log("  maxLeverage:", assetConfig.maxLeverage.toString());
  console.log("  minTradeSize:", assetConfig.minTradeSize.toString());
  console.log("  maxTraderOI:", assetConfig.maxTraderOI.toString(), `(${Number(assetConfig.maxTraderOI)/1e6} USDT)`);
  console.log("  maxGlobalOI:", assetConfig.maxGlobalOI.toString(), `(${Number(assetConfig.maxGlobalOI)/1e6} USDT)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
