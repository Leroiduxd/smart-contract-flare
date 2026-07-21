const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  
  // We can query ContractRegistry to get FtsoV2 address
  // Let's get registry address from Core
  const registryAddr = "0xa387241df4df0512fbd0b4b2404c34b399dfa7d1"; // Wait, registry is a constant or state?
  // Let's look at BrokexCore to see how it gets FtsoV2
  const ftsoV2Address = "0x3d8f934b2404c34b399dfa7d15da1c550d341838"; // or similar, let's call getPriceExternal
  
  // Let's just query getPriceExternal and see what it returns, and let's check FTSO directly
  // We can get FTSO address using ContractRegistry
  const registry = await hre.ethers.getContractAt(
    [
      "function getFtsoV2() external view returns (address)"
    ],
    "0xa387241df4df0512fbd0b4b2404c34b399dfa7d1" // Let's check registry address from coston2
  );
  
  try {
    const ftsoAddr = await registry.getFtsoV2();
    console.log("FTSO V2 Address:", ftsoAddr);
    
    const ftso = await hre.ethers.getContractAt(
      [
        "function getFeedById(bytes21 _feedId) external view returns (uint256 _value, int8 _decimals, uint64 _timestamp)"
      ],
      ftsoAddr
    );
    
    const feedId = "0x01504158472f555344000000000000000000000000"; // PAXG/USD
    const [value, decimals, timestamp] = await ftso.getFeedById(feedId);
    console.log("PAXG/USD FTSO RAW:");
    console.log("  Value:    ", value.toString());
    console.log("  Decimals: ", decimals.toString());
    console.log("  Timestamp:", timestamp.toString());
  } catch (err) {
    console.log("Error querying registry/FTSO directly:", err.message);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
