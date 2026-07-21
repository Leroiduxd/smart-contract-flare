const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  
  console.log("=================================================");
  console.log(`Déploiement avec le compte : ${deployerAddress}`);
  console.log("=================================================");

  // 1. Déploiement de USDTMock
  console.log("Déploiement de USDTMock...");
  const USDTMock = await hre.ethers.getContractFactory("USDTMock");
  const usdt = await USDTMock.deploy();
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  console.log(`USDTMock déployé avec succès à : ${usdtAddress}`);

  // 2. Déploiement de BrokexVault
  console.log("Déploiement de BrokexVault...");
  const BrokexVault = await hre.ethers.getContractFactory("BrokexVault");
  const vault = await BrokexVault.deploy(usdtAddress, "Brokex LP Token", "bLP");
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log(`BrokexVault déployé avec succès à : ${vaultAddress}`);

  // 3. Déploiement de BrokexCore
  console.log("Déploiement de BrokexCore...");
  const BrokexCore = await hre.ethers.getContractFactory("BrokexCore");
  const core = await BrokexCore.deploy(vaultAddress, deployerAddress);
  await core.waitForDeployment();
  const coreAddress = await core.getAddress();
  console.log(`BrokexCore déployé avec succès à : ${coreAddress}`);

  // 4. Liaison de BrokexCore dans BrokexVault
  console.log("Configuration de BrokexCore comme Primary Core dans le Vault...");
  const tx1 = await vault.setPrimaryCore(coreAddress);
  await tx1.wait();
  console.log("Liaison du Core effectuée avec succès !");

  // 5. Approbation et Dépôt de 100 USDT (100 * 10^6 car 6 décimales)
  const depositAmount = 100n * 10n**6n;
  console.log(`Approbation de ${depositAmount} USDT pour le Vault...`);
  const tx2 = await usdt.approve(vaultAddress, depositAmount);
  await tx2.wait();

  console.log("Dépôt de 100 USDT dans le Vault...");
  const tx3 = await vault.deposit(depositAmount);
  await tx3.wait();
  console.log("Dépôt effectué avec succès !");

  // 6. Enregistrement de l'actif OR (ID 5500)
  console.log("Listing de l'actif OR (ID 5500)...");
  const goldConfig = {
    feedId: "0x01504158472f555344000000000000000000000000",
    minLeverage: 2,                        // 2x
    maxLeverage: 50,                       // 50x
    minTradeSize: 1000000,                 // 1 USDT
    commissionBps: 700,                    // 0.07%
    borrowRateHourly: 22,                  // 0.0022%
    profitCap: 100000,                     // 10%
    executionTolerance: 500,               // 0.05%
    maxProofAge: 3600,                     // 1 heure
    maxTraderOI: 1000000n * 10n**6n,       // 1M USDT
    maxGlobalOI: 100000000n * 10n**6n,     // 100M USDT
    lockedCapitalBps: 50000,               // 5%
    liqThresholdBps: 950000,               // 95%
    listed: true,
    frozen: false
  };

  const tx4 = await core.listAsset(5500, goldConfig);
  await tx4.wait();
  console.log("✅ Actif OR configuré et listé !");

  // 7. Enregistrement de l'actif BTC (ID 5600)
  console.log("Listing de l'actif BTC (ID 5600)...");
  const btcConfig = {
    feedId: "0x014254432f55534400000000000000000000000000",
    minLeverage: 2,                        // 2x
    maxLeverage: 50,                       // 50x
    minTradeSize: 1000000,                 // 1 USDT
    commissionBps: 700,                    // 0.07%
    borrowRateHourly: 22,                  // 0.0022%
    profitCap: 100000,                     // 10%
    executionTolerance: 500,               // 0.05%
    maxProofAge: 3600,                     // 1 heure
    maxTraderOI: 5000000000,               // 5k USDT
    maxGlobalOI: 200000000000,             // 200k USDT
    lockedCapitalBps: 50000,               // 5%
    liqThresholdBps: 950000,               // 95%
    listed: true,
    frozen: false
  };

  const tx5 = await core.listAsset(5600, btcConfig);
  await tx5.wait();
  console.log("✅ Actif BTC configuré et listé !");

  console.log("=================================================");
  console.log("RÉSUMÉ COMPLET :");
  console.log(`Mock USDT   : ${usdtAddress}`);
  console.log(`Vault       : ${vaultAddress}`);
  console.log(`Core        : ${coreAddress}`);
  console.log(`Solde Vault : ${await usdt.balanceOf(vaultAddress)} USDT`);
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
