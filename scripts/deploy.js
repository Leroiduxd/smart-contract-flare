const hre = require("hardhat");

async function main() {
  console.log("Déploiement des smart contracts...");

  // Déploiement Gold Oracle
  const BrokexOracleFTSO = await hre.ethers.getContractFactory("BrokexOracleFTSO");
  const goldContract = await BrokexOracleFTSO.deploy();
  await goldContract.waitForDeployment();
  const goldAddress = await goldContract.getAddress();
  console.log(`BrokexOracleFTSO (Gold) déployé à : ${goldAddress}`);

  // Déploiement BTC Oracle
  const BrokexOracleBTCFTSO = await hre.ethers.getContractFactory("BrokexOracleBTCFTSO");
  const btcContract = await BrokexOracleBTCFTSO.deploy();
  await btcContract.waitForDeployment();
  const btcAddress = await btcContract.getAddress();
  console.log(`BrokexOracleBTCFTSO (BTC) déployé à : ${btcAddress}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
