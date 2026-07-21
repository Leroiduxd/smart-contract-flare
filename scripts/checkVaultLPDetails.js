const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const [deployer] = await hre.ethers.getSigners();
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  const supply = await vault.totalSupply();
  const price = await vault.getLPPrice.staticCall();

  console.log("=== RAW VAULT DETAILS ===");
  console.log("Raw totalSupply:", supply.toString());
  console.log("Raw LP Price:   ", price.toString());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
