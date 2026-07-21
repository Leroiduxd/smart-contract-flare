const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";
  const USDT_ADDRESS = "0x12e388594341F259AEEb1f23a6a13E6b1898BaC6";
  const [deployer] = await hre.ethers.getSigners();

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  const lpBal = await vault.balanceOf(deployer.address);
  console.log(`Deployer LP Balance: ${hre.ethers.formatUnits(lpBal, 18)} LP`);

  if (lpBal > 0n) {
    console.log("Requesting withdrawal of all remaining LP...");
    const tx = await vault.requestWithdraw(lpBal);
    await tx.wait();
    console.log("Withdrawal request registered successfully!");

    console.log("Processing withdrawal queue...");
    const tx2 = await vault.processQueue({ gasLimit: 1000000 });
    await tx2.wait();
    console.log("Queue processed successfully!");
  } else {
    console.log("Deployer has no LP balance.");
  }

  const finalUSDT = await usdt.balanceOf(VAULT_ADDRESS);
  const finalSupply = await vault.totalSupply();
  
  console.log("\n=== POST WITHDRAWAL STATE ===");
  console.log("Vault USDT Balance:", (Number(finalUSDT)/1e6).toFixed(6), "USDT");
  console.log("LP Total Supply:   ", hre.ethers.formatUnits(finalSupply, 18), "LP");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
