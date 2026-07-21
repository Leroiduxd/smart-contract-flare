const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";

  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  const assetsToTest = [
    { id: 5700, name: "ETH", feedId: "0x014554482f55534400000000000000000000000000" },
    { id: 5800, name: "SOL", feedId: "0x01534f4c2f55534400000000000000000000000000" },
    { id: 5900, name: "XRP", feedId: "0x015852502f55534400000000000000000000000000" },
    { id: 6000, name: "DOGE", feedId: "0x01444f47452f555344000000000000000000000000" },
    { id: 6100, name: "LTC", feedId: "0x014c54432f55534400000000000000000000000000" },
    { id: 6200, name: "ADA", feedId: "0x014144412f55534400000000000000000000000000" },
    { id: 6300, name: "FLR", feedId: "0x01464c522f55534400000000000000000000000000" },
    { id: 6400, name: "MATIC", feedId: "0x014d415449432f5553440000000000000000000000" }
  ];

  console.log("=== 1. VERIFYING ORACLE FEEDS ON COSTON2 ===");
  const ftsoV2 = await hre.ethers.getContractAt("FtsoV2Interface", "0x7BDE3Df0624114eDB3A67dFe6753e62f4e7c1d20");
  
  for (const a of assetsToTest) {
    try {
      const feed = await ftsoV2.getFeedById(a.feedId);
      console.log(`  Feed ${a.name}/USD is active! Raw output:`, feed);
    } catch (err) {
      console.error(`  ❌ Feed ${a.name}/USD failed!`, err.message);
      return;
    }
  }

  console.log("\n=== 2. LISTING 8 NEW ASSETS ON CORE ===");
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

  for (const a of assetsToTest) {
    console.log(`Listing ${a.name} (ID: ${a.id})...`);
    try {
      const tx = await core.listAsset(a.id, { ...configTemplate, feedId: a.feedId });
      await tx.wait();
      console.log(`  ✅ ${a.name} listed.`);
    } catch (err) {
      if (err.message.includes("BadParameter") || err.message.includes("reverted")) {
        console.log(`  ℹ️ ${a.name} was already listed.`);
      } else {
        throw err;
      }
    }
  }

  // 3. Deposit USDT to Vault to provide liquidity (e.g. 100 USDT)
  console.log("\n=== 3. DEPOSITING USDT TO VAULT ===");
  const depositAmt = 100n * 10n**6n;
  await (await usdt.approve(VAULT_ADDRESS, depositAmt)).wait();
  await (await vault.deposit(depositAmt, { gasLimit: 1000000 })).wait();
  console.log("  ✅ Deposited 100 USDT.");

  // Helper to sign FTSO KMS proof
  async function signKMSProof(assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp) {
    const abiCoder = hre.ethers.AbiCoder.defaultAbiCoder();
    const hash = hre.ethers.keccak256(
      abiCoder.encode(
        ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
        [assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp]
      )
    );
    const sig = await deployer.signMessage(hre.ethers.getBytes(hash));
    return sig;
  }

  const openTrades = [];

  console.log("\n=== 4. OPENING LONG & SHORT TRADES FOR EACH ASSET ===");
  for (const a of assetsToTest) {
    for (const direction of [1, 0]) { // 1=LONG, 0=SHORT
      const dirStr = direction === 1 ? "LONG" : "SHORT";
      console.log(`Opening ${dirStr} on ${a.name}...`);
      
      const timestamp = Math.floor(Date.now() / 1000);
      const maxOI = 500000n * 10n**6n;
      const sig = await signKMSProof(a.id, maxOI, maxOI, 100, 100, timestamp);
      const proof = {
        assetId: a.id,
        maxOILong: maxOI,
        maxOIShort: maxOI,
        spreadLong: 100,
        spreadShort: 100,
        timestamp,
        sig
      };

      const tx = await core.openMarketPosition(a.id, direction, 2n * 10n**6n, 10, 0, 0, proof, { gasLimit: 1000000 });
      await tx.wait();
      
      const nextId = await core.nextTradeId();
      const tradeId = Number(nextId) - 1;
      openTrades.push({ assetId: a.id, tradeId });
      console.log(`  ✅ Position #${tradeId} opened.`);
    }
  }

  console.log("\n=== 5. CHECKING LP PRICE WITH OPEN TRADES ===");
  const lpPrice = await vault.getLPPrice.staticCall();
  console.log("  ✅ LP Price fetched successfully! Price:", (Number(lpPrice)/1e6).toFixed(6), "USD");

  console.log("\n=== 6. CLEANING UP: CLOSING ALL TRADES ===");
  for (const t of openTrades) {
    console.log(`Closing Position #${t.tradeId} (Asset: ${t.assetId})...`);
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
    await (await core.closePositionMarket(t.assetId, t.tradeId, proof, { gasLimit: 1000000 })).wait();
    console.log(`  ✅ Position #${t.tradeId} closed.`);
  }

  console.log("\n=== 7. FINAL STATE VERIFICATION ===");
  const finalPrice = await vault.getLPPrice.staticCall();
  console.log("  ✅ Final LP Price:", (Number(finalPrice)/1e6).toFixed(6), "USD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
