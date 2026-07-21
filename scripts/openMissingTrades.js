const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const VAULT_ADDRESS = "0xF287c732eBc8d916eFD981AE4DC2eCDBD5EcbbD4";
  const USDT_ADDRESS = "0xB61bB22c75b3Cc14Ab4CbEE93C1076f54e90652D";

  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

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

  console.log("=== CHECKING FOR MISSING TRADES ===");
  const nextId = await core.nextTradeId();
  
  // Map of assetId => { hasLong: boolean, hasShort: boolean }
  const assetStatus = {};
  for (const id of assets) {
    assetStatus[id] = { hasLong: false, hasShort: false };
  }

  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    if (Number(t.state) === 1) { // ACTIVE
      const id = Number(t.assetId);
      if (assetStatus[id]) {
        if (t.direction === 1) assetStatus[id].hasLong = true;
        if (t.direction === 0) assetStatus[id].hasShort = true;
      }
    }
  }

  for (const assetId of assets) {
    const status = assetStatus[assetId];
    console.log(`Asset ${assetId}: LONG=${status.hasLong}, SHORT=${status.hasShort}`);

    for (const direction of [1, 0]) {
      const isMissing = (direction === 1 && !status.hasLong) || (direction === 0 && !status.hasShort);
      if (isMissing) {
        const dirStr = direction === 1 ? "LONG" : "SHORT";
        console.log(`  Opening missing ${dirStr} on asset ID ${assetId}...`);
        
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
          console.log(`    ✅ Position opened.`);
        } catch (err) {
          console.error(`    ❌ Failed to open position:`, err.message);
        }
      }
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
