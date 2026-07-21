const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";
  const USDT_ADDRESS = "0x12e388594341F259AEEb1f23a6a13E6b1898BaC6";

  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS);

  const head = await vault.queueHead();
  const tail = await vault.queueTail();
  const totalUSDT = await usdt.balanceOf(VAULT_ADDRESS);
  const lockedCap = await core.totalLockedCapital();
  const price = await vault.getLPPrice.staticCall();

  console.log("=== QUEUE DEBUG ===");
  console.log("Queue Head:        ", head.toString());
  console.log("Queue Tail:        ", tail.toString());
  console.log("Vault USDT Balance:", (Number(totalUSDT)/1e6).toFixed(6), "USDT");
  console.log("Core Locked Capital:", (Number(lockedCap)/1e6).toFixed(6), "USDT");
  console.log("LP Price:          ", (Number(price)/1e6).toFixed(6), "USD");

  if (Number(head) < Number(tail)) {
    const req = await vault.withdrawalQueue(head);
    console.log(`Request #${head} Details:`);
    console.log(`  User:               `, req.user);
    console.log(`  LP Amount Remaining:`, hre.ethers.formatUnits(req.lpAmountRemaining, 18), "LP");
    const valueUSDT = (req.lpAmountRemaining * price) / 10n**18n;
    console.log(`  Value in USDT:      `, (Number(valueUSDT)/1e6).toFixed(6), "USDT");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
