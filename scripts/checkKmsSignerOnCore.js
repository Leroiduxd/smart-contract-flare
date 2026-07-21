const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x7D8a8Dd4191Da885eF04C3C5e6eEE8EDBBf52300";
  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS);

  const signer = await core.kmsSigner();
  console.log("=== CORE V2 DETAILS ===");
  console.log("Core Address    :", CORE_ADDRESS);
  console.log("kmsSigner on-chain:", signer);

  const gold = await core.assets(5500);
  console.log("Gold listed:    ", gold.listed);

  const btc = await core.assets(5600);
  console.log("BTC listed:     ", btc.listed);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
