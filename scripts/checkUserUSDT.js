const hre = require("hardhat");

async function main() {
  const USDT_ADDRESS = "0x2c734516c750C278B89E7744018AC1F9e0Ecda54";
  const VAULT_ADDRESS = "0x246E2e421209371182c12D2171a96A20520Cc7DF";
  const USER_ADDRESS = "0xca30CD2760E48af1Be32C8420e71803DA6735142";

  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS);
  const bal = await usdt.balanceOf(USER_ADDRESS);
  const allowance = await usdt.allowance(USER_ADDRESS, VAULT_ADDRESS);

  console.log("=== USER USDT DETAILS ===");
  console.log("User Balance:  ", bal.toString(), `(${Number(bal) / 1e6} USDT)`);
  console.log("Vault Allowance:", allowance.toString(), `(${Number(allowance) / 1e6} USDT)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
