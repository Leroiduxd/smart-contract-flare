const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x246E2e421209371182c12D2171a96A20520Cc7DF";
  
  const [deployer] = await hre.ethers.getSigners();
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  console.log("Sending deposit transaction of 10 USDT...");
  try {
    const tx = await vault.deposit(hre.ethers.parseUnits("10", 6));
    console.log("Tx sent:", tx.hash);
    const receipt = await tx.wait();
    console.log("Tx succeeded! Block:", receipt.blockNumber);
  } catch (err) {
    console.error("❌ Transaction failed!");
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
