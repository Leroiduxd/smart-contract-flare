const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";

  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  // Load private keys
  const wallet2Key = "0x3ebe9cbf7ceca96b75082d555a4ded93a602599a66756780bfc8a914ea11ae0e";
  const wallet3Key = "0xa63418e7e81a052df6a22a48c2e17c4ff805c7e2596222492d8caedde37106fc";

  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);

  const remaining = [
    { wallet: wallet2, assetId: 5600, tradeId: 23 },
    { wallet: wallet3, assetId: 5600, tradeId: 25 },
    { wallet: wallet3, assetId: 5600, tradeId: 28 },
    { wallet: wallet3, assetId: 5500, tradeId: 29 }
  ];

  console.log("=== CLOSING REMAINING TRADES ===");
  
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

  for (const t of remaining) {
    console.log(`Closing Trade #${t.tradeId} belonging to ${t.wallet.address}...`);
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
      
      const coreWithW = core.connect(t.wallet);
      const tx = await coreWithW.closePositionMarket(t.assetId, t.tradeId, proof);
      await tx.wait();
      console.log(`  ✅ Trade #${t.tradeId} closed successfully!`);
    } catch (err) {
      console.error(`  ❌ Failed to close Trade #${t.tradeId}:`, err);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
