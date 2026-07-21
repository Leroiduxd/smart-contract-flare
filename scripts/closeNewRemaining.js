const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  // Wallet 3 (owner of Trade #30 and #37)
  const wallet3Key = "0x26eb615475e66d7ba0cf7db12f45ae28ea6669351a5aa22839935af0d19b9b9b";
  const wallet3 = new hre.ethers.Wallet(wallet3Key, provider);

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, wallet3);

  async function signKMSProof(assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp) {
    const abiCoder = hre.ethers.AbiCoder.defaultAbiCoder();
    const hash = hre.ethers.keccak256(
      abiCoder.encode(
        ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
        [assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp]
      )
    );
    // Sign using deployer (which is Authorized KMS Signer)
    const sig = await deployer.signMessage(hre.ethers.getBytes(hash));
    return sig;
  }

  const remaining = [
    { assetId: 5500, tradeId: 30 },
    { assetId: 5600, tradeId: 37 }
  ];

  for (const t of remaining) {
    console.log(`Closing Trade #${t.tradeId} (Asset: ${t.assetId}) belonging to ${wallet3.address}...`);
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

      const tx = await core.closePositionMarket(t.assetId, t.tradeId, proof);
      await tx.wait();
      console.log(`  ✅ Closed successfully!`);
    } catch (err) {
      console.error(`  ❌ Failed to close Trade #${t.tradeId}:`, err.message);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
