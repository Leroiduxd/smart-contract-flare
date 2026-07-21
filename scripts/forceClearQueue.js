const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";
  const [deployer] = await hre.ethers.getSigners();

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  console.log("Vault USDT Balance before donation:", (Number(await usdt.balanceOf(VAULT_ADDRESS))/1e6).toFixed(6), "USDT");

  // Transfer 1 USDT directly to the Vault as donation to cover the dust difference
  console.log("Sending 1.0 USDT donation to Vault...");
  const tx = await usdt.transfer(VAULT_ADDRESS, 1n * 10n**6n);
  await tx.wait();

  console.log("Vault USDT Balance after donation: ", (Number(await usdt.balanceOf(VAULT_ADDRESS))/1e6).toFixed(6), "USDT");

  console.log("Processing queue to clear remaining LP...");
  const tx2 = await vault.processQueue({ gasLimit: 1000000 });
  await tx2.wait();
  console.log("✅ Queue processed.");

  const finalSupply = await vault.totalSupply();
  const finalPrice = await vault.getLPPrice.staticCall();
  const finalUSDT = await usdt.balanceOf(VAULT_ADDRESS);

  console.log("\n=== POST WITHDRAWAL STATE ===");
  console.log("Vault USDT Balance:", (Number(finalUSDT)/1e6).toFixed(6), "USDT");
  console.log("LP Total Supply:   ", hre.ethers.formatUnits(finalSupply, 18), "LP");
  console.log("LP Price:          ", (Number(finalPrice)/1e6).toFixed(6), "USD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
