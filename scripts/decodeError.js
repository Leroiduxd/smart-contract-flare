const fs = require("fs");
const path = require("path");

function main() {
  const coreArtifactPath = path.join(__dirname, "../artifacts/contracts/BrokexCore.sol/BrokexCore.json");
  if (!fs.existsSync(coreArtifactPath)) {
    console.error("Artifact not found at:", coreArtifactPath);
    return;
  }
  
  const artifact = JSON.parse(fs.readFileSync(coreArtifactPath, "utf8"));
  const errors = artifact.abi.filter(x => x.type === "error");
  
  console.log("=== BrokexCore Custom Errors ===");
  const { ethers } = require("ethers");
  for (const err of errors) {
    const signature = `${err.name}(${err.inputs.map(i => i.type).join(",")})`;
    const selector = ethers.id(signature).slice(0, 10);
    console.log(`${selector} -> ${signature}`);
  }
}

main();
