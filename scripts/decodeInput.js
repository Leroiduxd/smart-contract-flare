const { ethers } = require("ethers");

function main() {
  const CORE_ABI = [
    "function openMarketPosition(uint256 assetId, uint8 direction, uint256 collateral, uint256 leverage, uint256 slPrice, uint256 tpPrice, tuple(uint256 assetId, uint256 maxOILong, uint256 maxOIShort, uint256 spreadLong, uint256 spreadShort, uint256 timestamp, bytes sig) riskProof)"
  ];
  
  const iface = new ethers.Interface(CORE_ABI);
  
  // Let's piece together the tx data shown in the screenshot:
  // 15d364ee
  // 00000000000000000000000000000000000000000000000000000000000015e0 (5600)
  // ...
  // Let's decode a constructed hex payload to verify if we can match it.
  // Wait, let's write a script to query the pending trades or trades list instead!
}

main();
