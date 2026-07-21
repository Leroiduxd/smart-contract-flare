const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";
  const [deployer] = await hre.ethers.getSigners();
  const provider = hre.ethers.provider;

  const wallet2Key = "0x3ebe9cbf7ceca96b75082d555a4ded93a602599a66756780bfc8a914ea11ae0e";
  const wallet2 = new hre.ethers.Wallet(wallet2Key, provider);

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, wallet2);

  const assetId = 5600;
  const tradeId = 23;
  const timestamp = Math.floor(Date.now() / 1000);
  const maxOI = 500000n * 10n**6n;

  const abiCoder = hre.ethers.AbiCoder.defaultAbiCoder();
  const hash = hre.ethers.keccak256(
    abiCoder.encode(
      ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
      [assetId, maxOI, maxOI, 100, 100, timestamp]
    )
  );
  const sig = await deployer.signMessage(hre.ethers.getBytes(hash));

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
    const tx = await core.closePositionMarket(assetId, tradeId, proof);
    const receipt = await tx.wait();
    console.log("Transaction mined! Hash:", receipt.hash);
  } catch (err) {
    console.error("❌ Transaction failed!");
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
