const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x96c719b0CAe583f768F7B8D41C59fF85401BF389";
  const [deployer] = await hre.ethers.getSigners();
  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS, deployer);

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

  console.log("Mise à jour du feedId pour l'OR (PAXG/USD: 0x01504158472f555344000000000000000000000000)...");
  const tx = await core.updateAsset(5500, {
    ...configTemplate,
    feedId: "0x01504158472f555344000000000000000000000000"
  });
  await tx.wait();
  console.log("  ✅ Feed ID de l'OR mis à jour avec succès !");

  console.log("Mise à jour du feedId pour le BTC (BTC/USD: 0x014254432f55534400000000000000000000000000)...");
  const tx2 = await core.updateAsset(5600, {
    ...configTemplate,
    feedId: "0x014254432f55534400000000000000000000000000"
  });
  await tx2.wait();
  console.log("  ✅ Feed ID du BTC mis à jour avec succès !");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
