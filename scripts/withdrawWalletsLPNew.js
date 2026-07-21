const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const wallet2Key = "0x3a565ab9bacf94a909b63aff1148e1dfc48affa6d1460e141fe551fbd1a20ff6";
  const wallet3Key = "0x26eb615475e66d7ba0cf7db12f45ae28ea6669351a5aa22839935af0d19b9b9b";

  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  const wallets = [wallet2, wallet3];
  
  console.log("=== REQUESTING LP WITHDRAWAL FOR SECONDARY WALLETS ===");
  for (const w of wallets) {
    const vaultW = vault.connect(w);
    const lpBal = await vaultW.balanceOf(w.address);
    console.log(`Wallet ${w.address} LP Balance: ${hre.ethers.formatUnits(lpBal, 18)} LP`);
    if (lpBal > 0n) {
      console.log(`  Requesting withdrawal...`);
      await (await vaultW.requestWithdraw(lpBal)).wait();
      console.log(`  ✅ Registered.`);
    }
  }

  console.log("Processing queue...");
  await (await vault.processQueue({ gasLimit: 1000000 })).wait();
  console.log("✅ Queue processed.");

  const finalSupply = await vault.totalSupply();
  const finalPrice = await vault.getLPPrice.staticCall();
  const finalUSDT = await (await hre.ethers.getContractAt("USDTMock", await vault.USDT())).balanceOf(VAULT_ADDRESS);

  console.log("\n=== POST WITHDRAWAL STATE ===");
  console.log("Vault USDT Balance:", (Number(finalUSDT)/1e6).toFixed(6), "USDT");
  console.log("LP Total Supply:   ", hre.ethers.formatUnits(finalSupply, 18), "LP");
  console.log("LP Price:          ", (Number(finalPrice)/1e6).toFixed(6), "USD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
