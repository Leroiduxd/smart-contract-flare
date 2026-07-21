const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  // Wallet 2 and 3 credentials
  const wallet2Key = "0x3a565ab9bacf94a909b63aff1148e1dfc48affa6d1460e141fe551fbd1a20ff6";
  const wallet3Key = "0x26eb615475e66d7ba0cf7db12f45ae28ea6669351a5aa22839935af0d19b9b9b";

  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  const wallets = [wallet2, wallet3];

  console.log("=== RECLAIMING FLR GAS FOR DEPLOYER ===");
  for (const w of wallets) {
    const bal = await provider.getBalance(w.address);
    console.log(`Wallet ${w.address} Balance: ${hre.ethers.formatEther(bal)} FLR`);
    
    // Send all remaining FLR minus a small gas buffer
    if (bal > hre.ethers.parseEther("0.05")) {
      const sendAmt = bal - hre.ethers.parseEther("0.05");
      console.log(`  Sending ${hre.ethers.formatEther(sendAmt)} FLR to deployer...`);
      const tx = await w.sendTransaction({
        to: deployer.address,
        value: sendAmt,
        gasPrice: await provider.getFeeData().then(f => f.gasPrice)
      });
      await tx.wait();
      console.log("  ✅ Sent.");
    }
  }

  const finalBal = await provider.getBalance(deployer.address);
  console.log("Deployer final balance:", hre.ethers.formatEther(finalBal), "FLR");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
