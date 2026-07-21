const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Récupération de l'USDT depuis l'ancien Vault pour : ${deployer.address}`);

  const OLD_VAULT = "0x19E9E0c71b672aAaadee26532dA80D330399fa11";
  const OLD_CORE = "0x04A7CDf3b3AfF0a0F84a94C48095d84baa91eC11";

  const core = await ethers.getContractAt(
    ["function enableEmergencyMode() external", "function emergencyMode() external view returns (bool)"],
    OLD_CORE
  );

  const vault = await ethers.getContractAt(
    ["function withdraw(uint256 amount) external"],
    OLD_VAULT
  );

  const isEmergency = await core.emergencyMode();
  console.log(`Emergency mode actif sur l'ancien Core : ${isEmergency}`);

  if (!isEmergency) {
    console.log("Activation du mode d'urgence sur l'ancien Core...");
    const txEmergency = await core.enableEmergencyMode();
    await txEmergency.wait();
    console.log("✅ Mode d'urgence activé.");
  }

  console.log("Appel à withdraw(5 USDT) depuis le Vault...");
  const tx = await vault.withdraw(ethers.parseUnits("5", 6));
  await tx.wait();
  console.log("✅ USDT récupéré avec succès !");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
