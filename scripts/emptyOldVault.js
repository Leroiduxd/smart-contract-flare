const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Vidage complet de l'ancien Vault pour : ${deployer.address}`);

  const OLD_VAULT = "0x19E9E0c71b672aAaadee26532dA80D330399fa11";
  
  const vault = await ethers.getContractAt(
    [
      "function withdraw(uint256 amount) external"
    ],
    OLD_VAULT
  );

  const usdt = await ethers.getContractAt(
    ["function balanceOf(address account) external view returns (uint256)"],
    "0xC1A5B41512496B80903D1f32d6dEa3a73212E71F"
  );

  const balOld = await usdt.balanceOf(OLD_VAULT);
  console.log(`Solde restant de l'ancien Vault : ${ethers.formatUnits(balOld, 6)} USDT`);

  if (balOld > 0n) {
    console.log(`Retrait de ${ethers.formatUnits(balOld, 6)} USDT...`);
    const tx = await vault.withdraw(balOld);
    await tx.wait();
    console.log("✅ Ancien Vault vidé avec succès !");
  } else {
    console.log("L'ancien Vault est déjà vide.");
  }

  const finalBalDeployer = await usdt.balanceOf(deployer.address);
  console.log(`Solde du deployer : ${ethers.formatUnits(finalBalDeployer, 6)} USDT`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
