const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const block = await provider.getBlock(33007265);
  console.log("Block Transactions:", block.transactions);
  
  for (const txHash of block.transactions) {
    const tx = await provider.getTransaction(txHash);
    console.log(`Transaction ${txHash}:`);
    console.log(`  From: `, tx.from);
    console.log(`  To:   `, tx.to);
    console.log(`  Data: `, tx.data);
    console.log(`  Value:`, tx.value.toString());
    
    const receipt = await provider.getTransactionReceipt(txHash);
    console.log(`  Status:`, receipt.status);
    console.log(`  Gas Used:`, receipt.gasUsed.toString());
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
