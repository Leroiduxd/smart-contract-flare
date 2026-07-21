const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("====================================================");
  console.log(`Exécution avec le compte : ${deployer.address}`);
  console.log("====================================================\n");

  const CORE_ADDRESS = "0x310375937fB18E08f5700D9C1cc0F75E2d98bbA9";
  const VAULT_ADDRESS = "0xdD68Cb3Fe62a82a0E2dabC43BC58f9eCF8423d6E";
  const USDT_ADDRESS = "0xC1A5B41512496B80903D1f32d6dEa3a73212E71F";

  const core = await ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  const vault = await ethers.getContractAt("BrokexVault", VAULT_ADDRESS);
  
  const usdt = await ethers.getContractAt(
    [
      "function balanceOf(address account) external view returns (uint256)",
      "function approve(address spender, uint256 amount) external returns (bool)",
      "function allowance(address owner, address spender) external view returns (uint256)",
      "function mint(address to, uint256 amount) external returns (bool)"
    ],
    USDT_ADDRESS
  );

  console.log("1. Configuration des actifs...");

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
    maxTraderOI: 5000000000,               // 5k USDT
    maxGlobalOI: 200000000000,             // 200k USDT
    lockedCapitalBps: 50000,               // 5%
    liqThresholdBps: 950000,               // 95%
    listed: true,
    frozen: false
  };

  const btcConfig = {
    ...goldConfig,
    feedId: "0x014254432f55534400000000000000000000000000"
  };

  try {
    console.log("Enregistrement de l'actif OR (ID 5500) avec minTradeSize = 1 USDT...");
    const txGold = await core.listAsset(5500, goldConfig);
    await txGold.wait();
    console.log("✅ Actif OR configuré !");
  } catch (err) {
    console.log("L'actif OR est déjà listé ou erreur :", err.message);
  }

  try {
    console.log("Enregistrement de l'actif BTC (ID 5600) avec minTradeSize = 1 USDT...");
    const txBtc = await core.listAsset(5600, btcConfig);
    await txBtc.wait();
    console.log("✅ Actif BTC configuré !");
  } catch (err) {
    console.log("L'actif BTC est déjà listé ou erreur :", err.message);
  }

  console.log("\n2. Gestion du dépôt de 5 USDT...");

  const depositAmount = ethers.parseUnits("5", 6); // 5 USDT

  let balance = await usdt.balanceOf(deployer.address);
  console.log(`Votre solde USDT actuel : ${ethers.formatUnits(balance, 6)} USDT`);

  if (balance < depositAmount) {
    console.log("Solde insuffisant. Tentative de mint de 100 USDT de test...");
    try {
      const mintTx = await usdt.mint(deployer.address, ethers.parseUnits("100", 6));
      await mintTx.wait();
      balance = await usdt.balanceOf(deployer.address);
      console.log(`Nouveau solde USDT : ${ethers.formatUnits(balance, 6)} USDT`);
    } catch (mintErr) {
      console.error("❌ Impossible de minter du USDT :", mintErr.message);
      process.exit(1);
    }
  }

  console.log("Approbation du Vault pour dépenser 5 USDT...");
  const approveTx = await usdt.approve(VAULT_ADDRESS, depositAmount);
  await approveTx.wait();
  console.log("✅ Approbation effectuée.");

  console.log("Dépôt de 5 USDT dans BrokexVault...");
  const depositTx = await vault.deposit(depositAmount);
  await depositTx.wait();
  console.log("✅ Dépôt de 5 USDT effectué avec succès !");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
