const { ethers } = require("hardhat");

async function main() {
  const USDT_ADDRESS = "0xC1A5B41512496B80903D1f32d6dEa3a73212E71F";
  const OLD_VAULT = "0x19E9E0c71b672aAaadee26532dA80D330399fa11";
  const NEW_VAULT = "0xdD68Cb3Fe62a82a0E2dabC43BC58f9eCF8423d6E";
  const DEPLOYER = "0xca30CD2760E48af1Be32C8420e71803DA6735142";

  const usdt = await ethers.getContractAt(
    ["function balanceOf(address account) external view returns (uint256)"],
    USDT_ADDRESS
  );

  const balDeployer = await usdt.balanceOf(DEPLOYER);
  const balOld = await usdt.balanceOf(OLD_VAULT);
  const balNew = await usdt.balanceOf(NEW_VAULT);

  console.log(`Deployer: ${ethers.formatUnits(balDeployer, 6)} USDT`);
  console.log(`Old Vault: ${ethers.formatUnits(balOld, 6)} USDT`);
  console.log(`New Vault: ${ethers.formatUnits(balNew, 6)} USDT`);
}

main().catch(console.error);
