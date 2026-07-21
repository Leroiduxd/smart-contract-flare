const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";

  const [deployer] = await hre.ethers.getSigners();

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  // Approve Core just in case
  await (await usdt.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();

  // All 10 listed assets
  const assets = [5500, 5600, 5700, 5800, 5900, 6000, 6100, 6200, 6300, 6400];

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

  console.log("=== OPENING LONG & SHORT TRADES ON ALL 10 ASSETS ===");

  for (const assetId of assets) {
    for (const direction of [1, 0]) { // 1=LONG, 0=SHORT
      const dirStr = direction === 1 ? "LONG" : "SHORT";
      console.log(`Opening ${dirStr} on asset ID ${assetId}...`);
      
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
        const tx = await core.openMarketPosition(assetId, direction, 5n * 10n**6n, 10, 0, 0, proof, { gasLimit: 1000000 });
        await tx.wait();
        console.log(`  ✅ Position opened.`);
      } catch (err) {
        console.error(`  ❌ Failed to open position:`, err.message);
      }
    }
  }

  console.log("\n=== ALL POSITIONS LEFT OPEN ===");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
