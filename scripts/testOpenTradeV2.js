const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x2076A1e10A57ccDE1A85368e27E93CB5ce8F506B";
  const USDT_ADDRESS = "0x746b5Ce3db819414EC1D60d05C13B32e37847e66";

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
  console.log("Full Tx Hash:", tx.hash);
  await tx.wait();
  console.log("🎉 POSITION OUVERTE AVEC SUCCÈS SUR LE CORE V2 AVEC SIGNATURE TEE !");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
