const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x96c719b0CAe583f768F7B8D41C59fF85401BF389";
  const USDT_ADDRESS = "0x0e4F39726901edc0139Fdc2862130b401eA821b7";

  const [deployer] = await hre.ethers.getSigners();
  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  console.log("=================================================");
  console.log("   TEST DE TRADING COMPLET (OUVERTURE + CLÔTURE) ");
  console.log("=================================================");
  console.log("Compte Utilisateur :", deployer.address);
  console.log("BrokexCore V2      :", CORE_ADDRESS);

  // 1. Approbation USDT
  console.log("\n1. Approbation USDT pour Core V2...");
  await (await usdt.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();

  // 2. Demande de Preuve TEE pour l'Ouverture
  console.log("\n2. Demande de preuve au service TEE Local (Ouverture)...");
  const resOpen = await fetch("http://localhost:8080/sign-proof", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      assetId: 5500,
      maxOILong: (500000n * 10n**6n).toString(),
      maxOIShort: (500000n * 10n**6n).toString(),
      spreadLong: 100,
      spreadShort: 100
    })
  });
  const dataOpen = await resOpen.json();
  console.log("   Preuve TEE Reçue | Signer:", dataOpen.teeSigner);

  // 3. Ouverture de la Position LONG
  console.log("\n3. Envoi de la transaction d'Ouverture de Position LONG...");
  const openTx = await core.openMarketPosition(
    5500, // assetId OR
    1,    // LONG
    5n * 10n**6n, // 5 USDT Marge
    10,   // 10x Levier
    0,    // sl
    0,    // tp
    dataOpen.proof,
    { gasLimit: 1000000 }
  );
  console.log("   --> Tx Hash Ouverture :", openTx.hash);
  const openReceipt = await openTx.wait();
  console.log("   ✅ Transaction d'Ouverture confirmée dans le bloc :", openReceipt.blockNumber);

  // Récupération de l'ID du trade ouvert
  const nextId = await core.nextTradeId();
  const tradeId = Number(nextId) - 1;
  console.log(`   --> Position #${tradeId} ouverte avec succès !`);

  // 4. Demande de Preuve TEE pour la Clôture
  console.log("\n4. Demande de preuve au service TEE Local (Clôture)...");
  const resClose = await fetch("http://localhost:8080/sign-proof", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      assetId: 5500,
      maxOILong: (500000n * 10n**6n).toString(),
      maxOIShort: (500000n * 10n**6n).toString(),
      spreadLong: 100,
      spreadShort: 100
    })
  });
  const dataClose = await resClose.json();

  // 5. Clôture de la Position
  console.log(`\n5. Envoi de la transaction de Clôture de la Position #${tradeId}...`);
  const closeTx = await core.closePositionMarket(
    5500,
    tradeId,
    dataClose.proof,
    { gasLimit: 1000000 }
  );
  console.log("   --> Tx Hash Clôture :", closeTx.hash);
  const closeReceipt = await closeTx.wait();
  console.log("   ✅ Transaction de Clôture confirmée dans le bloc :", closeReceipt.blockNumber);

  console.log("\n=================================================");
  console.log("🎉 TEST EN DIRECT 100% RÉUSSI SUR COSTON2 TESTNET !");
  console.log("=================================================");
  console.log("Tx Ouverture : https://coston2-explorer.flare.network/tx/" + openTx.hash);
  console.log("Tx Clôture   : https://coston2-explorer.flare.network/tx/" + closeTx.hash);
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
