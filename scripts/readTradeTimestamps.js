const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  
  const b1 = await provider.getBlock(33006671);
  const b2 = await provider.getBlock(33006963);
  const b3 = await provider.getBlock(33006965);

  console.log("Block 33006671 (Trade 1) Timestamp:", b1.timestamp);
  console.log("Block 33006963 (Deposit 1000) Timestamp:", b2.timestamp);
  console.log("Block 33006965 (Trade 2) Timestamp:", b3.timestamp);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
