const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";

  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

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

  const assetId = 6400; // MATIC

  console.log("=== OPENING MISSING MATIC TRADES ===");
  for (const direction of [1, 0]) {
    const dirStr = direction === 1 ? "LONG" : "SHORT";
    console.log(`Opening ${dirStr} on MATIC (ID 6400)...`);
    
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

    try {
      const tx = await core.openMarketPosition(assetId, direction, 5n * 10n**6n, 10, 0, 0, proof, { gasLimit: 500000 });
      await tx.wait();
      console.log(`  ✅ ${dirStr} opened.`);
    } catch (err) {
      console.error(`  ❌ Failed:`, err.message);
    }
  }

  const price = await vault.getLPPrice.staticCall();
  console.log("\n=== FINAL LP PRICE ===");
  console.log("LP Price:", (Number(price)/1e6).toFixed(6), "USD");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
