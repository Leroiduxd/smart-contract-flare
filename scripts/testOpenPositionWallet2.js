const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x3125392eCF85354eDCA8E02649d84EC3E9710dA4";
  const USDT_ADDRESS = "0xA5F683378B693e0311fC4B5d8DF6050F32577d80";
  
  const [deployer] = await hre.ethers.getSigners();
  
  // Create wallet2 from private key or random
  const wallet2 = hre.ethers.Wallet.createRandom().connect(hre.ethers.provider);
  
  // Fund wallet2
  console.log("Funding wallet2...");
  await (await deployer.sendTransaction({ to: wallet2.address, value: hre.ethers.parseEther("0.1") })).wait();
  
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);
  await (await usdt.transfer(wallet2.address, 100n * 10n**6n)).wait();
  
  const usdt2 = usdt.connect(wallet2);
  await (await usdt2.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS, wallet2);

  const assetId = 5500;
  const direction = 1;
  const collateralRaw = 10n * 10n**6n;
  const leverage = 10;

  const timestamp = Math.floor(Date.now() / 1000);
  const maxOI = 500000n * 10n**6n;
  
  // Sign locally using deployer (which is KMS signer)
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

  console.log("Simulating openMarketPosition from wallet2...");
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
