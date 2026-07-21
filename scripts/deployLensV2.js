const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x96c719b0CAe583f768F7B8D41C59fF85401BF389";
  const VAULT_ADDRESS = "0x696B1A2B6A516209e8f32BAA68eE5970bd2d43c9";

  const [deployer] = await hre.ethers.getSigners();
  console.log("=================================================");
  console.log("    DÉPLOIEMENT DU BROKEX LENS V2 SUR COSTON2   ");
  console.log("=================================================");
  console.log("Déploiement avec le compte :", deployer.address);

  const BrokexLens = await hre.ethers.getContractFactory("contracts/v2/BrokexLens.sol:BrokexLens");
  const lens = await BrokexLens.deploy(CORE_ADDRESS, VAULT_ADDRESS);
  await lens.waitForDeployment();
  const lensAddress = await lens.getAddress();

  console.log("\n  ✅ BrokexLens V2 déployé avec succès à :", lensAddress);
  console.log("=================================================");

  // Test de lecture du snapshot
  const snapshot = await lens.getProtocolSnapshot();
  console.log("  Core Owner       :", snapshot.coreOwner);
  console.log("  TEE Enclave Signer:", snapshot.teeEnclaveSigner);
  console.log("  Dernier Trade ID :", snapshot.lastTradeId.toString());
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
