const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const w2 = "0x3764916675D9A52D719976AF5958D984ea41A5f2";
  const w3 = "0x6505604a48f66D4b58ceC0522b9579829c19083d";

  console.log("Wallet 2 FLR Balance:", hre.ethers.formatEther(await provider.getBalance(w2)));
  console.log("Wallet 3 FLR Balance:", hre.ethers.formatEther(await provider.getBalance(w3)));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
