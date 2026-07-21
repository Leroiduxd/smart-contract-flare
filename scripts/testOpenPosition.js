const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x3125392eCF85354eDCA8E02649d84EC3E9710dA4";
  const USDT_ADDRESS = "0xA5F683378B693e0311fC4B5d8DF6050F32577d80";
  const [deployer] = await hre.ethers.getSigners();

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, deployer);

  const assetId = 5500;
  const direction = 1;
  const collateralRaw = 10n * 10n**6n;
  const leverage = 10;

  const timestamp = Math.floor(Date.now() / 1000);
  const maxOI = 500000n * 10n**6n;
  
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);
  console.log("Approving USDT to Core...");
  await (await usdt.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();

  // Sign locally
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

  console.log("Simulating openMarketPosition...");
  try {
    const tx = await core.openMarketPosition.staticCall(assetId, direction, collateralRaw, leverage, 0, 0, proof);
    console.log("Success! Expected Trade ID:", tx.toString());
  } catch (err) {
    console.error("❌ Simulation failed!");
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
