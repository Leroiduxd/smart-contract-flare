const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;
  const USDT_ADDRESS = "0xA5F683378B693e0311fC4B5d8DF6050F32577d80";

  const flrBal = await provider.getBalance(deployer.address);
  
  let usdtBal = 0n;
  try {
    const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);
    usdtBal = await usdt.balanceOf(deployer.address);
  } catch (e) {}

  console.log("=== MAIN WALLET BALANCES ===");
  console.log("FLR Balance: ", hre.ethers.formatEther(flrBal), "FLR");
  console.log("USDT Balance:", (Number(usdtBal) / 1e6).toFixed(2), "USDT");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
