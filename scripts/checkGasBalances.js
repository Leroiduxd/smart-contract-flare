const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  console.log("Deployer:", deployer.address, "Balance:", hre.ethers.formatEther(await provider.getBalance(deployer.address)), "FLR");

  const wallet2Key = "0x3a565ab9bacf94a909b63aff1148e1dfc48affa6d1460e141fe551fbd1a20ff6";
  const wallet3Key = "0x26eb615475e66d7ba0cf7db12f45ae28ea6669351a5aa22839935af0d19b9b9b";

  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  console.log("Wallet 2:", wallet2.address, "Balance:", hre.ethers.formatEther(await provider.getBalance(wallet2.address)), "FLR");
  console.log("Wallet 3:", wallet3.address, "Balance:", hre.ethers.formatEther(await provider.getBalance(wallet3.address)), "FLR");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
