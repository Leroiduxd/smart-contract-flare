const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x9a1399F58F75E36424bD0E74744f562d513a0df6";
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  const totalLocked = await core.totalLockedCapital();
  const requiredFree = await vault.getRequiredFreeUSDC.staticCall();
  const cfg = await core.assets(5500);

  console.log("=== CAPITAL INFO ===");
  console.log("totalLockedCapital:   ", totalLocked.toString(), `(${Number(totalLocked) / 1e6} USDT)`);
  console.log("getRequiredFreeUSDC:  ", requiredFree.toString(), `(${Number(requiredFree) / 1e6} USDT)`);
  console.log("lockedCapitalBps:     ", cfg.lockedCapitalBps.toString());
  console.log("liqThresholdBps:      ", cfg.liqThresholdBps.toString());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
