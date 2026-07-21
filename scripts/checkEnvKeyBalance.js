const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;
  console.log("Account from .env:", deployer.address);
  const bal = await provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(bal), "FLR");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
