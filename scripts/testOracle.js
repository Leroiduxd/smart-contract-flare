const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x3125392eCF85354eDCA8E02649d84EC3E9710dA4";
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  console.log("Fetching Gold price...");
  try {
    const goldPrice = await core.getPriceExternal.staticCall(5500);
    console.log("Gold Price:", goldPrice.toString());
  } catch (err) {
    console.error("❌ Gold Price call reverted:", err.message);
  }

  console.log("Fetching BTC price...");
  try {
    const btcPrice = await core.getPriceExternal.staticCall(5600);
    console.log("BTC Price:", btcPrice.toString());
  } catch (err) {
    console.error("❌ BTC Price call reverted:", err.message);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
