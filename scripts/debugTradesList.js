const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2D2b93F52b4ae317FA11Ea36A21af23dC6Ff3eA8";
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  const nextId = await core.nextTradeId();
  console.log("nextTradeId:", nextId.toString());

  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    console.log(`Trade #${i}: Asset=${t.assetId.toString()}, Dir=${t.direction.toString()}, State=${t.state.toString()}, Trader=${t.trader}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
