const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  
  console.log("=================================================");
  console.log(`Déploiement avec le compte : ${deployerAddress}`);
  console.log("=================================================");

  const USDT_ADDRESS = "0xC1A5B41512496B80903D1f32d6dEa3a73212E71F";
  const KMS_SIGNER = deployerAddress; // La clé privée correspond au deployer

  // 1. Déploiement de BrokexVault
  console.log("Déploiement de BrokexVault...");
  const BrokexVault = await hre.ethers.getContractFactory("BrokexVault");
  const vault = await BrokexVault.deploy(USDT_ADDRESS);
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log(`BrokexVault déployé avec succès à : ${vaultAddress}`);

  // 2. Déploiement de BrokexCore
  console.log("Déploiement de BrokexCore...");
  const BrokexCore = await hre.ethers.getContractFactory("BrokexCore");
  const core = await BrokexCore.deploy(vaultAddress, KMS_SIGNER);
  await core.waitForDeployment();
  const coreAddress = await core.getAddress();
  console.log(`BrokexCore déployé avec succès à : ${coreAddress}`);

  // 3. Liaison de BrokexCore dans BrokexVault
  console.log("Configuration de BrokexCore comme Primary Core dans le Vault...");
  const tx = await vault.setPrimaryCore(coreAddress);
  await tx.wait();
  console.log("Liaison du Core effectuée avec succès !");
  
  console.log("=================================================");
  console.log("RÉSUMÉ DES ADRESSES DÉPLOYÉES :");
  console.log(`USDT (existant)    : ${USDT_ADDRESS}`);
  console.log(`KMS Signer         : ${KMS_SIGNER}`);
  console.log(`BrokexVault        : ${vaultAddress}`);
  console.log(`BrokexCore         : ${coreAddress}`);
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
