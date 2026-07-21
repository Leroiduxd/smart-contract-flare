const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  const goldPrice = await core.getPriceExternal.staticCall(5500);
  const exp = await core.exposures(5500);
  const pnl = await core.getUnrealizedPnL.staticCall(5500);

  console.log("=== PNL DEBUG FOR GOLD ===");
  console.log("Gold Price:      ", goldPrice.toString());
  console.log("OI Long:         ", exp.openInterestLong.toString());
  console.log("Avg Entry Long:  ", exp.avgEntryPriceLong.toString());
  console.log("Unrealized PnL:  ", pnl.toString());

  // Let's compute it in JS using BigInt
  const longOI = exp.openInterestLong;
  const avgLong = exp.avgEntryPriceLong;
  const currentPrice = goldPrice;

  if (longOI > 0n && avgLong > 0n) {
    const diff = currentPrice - avgLong;
    const numerator = longOI * diff;
    const computedPnL = numerator / avgLong;
    console.log("Computed JS PnL: ", computedPnL.toString());
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
