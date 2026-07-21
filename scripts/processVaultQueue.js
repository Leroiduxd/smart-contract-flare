const hre = require("hardhat");

async function main() {
  const VAULT_ADDRESS = "0x5752B4790c2F2fAF27680253D51c45de576ec040";
  const [deployer] = await hre.ethers.getSigners();

  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS, deployer);

  console.log("Processing withdrawal queue...");
  try {
    const tx = await vault.processQueue();
    await tx.wait();
    console.log("Queue processed successfully!");
  } catch (err) {
    console.log("Vault processQueue call status:", err.message);
  }

  const price = await vault.getLPPrice.staticCall();
  const totalSupply = await vault.totalSupply();
  
  console.log("=== LP STATE ===");
  console.log("LP Total Supply:", totalSupply.toString(), `(${Number(totalSupply)/1e18} LP)`);
  console.log("LP Price:       ", price.toString(), `(${Number(price)/1e6} USD)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
