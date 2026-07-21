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

  console.log("=== 1. OPENING TRADES ===");
  const openTrades = [];
  const assetsToTest = [5500, 5600]; // Gold and BTC
  
  for (const assetId of assetsToTest) {
    for (const direction of [1, 0]) { // 1=LONG, 0=SHORT
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

      const tx = await core.openMarketPosition(assetId, direction, 10n * 10n**6n, 10, 0, 0, proof, { gasLimit: 1000000 });
      await tx.wait();
      
      const nextId = await core.nextTradeId();
      const tradeId = Number(nextId) - 1;
      openTrades.push({ assetId, tradeId });
      console.log(`  Position #${tradeId} (Asset: ${assetId}, Dir: ${direction === 1 ? "LONG" : "SHORT"}) opened.`);
    }
  }

  console.log("\n=== 2. LP PRICE WITH OPEN TRADES ===");
  const priceBefore = await vault.getLPPrice.staticCall();
  console.log("  LP Price before deposit:", (Number(priceBefore)/1e6).toFixed(6), "USD");

  console.log("\n=== 3. DEPOSITING USDT WHILE TRADES ARE OPEN ===");
  const depositAmt = 50n * 10n**6n;
  await (await usdt.approve(VAULT_ADDRESS, depositAmt)).wait();
  
  try {
    const tx = await vault.deposit(depositAmt, { gasLimit: 1000000 });
    await tx.wait();
    console.log("  ✅ Deposit successful while trades are open!");
  } catch (err) {
    console.error("  ❌ Deposit failed while trades are open:", err.message);
  }

  console.log("\n=== 4. LP PRICE AFTER DEPOSIT ===");
  const priceAfter = await vault.getLPPrice.staticCall();
  console.log("  LP Price after deposit:", (Number(priceAfter)/1e6).toFixed(6), "USD");

  console.log("\n=== 5. CLEANING UP: CLOSING TRADES ===");
  for (const t of openTrades) {
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
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
