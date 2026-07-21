const hre = require("hardhat");

async function main() {
  const errors = [
    "ZeroAddress()",
    "BadParameter()",
    "ProtocolPaused()",
    "NotPausedError()",
    "EmergencyOnly()",
    "NotTrader()",
    "BadDirection()",
    "BadOrderType()",
    "BadLeverage()",
    "BadMargin()",
    "BadPrice()",
    "BadSLTP()",
    "DelayNotPassed()",
    "InvalidState()",
    "OIExceeded()",
    "TraderOIExceeded()",
    "GlobalOIExceeded()",
    "InsufficientVaultCapital()",
    "StalePrice()",
    "PairNotInProof()",
    "InvalidKmsProof()",
    "KmsProofExpired()",
    "SpreadExceedsMaxAllowed()",
    "TransferFailed()",
    "InsufficientFreeLiquidityForWithdrawals()"
  ];

  console.log("=== DECODING ERROR SELECTOR 0xa6dd06f3 ===");
  for (const err of errors) {
    const sel = hre.ethers.id(err).slice(0, 10);
    console.log(`${sel} => ${err}`);
    if (sel.toLowerCase() === "0xa6dd06f3") {
      console.log(`\n🎯 MATCH FOUND: ${err}`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
