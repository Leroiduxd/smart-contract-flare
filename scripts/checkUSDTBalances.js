const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";
  const USDT_ADDRESS = "0x12e388594341F259AEEb1f23a6a13E6b1898BaC6";

  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS);

  const vaultBal = await usdt.balanceOf(VAULT_ADDRESS);
  const coreBal = await usdt.balanceOf(CORE_ADDRESS);

  console.log("=== CONTRACT USDT BALANCES ===");
  console.log("Vault USDT Balance:", (Number(vaultBal)/1e6).toFixed(6), "USDT");
  console.log("Core USDT Balance: ", (Number(coreBal)/1e6).toFixed(6), "USDT");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
