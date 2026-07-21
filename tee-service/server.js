const express = require("express");
const { ethers } = require("ethers");
require("dotenv").config();

const app = express();
app.use(express.json());

// Enable CORS for browser frontend access
app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
  res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  if (req.method === "OPTIONS") return res.sendStatus(200);
  next();
});

const PORT = process.env.PORT || 8080;

// Enclave Private Key (Load from env or generate key for enclave memory)
const KMS_PRIVATE_KEY = process.env.KMS_PRIVATE_KEY || process.env.PRIVATE_KEY;
if (!KMS_PRIVATE_KEY) {
  console.error("⚠️ WARNING: No KMS_PRIVATE_KEY set in .env! Generating a random enclave signer key...");
}

const wallet = KMS_PRIVATE_KEY 
  ? new ethers.Wallet(KMS_PRIVATE_KEY) 
  : ethers.Wallet.createRandom();

console.log("=================================================");
console.log("     BROKEX LOCAL TEE KMS SIGNER SERVICE        ");
console.log("=================================================");
console.log(`🔒 Enclave KMS Signer Address: ${wallet.address}`);
console.log("=================================================");

/**
 * GET /health
 */
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    teeSigner: wallet.address,
    timestamp: Math.floor(Date.now() / 1000)
  });
});

/**
 * GET /signer-address
 */
app.get("/signer-address", (req, res) => {
  res.json({
    kmsSigner: wallet.address
  });
});

/**
 * POST /sign-proof
 * Body: { assetId, maxOILong?, maxOIShort?, spreadLong?, spreadShort? }
 */
app.post("/sign-proof", async (req, res) => {
  try {
    const { assetId, maxOILong, maxOIShort, spreadLong, spreadShort } = req.body;

    if (!assetId) {
      return res.status(400).json({ error: "Missing required parameter: assetId" });
    }

    // Default parameters if not passed explicitly
    const parsedAssetId = BigInt(assetId);
    const parsedMaxOILong = maxOILong ? BigInt(maxOILong) : 500000n * 10n**6n; // 500,000 USDT
    const parsedMaxOIShort = maxOIShort ? BigInt(maxOIShort) : 500000n * 10n**6n; // 500,000 USDT
    const parsedSpreadLong = spreadLong ? BigInt(spreadLong) : 100n; // 1.00 bps
    const parsedSpreadShort = spreadShort ? BigInt(spreadShort) : 100n; // 1.00 bps
    const timestamp = BigInt(Math.floor(Date.now() / 1000));

    // Encode parameters matching BrokexCore hashing
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const hash = ethers.keccak256(
      abiCoder.encode(
        ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
        [parsedAssetId, parsedMaxOILong, parsedMaxOIShort, parsedSpreadLong, parsedSpreadShort, timestamp]
      )
    );

    // Sign hash using TEE Enclave Private Key
    const sig = await wallet.signMessage(ethers.getBytes(hash));

    const proof = {
      assetId: parsedAssetId.toString(),
      maxOILong: parsedMaxOILong.toString(),
      maxOIShort: parsedMaxOIShort.toString(),
      spreadLong: parsedSpreadLong.toString(),
      spreadShort: parsedSpreadShort.toString(),
      timestamp: timestamp.toString(),
      sig: sig
    };

    console.log(`[TEE Signer] Generated proof for Asset #${assetId} at timestamp ${timestamp}`);
    res.json({ success: true, proof });
  } catch (error) {
    console.error("❌ Error generating TEE proof:", error);
    res.status(500).json({ error: error.message });
  }
});

app.listen(PORT, () => {
  console.log(`🚀 TEE Signer Service listening on port ${PORT}`);
});
