const { ethers } = require("ethers");

// Configuration
const MAINNET_RPC = "https://flare-api.flare.network/ext/C/rpc";
const COSTON2_RPC = "https://coston2-api.flare.network/ext/C/rpc";

const REGISTRY_ADDRESS = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019";

const REGISTRY_ABI = [
  "function getContractAddressByName(string calldata _name) external view returns (address)"
];

const FTSO_ABI = [
  "function getFeedById(bytes21 _feedId) external view returns (uint256 _value, int8 _decimals, uint64 _timestamp)"
];

// Helper pour calculer les feed IDs dynamiquement
function getFeedId(category, feedName) {
  const hexFeedName = Buffer.from(feedName, "utf8").toString("hex");
  const padded = (category + hexFeedName).padEnd(42, "0");
  return "0x" + padded;
}

const FEEDS = [
  { name: "PAXG/USD", id: getFeedId("01", "PAXG/USD") },
  { name: "BTC/USD",  id: getFeedId("01", "BTC/USD") }
];

async function main() {
  console.log("Initialisation des connexions RPC...");
  const mainnetProvider = new ethers.JsonRpcProvider(MAINNET_RPC);
  const coston2Provider = new ethers.JsonRpcProvider(COSTON2_RPC);

  console.log("Résolution des adresses du contrat FtsoV2 via le Registry...");
  const mainnetRegistry = new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, mainnetProvider);
  const coston2Registry = new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, coston2Provider);

  let mainnetFtsoAddress, coston2FtsoAddress;
  try {
    mainnetFtsoAddress = await mainnetRegistry.getContractAddressByName("FtsoV2");
    console.log(`Mainnet FtsoV2 : ${mainnetFtsoAddress}`);
  } catch (err) {
    console.error("Erreur lors de la résolution de FtsoV2 sur Mainnet :", err.message);
    process.exit(1);
  }

  try {
    coston2FtsoAddress = await coston2Registry.getContractAddressByName("FtsoV2");
    console.log(`Coston2 FtsoV2 : ${coston2FtsoAddress}`);
  } catch (err) {
    console.error("Erreur lors de la résolution de FtsoV2 sur Coston2 :", err.message);
    process.exit(1);
  }

  const mainnetFtso = new ethers.Contract(mainnetFtsoAddress, FTSO_ABI, mainnetProvider);
  const coston2Ftso = new ethers.Contract(coston2FtsoAddress, FTSO_ABI, coston2Provider);

  const targets = [
    { network: "Mainnet", ftso: mainnetFtso, feed: FEEDS[0] }, // PAXG/USD
    { network: "Mainnet", ftso: mainnetFtso, feed: FEEDS[1] }, // BTC/USD
    { network: "Coston2", ftso: coston2Ftso, feed: FEEDS[0] }, // PAXG/USD
    { network: "Coston2", ftso: coston2Ftso, feed: FEEDS[1] }  // BTC/USD
  ];

  // Initialisation du statut de tracking
  const state = targets.map(t => ({
    ...t,
    lastTimestamp: 0n,
    updateCount: 0
  }));

  console.log("\nDébut du polling toutes les 2 secondes (durée : 2 minutes)...");
  console.log("--------------------------------------------------------------------------------");

  let ticks = 0;
  const maxTicks = 60; // 60 ticks * 2s = 120s

  const interval = setInterval(async () => {
    ticks++;
    if (ticks > maxTicks) {
      clearInterval(interval);
      printSummary(state);
      return;
    }

    await Promise.all(state.map(async (item) => {
      try {
        const [value, decimals, timestamp] = await item.ftso.getFeedById(item.feed.id);
        const price = Number(value) / (10 ** Number(decimals));
        
        let changeSymbol = "=";
        if (item.lastTimestamp !== 0n) {
          if (timestamp > item.lastTimestamp) {
            changeSymbol = "▲";
            item.updateCount++;
          } else if (timestamp < item.lastTimestamp) {
            changeSymbol = "▼";
            item.updateCount++;
          }
        }
        item.lastTimestamp = timestamp;

        const timeString = new Date(Number(timestamp) * 1000).toLocaleTimeString("fr-FR");
        console.log(
          `[${item.network}] ${item.feed.name.padEnd(8)} | Prix: ${price.toFixed(4).padStart(12)} | TS: ${timeString} | Status: [${changeSymbol}]`
        );
      } catch (err) {
        console.log(`[${item.network}] ${item.feed.name.padEnd(8)} | ERREUR: ${err.message.slice(0, 60)}`);
      }
    }));
  }, 2000);
}

function printSummary(state) {
  console.log("\n================================================================================");
  console.log("RÉSUMÉ FINAL DE LA VÉRIFICATION DES FEEDS (120 secondes)");
  console.log("================================================================================");
  state.forEach(item => {
    console.log(
      `- ${item.network} ${item.feed.name.padEnd(8)} : ${item.updateCount} updates détectées en 120s`
    );
  });
  console.log("================================================================================");
  process.exit(0);
}

main().catch(console.error);
