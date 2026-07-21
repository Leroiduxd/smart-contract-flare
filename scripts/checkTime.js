const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const block = await provider.getBlock("latest");
  const localTime = Math.floor(Date.now() / 1000);

  console.log("Latest block timestamp on Coston2:", block.timestamp);
  console.log("Local system time:                ", localTime);
  console.log("Difference (Local - Block):        ", localTime - block.timestamp, "seconds");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
