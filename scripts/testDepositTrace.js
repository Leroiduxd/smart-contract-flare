const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const [deployer] = await hre.ethers.getSigners();

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  console.log("Simulating vault.deposit()...");
  try {
    await vault.deposit.staticCall(100n * 10n**6n);
    console.log("Success! deposit staticCall passes.");
  } catch (err) {
    console.error("❌ deposit staticCall failed:");
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
