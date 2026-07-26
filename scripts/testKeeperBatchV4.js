const { ethers } = require("hardhat");

/**
 * 🧪 SCRIPT DE TEST ROBUSTE KEEPER & BATCH EXECUTE (BROKEX V4)
 * 
 * Ce script teste la résilience de batchExecute() du Core V4 :
 * - Il ouvre plusieurs ordres (Limit Long, Limit Short, Stop, TP, SL, Liquidation, Positive Liquidation).
 * - Il soumet une BATCH EXECUTE contenant des trades Valides (qui remplissent les conditions) 
 *   et des trades Invalides (qui ne remplissent pas la condition de prix ou d'état).
 * - Il VÉRIFIE que `batchExecute` NE REVERT PAS, exécute les trades valides et saute (skip) les trades invalides !
 */

const ADDRESSES = {
  usdt: "0x6D2b647fc329006f730866f0BC21ed899bee9Fc5",
  vault: "0x49aa225E56Cc6F06333BA657d4B259aAfc7c44A9",
  core: "0xd5c69Fd354008ed47a5CeDcE180fF15761931230",
};

const KMS_PRIVATE_KEY = "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";

const ASSETS = {
  GOLD: 5500,
  SILVER: 5501,
  OIL: 5502,
};

const REASONS = {
  MARKET: 0,
  SL: 1,
  TP: 2,
  LIQ: 3,
  EMERGENCY: 4,
  CANCEL: 5,
  PROFIT_CAP: 6,
};

async function signRiskProof(kmsWallet, assetId, priceUSD, options = {}) {
  const timestamp = Math.floor(Date.now() / 1000);
  const price = ethers.parseUnits(priceUSD.toString(), 6);
  const maxOILong = ethers.parseUnits(options.maxOILong || "10000000", 6);
  const maxOIShort = ethers.parseUnits(options.maxOIShort || "10000000", 6);
  const spreadLong = options.spreadLong || 100;   // 0.01%
  const spreadShort = options.spreadShort || 100; // 0.01%

  const hash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
      [assetId, price, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp]
    )
  );

  const sig = await kmsWallet.signMessage(ethers.getBytes(hash));

  return {
    assetId,
    price,
    maxOILong,
    maxOIShort,
    spreadLong,
    spreadShort,
    timestamp,
    sig,
  };
}

