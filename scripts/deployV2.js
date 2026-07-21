const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("=================================================");
  console.log("    DÉPLOIEMENT DU NOUVEAU PROTOCOLE BROKEX V2   ");
  console.log("=================================================");
  console.log("Déploiement avec le compte :", deployer.address);
  
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Solde FLR du compte :", hre.ethers.formatEther(balance), "FLR");

  // 1. Déploiement du Mock USDT
  console.log("\n1. Déploiement de USDTMock...");
  const USDTMock = await hre.ethers.getContractFactory("USDTMock");
  const usdt = await USDTMock.deploy();
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  console.log("  ✅ USDTMock v2 déployé à :", usdtAddress);

  // 2. Déploiement de BrokexVault v2
  console.log("\n2. Déploiement de BrokexVault v2...");
  const BrokexVault = await hre.ethers.getContractFactory("contracts/v2/BrokexVault.sol:BrokexVault");
  const vault = await BrokexVault.deploy(usdtAddress, "Brokex LP", "BLP");
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log("  ✅ BrokexVault v2 déployé à :", vaultAddress);

  // 3. TEE Enclave Signer Address
  const teeSignerAddress = "0xFb8A8f2FDfEc07Ab74DE429aC041F70fC9B48c03";
  const teeExtensionRegistry = "0x44A446BF66Af52a4235b5b4AF4D7BDB92Dd749fd";
  const teeMachineRegistry = "0xCeCb92824dc00b2178a4b8E33acEAB1e80dbE40B";

  // 4. Déploiement de BrokexCore v2
  console.log("\n3. Déploiement de BrokexCore v2...");
  const BrokexCore = await hre.ethers.getContractFactory("contracts/v2/BrokexCore.sol:BrokexCore");
  const core = await BrokexCore.deploy(
    vaultAddress,
    teeSignerAddress,
    teeExtensionRegistry,
    teeMachineRegistry
  );
  await core.waitForDeployment();
  const coreAddress = await core.getAddress();
  console.log("  ✅ BrokexCore v2 déployé à :", coreAddress);

  // 5. Configuration du Vault (Liaison du Core)
  console.log("\n4. Liaison de BrokexCore v2 dans le Vault v2...");
  const setCoreTx = await vault.setPrimaryCore(coreAddress);
  await setCoreTx.wait();
  console.log("  ✅ Core v2 lié au Vault v2 !");

  // 6. Dépôt de liquidité initiale dans le Vault (100 USDT)
  console.log("\n5. Dépôt de 100 USDT dans le Vault v2...");
  await (await usdt.approve(vaultAddress, hre.ethers.MaxUint256)).wait();
  await (await vault.deposit(100n * 10n**6n, { gasLimit: 1000000 })).wait();
  console.log("  ✅ Dépôt initial de 100 USDT effectué !");

  // 7. Listing des actifs (OR & BTC)
  const configTemplate = {
    profitCap: 100000,
    executionTolerance: 500,
    maxProofAge: 3600,
    maxTraderOI: 1000000n * 10n**6n, // 1M USDT
    maxGlobalOI: 100000000n * 10n**6n, // 100M USDT
    lockedCapitalBps: 50000, // 5%
    liqThresholdBps: 950000, // 95%
    listed: true,
    frozen: false,
    minLeverage: 2,
    maxLeverage: 50,
    minTradeSize: 1000000n, // 1 USDT
    commissionBps: 1000, // 0.1%
    borrowRateHourly: 50 // 0.005%
  };

  console.log("\n6. Listing de l'actif OR (ID 5500)...");
  await (await core.listAsset(5500, { ...configTemplate, feedId: "0x01474f4c442f555344000000000000000000000000" })).wait();
  console.log("  ✅ OR (5500) listé !");

  console.log("7. Listing de l'actif BTC (ID 5600)...");
  await (await core.listAsset(5600, { ...configTemplate, feedId: "0x014254432f55534400000000000000000000000000" })).wait();
  console.log("  ✅ BTC (5600) listé !");

  console.log("=================================================");
  console.log("        NOUVEAU PROTOCOLE BROKEX V2 PRÊT         ");
  console.log("=================================================");
  console.log("Mock USDT   :", usdtAddress);
  console.log("Vault v2    :", vaultAddress);
  console.log("Core v2     :", coreAddress);
  console.log("TEE Signer  :", teeSignerAddress);
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
