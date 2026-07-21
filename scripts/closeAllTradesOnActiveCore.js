const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS, deployer);

  // Helper to sign KMS proof using the active TEE Enclave Signer key
  // Since TEE Enclave Signer Key is 0xFb8A8f2FDfEc07Ab74DE429aC041F70fC9B48c03
  // We fetch signature from local TEE service or generate matching signature
  async function getTEESignedProof(assetId, timestamp) {
    const res = await fetch("http://localhost:8080/sign-proof", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        assetId: assetId,
        maxOILong: (500000n * 10n**6n).toString(),
        maxOIShort: (500000n * 10n**6n).toString(),
        spreadLong: 100,
        spreadShort: 100
      })
    });
    const data = await res.json();
    return {
      assetId: assetId,
      maxOILong: 500000n * 10n**6n,
      maxOIShort: 500000n * 10n**6n,
      spreadLong: 100,
      spreadShort: 100,
      timestamp: timestamp,
      sig: data.proof.sig
    };
  }

  console.log("=== CLOSING ALL ACTIVE TRADES ON CORE ===");
  const nextId = await core.nextTradeId();
  console.log("Total trade entries:", Number(nextId) - 1);

  let closedCount = 0;
  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    if (Number(t.state) === 1) { // ACTIVE
      console.log(`Closing Active Trade #${t.id} (Asset: ${t.assetId}, Trader: ${t.trader})...`);
      try {
        const timestamp = Math.floor(Date.now() / 1000);
        const proof = await getTEESignedProof(Number(t.assetId), timestamp);
        
        // Connect as trader or deployer
        const tx = await core.closePositionMarket(t.assetId, t.id, proof, { gasLimit: 500000 });
        await tx.wait();
        console.log(`  ✅ Trade #${t.id} closed!`);
        closedCount++;
      } catch (err) {
        console.error(`  ❌ Could not close Trade #${t.id}:`, err.message);
      }
    }
  }

  console.log(`\n=== CLEANUP COMPLETE: Closed ${closedCount} active trades. ===`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
