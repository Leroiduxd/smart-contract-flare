const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x7D8a8Dd4191Da885eF04C3C5e6eEE8EDBBf52300";
  const USDT_ADDRESS = "0x1b8C72De8AEa4DA5DBF965d9b877Deee5B8B4e20";

  const [deployer] = await hre.ethers.getSigners();
  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS, deployer);
  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS, deployer);

  // Approve USDT for Core v2
  console.log("Approbation USDT pour Core v2...");
  await (await usdt.approve(CORE_ADDRESS, hre.ethers.MaxUint256)).wait();

  // Fetch proof from local TEE Enclave API
  console.log("Demande de preuve au service TEE Local...");
  const res = await fetch("http://localhost:8080/sign-proof", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      assetId: 5500,
      maxOILong: (500000n * 10n**6n).toString(),
      maxOIShort: (500000n * 10n**6n).toString(),
      spreadLong: 100,
      spreadShort: 100
    })
  });
  const data = await res.json();
  console.log("Preuve reçue de l'Enclave TEE :", data.proof);

  console.log("\nOuverture d'une position LONG sur l'OR (Asset 5500)...");
  const tx = await core.openMarketPosition(
    5500,
    1,
    5n * 10n**6n,
    10,
    0,
    0,
    data.proof,
    { gasLimit: 1000000 }
  );
  await tx.wait();
  console.log("🎉 POSITION OUVERTE AVEC SUCCÈS SUR LE CORE V2 AVEC SIGNATURE TEE !");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
