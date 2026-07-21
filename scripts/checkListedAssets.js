const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x9bdD4Ca25110ae2571b1a42f18050230D04C334F";
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  try {
    const ids = [];
    let i = 0;
    while (true) {
      try {
        const id = await core.listedAssetIds(i);
        ids.push(id.toString());
        i++;
      } catch (e) {
        break; // Out of bounds
      }
    }
    console.log("Listed Asset IDs:", ids);
    
    for (const id of ids) {
      try {
        const price = await core.getPriceExternal.staticCall(id);
        console.log(`Asset ${id} price:`, price.toString());
      } catch (priceErr) {
        console.error(`❌ Asset ${id} getPriceExternal reverted:`, priceErr.message);
      }
    }
  } catch (err) {
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