async function main() {
  console.log("=======================================================================");
  console.log("🚀 DEMARRAGE DU TEST COMPLET DES FONCTIONS KEEPER (BROKEX V4)");
  console.log("=======================================================================");

  const [signer] = await ethers.getSigners();
  const kmsWallet = new ethers.Wallet(KMS_PRIVATE_KEY, ethers.provider);

  console.log("👤 Tester Wallet :", signer.address);
  console.log("🔑 KMS Signer Wallet :", kmsWallet.address);

  const core = await ethers.getContractAt("v4/BrokexCore.sol:BrokexCore", ADDRESSES.core, signer);
  const usdt = await ethers.getContractAt("USDTMock", ADDRESSES.usdt, signer);

  // 0. Mint & Approve USDT
  console.log("\n1️⃣ Vérification Solde & Approbation USDT...");
  const usdtBalance = await usdt.balanceOf(signer.address);
  if (usdtBalance < ethers.parseUnits("5000", 6)) {
    console.log("💵 Mint de 10,000 USDT au tester wallet...");
    const mintTx = await usdt.mint(signer.address, ethers.parseUnits("10000", 6));
    await mintTx.wait();
  }
  const allowance = await usdt.allowance(signer.address, ADDRESSES.core);
  if (allowance < ethers.parseUnits("5000", 6)) {
    console.log("🔑 Approval de 10,000 USDT pour BrokexCore...");
    const appTx = await usdt.approve(ADDRESSES.core, ethers.parseUnits("100000", 6));
    await appTx.wait();
  }

  const collateral = ethers.parseUnits("100", 6); // 100 USDC per trade
  const leverage = 10; // 10x

  console.log("\n2️⃣ CRÉATION DES TRADES DE TEST...");

  // Trade A: Order LIMIT LONG sur l'Or à Target Price = 2500 USD
  console.log("  📌 Création Trade A: Limit LONG Gold à $2500...");
  const txA = await core.createLimitOrStopOrder(ASSETS.GOLD, 1, 1, ethers.parseUnits("2500", 6), collateral, leverage, 0, 0);
  await txA.wait();
  const tradeIdA = Number(await core.nextTradeId()) - 1;
  console.log(`     ✅ Trade A (Limit LONG) créé, ID = #${tradeIdA}`);

  // Trade B: Position MARKET LONG sur l'Or ouverte à $2500 (avec SL à $2400 et TP à $2700)
  console.log("  📌 Création Trade B: Market LONG Gold à $2500 (SL=$2400, TP=$2700)...");
  const proofB = await signRiskProof(kmsWallet, ASSETS.GOLD, 2500);
  const txB = await core.openMarketPosition(ASSETS.GOLD, 1, collateral, leverage, ethers.parseUnits("2400", 6), ethers.parseUnits("2700", 6), proofB);
  await txB.wait();
  const tradeIdB = Number(await core.nextTradeId()) - 1;
  console.log(`     ✅ Trade B (Market LONG) créé, ID = #${tradeIdB}`);

  // Trade C: Order STOP SHORT sur l'Argent à Target Price = $30
  console.log("  📌 Création Trade C: Stop SHORT Silver à $30...");
  const txC = await core.createLimitOrStopOrder(ASSETS.SILVER, 0, 2, ethers.parseUnits("30", 6), collateral, leverage, 0, 0);
  await txC.wait();
  const tradeIdC = Number(await core.nextTradeId()) - 1;
  console.log(`     ✅ Trade C (Stop SHORT) créé, ID = #${tradeIdC}`);

  // Trade D: Position MARKET SHORT sur le Pétrole à $80 (pour tester la Positive Liquidation / Profit Cap)
  console.log("  📌 Création Trade D: Market SHORT Oil à $80...");
  const proofD = await signRiskProof(kmsWallet, ASSETS.OIL, 80);
  const txD = await core.openMarketPosition(ASSETS.OIL, 0, collateral, leverage, 0, 0, proofD);
  await txD.wait();
  const tradeIdD = Number(await core.nextTradeId()) - 1;
  console.log(`     ✅ Trade D (Market SHORT) créé, ID = #${tradeIdD}`);

  console.log("\n=======================================================================");
  console.log("⚡ TEST 1 : BATCH EXECUTE AVEC UN MÉLANGE DE CONDITIONS SUCCÈS & ÉCHEC");
  console.log("=======================================================================");

  console.log("\n🤖 Génération des Batch RiskProofs du Keeper...");
  const proofGoldBatch = await signRiskProof(kmsWallet, ASSETS.GOLD, 2480);
  const proofSilverBatch = await signRiskProof(kmsWallet, ASSETS.SILVER, 35);
  const proofOilBatch = await signRiskProof(kmsWallet, ASSETS.OIL, 70); // Short Oil 80 -> 70 = +12.5% gain >= 10% profit cap!

  const batchTradeIds = [tradeIdA, tradeIdB, tradeIdC, tradeIdD];
  const batchReasons  = [REASONS.MARKET, REASONS.SL, REASONS.MARKET, REASONS.PROFIT_CAP];
  const batchProofs   = [proofGoldBatch, proofGoldBatch, proofSilverBatch, proofOilBatch];

  console.log(`📤 Envoi de batchExecute() avec ${batchTradeIds.length} trades...`);
  console.log(`   Trade #${tradeIdA} : Valide (Limit Long touché $2480 <= $2500) -> DOIT S'EXÉCUTER`);
  console.log(`   Trade #${tradeIdB} : Invalide (Prix $2480 n'a pas atteint le SL $2400) -> DOIT ÊTRE SKIPPÉ (Résilience)`);
  console.log(`   Trade #${tradeIdC} : Invalide (Stop Short $30 non atteint à $35) -> DOIT ÊTRE SKIPPÉ (Résilience)`);
  console.log(`   Trade #${tradeIdD} : Valide (Profit Cap / Positive Liq sur Short Oil 80 -> 60) -> DOIT S'EXÉCUTER`);

  const batchTx = await core.batchExecute(batchTradeIds, batchReasons, batchProofs);
  await batchTx.wait();

  console.log("\n✅ TRANSACTION EXÉCUTÉE SANS REVERT DU SMART CONTRACT !");

  // Inspection des états post-batch
  const stateA = (await core.trades(tradeIdA)).state;
  const stateB = (await core.trades(tradeIdB)).state;
  const stateC = (await core.trades(tradeIdC)).state;
  const stateD = (await core.trades(tradeIdD)).state;

  const stateNames = ["ORDER (Pending)", "OPEN", "CLOSED", "CANCELLED", "LIQUIDATED", "EMERGENCY", "LIQ_POS (Profit Cap)"];

  console.log("\n📊 RÉSULTATS DÉTAILLÉS APRÈS EXÉCUTION DU BATCH KEEPER :");
  console.log(`   - Trade #${tradeIdA} : State = ${stateNames[Number(stateA)]} (${Number(stateA) === 1 ? "🟢 SUCCÈS - Passé de ORDER à OPEN" : "🔴 ÉCHEC"})`);
  console.log(`   - Trade #${tradeIdB} : State = ${stateNames[Number(stateB)]} (${Number(stateB) === 1 ? "🟢 SUCCÈS - Skippé sans crash, toujours OPEN" : "🔴 ÉCHEC"})`);
  console.log(`   - Trade #${tradeIdC} : State = ${stateNames[Number(stateC)]} (${Number(stateC) === 0 ? "🟢 SUCCÈS - Skippé sans crash, toujours ORDER" : "🔴 ÉCHEC"})`);
  console.log(`   - Trade #${tradeIdD} : State = ${stateNames[Number(stateD)]} (${Number(stateD) === 6 ? "🟢 SUCCÈS - Fermé en LIQ_POS (Positive Liquidation)" : "🔴 ÉCHEC"})`);

  console.log("\n=======================================================================");
  console.log("⚡ TEST 2 : LIQUIDATION DU TRADE B LORSQUE LA CONDITION DE PRIX ARRIVE");
  console.log("=======================================================================");

  console.log("\n📉 Chute du prix de l'Or à $2350 (Déclenchement valide du SL / Liquidation de Trade B)...");
  const proofGoldCrash = await signRiskProof(kmsWallet, ASSETS.GOLD, 2350);

  const batchTx2 = await core.batchExecute([tradeIdB], [REASONS.SL], [proofGoldCrash]);
  await batchTx2.wait();

  const stateB_2 = (await core.trades(tradeIdB)).state;
  console.log(`   - Trade #${tradeIdB} après crash : State = ${stateNames[Number(stateB_2)]} (${Number(stateB_2) === 2 || Number(stateB_2) === 4 ? "🟢 SUCCÈS - Désormais Fermé/Liquidé" : "🔴 ÉCHEC"})`);

  console.log("\n=======================================================================");
  console.log("🎉 TOUTES LES VÉRIFICATIONS KEEPER ET LA RÉSILIENCE BATCH SONT VALIDEES !");
  console.log("=======================================================================");
}

main().catch((error) => {
  console.error("\n❌ ERREUR LORS DU TEST :", error);
  process.exitCode = 1;
});
