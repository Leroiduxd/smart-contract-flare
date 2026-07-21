const hre = require("hardhat");
require("dotenv").config();

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";

  // 2. Initialize wallets
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  console.log("=================================================");
  console.log("      INITIALISATION DU SCRIPT DE SIMULATION      ");
  console.log("=================================================");
  console.log("Wallet Principal (KMS Signer) :", deployer.address);

  // Generate 2 additional wallets
  const wallet2 = hre.ethers.Wallet.createRandom().connect(provider);
  const wallet3 = hre.ethers.Wallet.createRandom().connect(provider);
  console.log("Wallet 2 Address:", wallet2.address);
  console.log("Wallet 2 Private Key:", wallet2.privateKey);
  console.log("Wallet 3 Address:", wallet3.address);
  console.log("Wallet 3 Private Key:", wallet3.privateKey);

  // Save keys to a temp JSON file
  const fs = require("fs");
  fs.writeFileSync(
    "./scripts/tempWallets.json",
    JSON.stringify({
      wallet2: { address: wallet2.address, privateKey: wallet2.privateKey },
      wallet3: { address: wallet3.address, privateKey: wallet3.privateKey }
    }, null, 2)
  );

  // Fund Wallet 2 and Wallet 3 with Native FLR for gas (15.0 FLR each)
  console.log("\nEnvoi de 15.0 FLR pour le gas aux deux portefeuilles...");
  let tx = await deployer.sendTransaction({
    to: wallet2.address,
    value: hre.ethers.parseEther("15.0")
  });
  await tx.wait();
  tx = await deployer.sendTransaction({
    to: wallet3.address,
    value: hre.ethers.parseEther("15.0")
  });
  await tx.wait();
  console.log("FLR transféré avec succès !");

  // Transfer 1,000 USDT to Wallet 2 and Wallet 3 from Deployer balance
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);

  console.log("\nDistribution de 1,000 USDT aux deux portefeuilles...");
  const fundAmount = 1000n * 10n**6n; // 1,000 USDT
  tx = await usdt.transfer(wallet2.address, fundAmount);
  await tx.wait();
  tx = await usdt.transfer(wallet3.address, fundAmount);
  await tx.wait();
  console.log("USDT distribué avec succès !");

  // Approve Vault and Core for Wallet 2 & Wallet 3 & Deployer
  console.log("\nConfiguration des approbations USDT (Max)...");
  await (await usdt.approve(VAULT_ADDRESS, hre.ethers.MaxUint256)).wait();
  await (await usdt.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();
  const usdt2 = usdt.connect(wallet2);
  const usdt3 = usdt.connect(wallet3);
  await (await usdt2.approve(VAULT_ADDRESS, hre.ethers.MaxUint256)).wait();
  await (await usdt2.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();
  await (await usdt3.approve(VAULT_ADDRESS, hre.ethers.MaxUint256)).wait();
  await (await usdt3.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();
  console.log("Approbations configurées avec succès !");

  const wallets = [deployer, wallet2, wallet3];
  let activeTrades = []; // List of { wallet, assetId, tradeId }

  // Helper function to sign FTSO KMS proof
  async function signKMSProof(assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp) {
    const abiCoder = hre.ethers.AbiCoder.defaultAbiCoder();
    const hash = hre.ethers.keccak256(
      abiCoder.encode(
        ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
        [assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp]
      )
    );
    // Deployer is the authorized priceSigner in Core
    const sig = await deployer.signMessage(hre.ethers.getBytes(hash));
    return sig;
  }

  // Helper to cleanup everything at the end
  async function cleanup() {
    console.log("\n=================================================");
    console.log("         NETTOYAGE & RÉCUPÉRATION DES FONDS      ");
    console.log("=================================================");
    
    // 1. Close all active trades
    if (activeTrades.length > 0) {
      console.log(`Fermeture de ${activeTrades.length} positions ouvertes...`);
      for (const t of activeTrades) {
        try {
          const timestamp = Math.floor(Date.now() / 1000);
          const sig = await signKMSProof(t.assetId, 500000n * 10n**6n, 500000n * 10n**6n, 100, 100, timestamp);
          const proof = {
            assetId: t.assetId,
            maxOILong: 500000n * 10n**6n,
            maxOIShort: 500000n * 10n**6n,
            spreadLong: 100,
            spreadShort: 100,
            timestamp: timestamp,
            sig: sig
          };
          const coreWithWallet = core.connect(t.wallet);
          const closeTx = await coreWithWallet.closePositionMarket(t.assetId, t.tradeId, proof);
          await closeTx.wait();
          console.log(`  Position #${t.tradeId} fermée.`);
        } catch (err) {
          console.error(`  ❌ Échec fermeture position #${t.tradeId}:`, err.message);
        }
      }
      activeTrades = [];
    }

    // 1.5 Request withdrawal of all LP tokens for wallet2 and wallet3
    for (const w of [wallet2, wallet3]) {
      try {
        const vaultW = vault.connect(w);
        const lpBal = await vaultW.balanceOf(w.address);
        if (lpBal > 0n) {
          console.log(`Demande de retrait de ${Number(lpBal)/1e18} LP pour ${w.address}...`);
          await (await vaultW.requestWithdraw(lpBal)).wait();
        }
      } catch (err) {
        console.error(`  ❌ Échec demande retrait LP pour ${w.address}:`, err.message);
      }
    }

    // 2. Settle all pending withdrawals in the queue
    try {
      console.log("Traitement de la file d'attente de retraits...");
      const processTx = await vault.processQueue({ gasLimit: 1000000 });
      await processTx.wait();
    } catch (e) {}

    // 3. Recover USDT from wallet2 & wallet3 to deployer
    for (const w of [wallet2, wallet3]) {
      try {
        const usdtW = usdt.connect(w);
        const bal = await usdtW.balanceOf(w.address);
        if (bal > 0n) {
          console.log(`Récupération de ${Number(bal)/1e6} USDT de ${w.address}...`);
          await (await usdtW.transfer(deployer.address, bal)).wait();
        }
        
        const flrBal = await provider.getBalance(w.address);
        if (flrBal > hre.ethers.parseEther("0.05")) {
          const sendBal = flrBal - hre.ethers.parseEther("0.02"); // Leave some gas to avoid underfunded error
          console.log(`Récupération de ${hre.ethers.formatEther(sendBal)} FLR de ${w.address}...`);
          await (await w.sendTransaction({
            to: deployer.address,
            value: sendBal
          })).wait();
        }
      } catch (err) {
        console.error(`  ❌ Échec de la récupération pour ${w.address}:`, err.message);
      }
    }
    console.log("Nettoyage terminé !");
  }

  // Handle sudden stop (Ctrl+C)
  process.on("SIGINT", async () => {
    console.log("\nSimulation interrompue par l'utilisateur !");
    await cleanup();
    process.exit(0);
  });

  // Run simulation
  const numSteps = 120;
  console.log(`\nDémarrage de la simulation (${numSteps} étapes)...`);

  for (let step = 1; step <= numSteps; step++) {
    const rand = Math.random();
    const w = wallets[Math.floor(Math.random() * wallets.length)];
    
    console.log(`\n--- Étape ${step}/${numSteps} ---`);

    try {
      if (rand < 0.45) {
        // ACTION 1: OPEN POSITION
        const assetId = Math.random() < 0.5 ? 5500 : 5600;
        const direction = Math.random() < 0.5 ? 0 : 1; // 0=SHORT, 1=LONG
        const marginUSDT = Math.floor(Math.random() * 15) + 3; // 3 to 17 USDT
        const leverage = Math.floor(Math.random() * 20) + 5; // 5x to 24x
        const collateralRaw = BigInt(marginUSDT) * 10n**6n;

        console.log(`Ouverture Position par ${w.address}: Asset=${assetId}, Dir=${direction === 1 ? "LONG" : "SHORT"}, Marge=${marginUSDT} USDT, Levier=${leverage}x`);

        const timestamp = Math.floor(Date.now() / 1000);
        const maxOI = 500000n * 10n**6n;
        const sig = await signKMSProof(assetId, maxOI, maxOI, 100, 100, timestamp);
        const proof = {
          assetId,
          maxOILong: maxOI,
          maxOIShort: maxOI,
          spreadLong: 100,
          spreadShort: 100,
          timestamp,
          sig
        };

        const coreW = core.connect(w);
        const openTx = await coreW.openMarketPosition(assetId, direction, collateralRaw, leverage, 0, 0, proof);
        const receipt = await openTx.wait();

        // Retrieve trade ID from events
        const nextId = await core.nextTradeId();
        const tradeId = Number(nextId) - 1;
        activeTrades.push({ wallet: w, assetId, tradeId });
        console.log(`  ✅ Position #${tradeId} ouverte avec succès !`);

      } else if (rand < 0.75) {
        // ACTION 2: CLOSE POSITION
        if (activeTrades.length > 0) {
          const index = Math.floor(Math.random() * activeTrades.length);
          const t = activeTrades[index];
          console.log(`Fermeture Position #${t.tradeId} par ${t.wallet.address}...`);

          const timestamp = Math.floor(Date.now() / 1000);
          const maxOI = 500000n * 10n**6n;
          const sig = await signKMSProof(t.assetId, maxOI, maxOI, 100, 100, timestamp);
          const proof = {
            assetId: t.assetId,
            maxOILong: maxOI,
            maxOIShort: maxOI,
            spreadLong: 100,
            spreadShort: 100,
            timestamp,
            sig
          };

          const coreW = core.connect(t.wallet);
          const closeTx = await coreW.closePositionMarket(t.assetId, t.tradeId, proof);
          await closeTx.wait();
          
          activeTrades.splice(index, 1);
          console.log(`  ✅ Position #${t.tradeId} fermée avec succès !`);
        } else {
          console.log("Pas de position active à fermer. Skip.");
        }

      } else if (rand < 0.85) {
        // ACTION 3: DEPOSIT USDT
        const depositAmt = BigInt(Math.floor(Math.random() * 40) + 10) * 10n**6n; // 10 to 49 USDT
        console.log(`Dépôt de ${Number(depositAmt)/1e6} USDT dans le Vault par ${w.address}...`);
        
        const vaultW = vault.connect(w);
        const depTx = await vaultW.deposit(depositAmt);
        await depTx.wait();
        console.log("  ✅ Dépôt réussi !");

      } else if (rand < 0.93) {
        // ACTION 4: REQUEST WITHDRAW LP
        const vaultW = vault.connect(w);
        const lpBal = await vaultW.balanceOf(w.address);
        if (lpBal > 10n**18n) { // At least 1 LP
          const withdrawLP = lpBal / 4n; // Request withdraw 25% of their LPs
          console.log(`Demande de retrait de ${Number(withdrawLP)/1e18} LP par ${w.address}...`);
          
          const wdTx = await vaultW.requestWithdraw(withdrawLP);
          await wdTx.wait();
          console.log("  ✅ Demande de retrait enregistrée.");
        } else {
          console.log(`Solde LP insuffisant pour retrait pour ${w.address}. Skip.`);
        }

      } else {
        // ACTION 5: PROCESS QUEUE
        console.log("Exécution du Keeper pour traiter la file d'attente de retraits...");
        try {
          const processTx = await vault.connect(w).processQueue();
          await processTx.wait();
          console.log("  ✅ File d'attente traitée par le Keeper !");
        } catch (e) {
          console.log("  ℹ️ Aucun retrait à traiter dans la file ou liquidité libre insuffisante.");
        }
      }
    } catch (err) {
      console.error("  ❌ Étape échouée :", err.message);
    }

    // Small delay between transactions to let states update
    await new Promise(r => setTimeout(r, 1000));
  }

  // Done simulation, cleanup
  await cleanup();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
