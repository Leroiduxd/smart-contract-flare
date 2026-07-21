const hre = require("hardhat");

async function main() {
  const contractAddress = "0x26524D23f70FBb17c8D5d5C3353a9693565b9BE0";
  console.log(`Lecture du prix de l'or sur le contrat : ${contractAddress}`);

  const BrokexOracleFTSO = await hre.ethers.getContractFactory("BrokexOracleFTSO");
  const contract = BrokexOracleFTSO.attach(contractAddress);

  try {
    const goldPrice = await contract.getGoldPrice.staticCall();
    console.log(`Prix de l'or retourné (10^6) : ${goldPrice.toString()}`);
    console.log(`Prix de l'or en USD : $${(Number(goldPrice) / 1000000).toFixed(2)}`);
  } catch (error) {
    console.error("Erreur lors de la lecture du prix :", error);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
