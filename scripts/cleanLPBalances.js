const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";
  const USDT_ADDRESS = "0x12e388594341F259AEEb1f23a6a13E6b1898BaC6";

  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const wallet2Key = "0x3ebe9cbf7ceca96b75082d555a4ded93a602599a66756780bfc8a914ea11ae0e";
  const wallet3Key = "0xa63418e7e81a052df6a22a48c2e17c4ff805c7e2596222492d8caedde37106fc";

  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  const wallets = [wallet2, wallet3];

  console.log("=== CHECKING & CLEANING LP BALANCES ===");
  
  for (const w of wallets) {
    const vaultW = vault.connect(w);
    const lpBal = await vaultW.balanceOf(w.address);
    console.log(`Wallet ${w.address}: LP Balance = ${hre.ethers.formatUnits(lpBal, 18)} LP`);
    
    if (lpBal > 0n) {
      console.log(`  Requesting withdrawal of all LPs...`);
      const tx = await vaultW.requestWithdraw(lpBal);
      await tx.wait();
      console.log(`  ✅ Withdrawal request registered.`);
    }
  }

  console.log("\nProcessing withdrawal queue...");
  try {
    const tx = await vault.processQueue();
    await tx.wait();
    console.log("  ✅ Queue processed.");
  } catch (err) {
    console.log("  ℹ️ processQueue reverted:", err.message);
  }

  // Transfer remaining USDT to deployer
  for (const w of wallets) {
    const usdtW = usdt.connect(w);
    const usdtBal = await usdtW.balanceOf(w.address);
    if (usdtBal > 0n) {
      console.log(`Transferring ${Number(usdtBal)/1e6} USDT back to deployer from ${w.address}...`);
      await (await usdtW.transfer(deployer.address, usdtBal)).wait();
      console.log(`  ✅ Transferred.`);
    }
  }

  const finalSupply = await vault.totalSupply();
  const finalPrice = await vault.getLPPrice.staticCall();
  console.log("\n=== FINAL STATE ===");
  console.log("LP Total Supply:", hre.ethers.formatUnits(finalSupply, 18), "LP");
  console.log("LP Price:       ", (Number(finalPrice)/1e6).toFixed(6), "USD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
