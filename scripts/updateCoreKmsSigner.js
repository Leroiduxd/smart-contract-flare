const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x7D8a8Dd4191Da885eF04C3C5e6eEE8EDBBf52300";
  const [deployer] = await hre.ethers.getSigners();

  const core = await hre.ethers.getContractAt("contracts/v2/BrokexCore.sol:BrokexCore", CORE_ADDRESS, deployer);

  // TEE Enclave Signer Key Address generated inside local TEE enclave memory
  const teeSignerAddress = "0xf8429f008bA010d7e75eF38176A3e35d11e0F835";

  console.log("=== LINKING TEE ENCLAVE SIGNER TO BROKEX CORE ===");
  console.log("Core Address     :", CORE_ADDRESS);
  console.log("TEE Enclave Key  :", teeSignerAddress);

  const currentSigner = await core.kmsSigner();
  console.log("Current Signer   :", currentSigner);

  if (currentSigner.toLowerCase() !== teeSignerAddress.toLowerCase()) {
    console.log("Updating KMS Signer to TEE Enclave Key...");
    const tx = await core.setKmsSigner(teeSignerAddress);
    await tx.wait();
    console.log("  ✅ KMS Signer updated successfully to TEE Enclave Key!");
  } else {
    console.log("  ℹ️ TEE Enclave Key is already set as the KMS Signer!");
  }

  const updatedSigner = await core.kmsSigner();
  console.log("Active KMS Signer:", updatedSigner);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
