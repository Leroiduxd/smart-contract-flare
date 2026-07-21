const hre = require("hardhat");

async function main() {
  const CORE_ADDRESS = "0x715E1E98C6bC5b38d2700446Fbf897f5276dcffa";
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";

  const [deployer] = await hre.ethers.getSigners();

  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  const lockedCap = await core.totalLockedCapital();
  console.log("Core Total Locked Capital:", lockedCap.toString());

  console.log("Simulating vault.processQueue()...");
  try {
    const tx = await vault.processQueue({ gasLimit: 1000000 });
    await tx.wait();
    console.log("Success! processQueue transaction executed successfully.");
  } catch (err) {
    console.error("❌ processQueue transaction failed:");
    console.error(err);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
