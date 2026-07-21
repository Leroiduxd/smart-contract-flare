const express = require("express");
const { ethers } = require("ethers");
require("dotenv").config();

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8000;

// Enclave State (Secure In-Memory Key Storage inside TEE)
const enclaveStore = {
  keys: new Map(), // userAddress => privateKey
  masterSigner: null
};

// Initialize Master Enclave Signer Key
const MASTER_KEY = process.env.ENCLAVE_MASTER_KEY || process.env.KMS_PRIVATE_KEY;
if (MASTER_KEY) {
  enclaveStore.masterSigner = new ethers.Wallet(MASTER_KEY);
  console.log(`[TEE Enclave] Master Key Loaded: ${enclaveStore.masterSigner.address}`);
} else {
  enclaveStore.masterSigner = ethers.Wallet.createRandom();
  console.log(`[TEE Enclave] Generated Ephemeral Master Key: ${enclaveStore.masterSigner.address}`);
}

console.log("=================================================");
console.log("   FLARE CONFIDENTIAL COMPUTE (FCC) TEE ENGINE   ");
console.log("=================================================");
console.log(`🔒 Enclave Public Address: ${enclaveStore.masterSigner.address}`);
console.log("=================================================");

/**
 * Health check endpoint required by ext-proxy
 */
app.get("/health", (req, res) => {
  res.json({
    status: "HEALTHY",
    extension: "brokex-sign-extension",
    enclaveAddress: enclaveStore.masterSigner.address
  });
});

/**
 * Official FCC TEE Instruction Handler Endpoint
 * Receives decoded instructions forwarded from ext-proxy
 * 
 * Payload structure from ext-proxy:
 * {
 *   instructionId: string,
 *   opType: "KEY",
 *   opCommand: "UPDATE" | "SIGN",
 *   message: string (hex/base64),
 *   claimBackAddress: string
 * }
 */
app.post("/handle-instruction", async (req, res) => {
  try {
    const { instructionId, opType, opCommand, message, claimBackAddress } = req.body;

    console.log(`\n📥 [TEE Enclave] Received Instruction #${instructionId || 'LOCAL'}`);
    console.log(`   opType: ${opType} | opCommand: ${opCommand}`);
    console.log(`   sender: ${claimBackAddress}`);

    // Operation Router
    if (opType === "KEY" || opType === "0x4b45590000000000000000000000000000000000000000000000000000000000") {
      
      // 1. UPDATE KEY (Store encrypted private key in Enclave memory)
      if (opCommand === "UPDATE" || opCommand === "0x5550444154450000000000000000000000000000000000000000000000000000") {
        const keyHex = message.startsWith("0x") ? message : `0x${message}`;
        enclaveStore.keys.set(claimBackAddress.toLowerCase(), keyHex);
        console.log(`  ✅ [TEE Enclave] Private Key stored securely in enclave for ${claimBackAddress}`);

        return res.json({
          success: true,
          result: ethers.hexlify(ethers.toUtf8Bytes("KEY_UPDATED_SUCCESSFULLY")),
          status: "COMPLETED"
        });
      }

      // 2. SIGN MESSAGE / PARAMETERS
      if (opCommand === "SIGN" || opCommand === "0x5349474e00000000000000000000000000000000000000000000000000000000") {
        // Use user's enclave key if set, otherwise master enclave signer
        const userKey = enclaveStore.keys.get(claimBackAddress.toLowerCase());
        const signer = userKey ? new ethers.Wallet(userKey) : enclaveStore.masterSigner;

        // Decode payload or sign raw message bytes
        const msgBytes = ethers.getBytes(message.startsWith("0x") ? message : `0x${message}`);
        const sig = await signer.signMessage(msgBytes);

        console.log(`  ✅ [TEE Enclave] Signed payload with Enclave Key (${signer.address})`);

        return res.json({
          success: true,
          signature: sig,
          signer: signer.address,
          status: "COMPLETED"
        });
      }
    }

    // Default fallback: Direct parameter proof signing
    const signer = enclaveStore.masterSigner;
    const msgBytes = ethers.getBytes(message.startsWith("0x") ? message : `0x${message}`);
    const sig = await signer.signMessage(msgBytes);

    res.json({
      success: true,
      signature: sig,
      signer: signer.address,
      status: "COMPLETED"
    });

  } catch (error) {
    console.error("❌ [TEE Enclave] Error executing instruction:", error);
    res.status(500).json({
      success: false,
      error: error.message,
      status: "FAILED"
    });
  }
});

app.listen(PORT, () => {
  console.log(`🚀 FCC TEE Extension Handler running on port ${PORT}`);
});
