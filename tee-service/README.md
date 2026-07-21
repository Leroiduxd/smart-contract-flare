# Local TEE Enclave KMS Signer Service

This is the local Trusted Execution Environment (TEE) / Enclave KMS Proof Signer service for the **Flare Brokex Protocol**.

It replaces the centralized AWS KMS service by running a secure local signing microservice.

---

## 🛠️ Quick Start

### 1. Install Dependencies locally
```bash
cd tee-service
npm install
npm start
```

The service will start on `http://localhost:8080`.

### 2. Run with Docker Compose
```bash
cd tee-service
docker-compose up --build -d
```

---

## 📡 API Endpoints

### `GET /health`
Returns service status and active enclave KMS signer address.

### `GET /signer-address`
Returns `{ "kmsSigner": "0x..." }`.

### `POST /sign-proof`
Generates a signed `KmsProof` matching `BrokexCore` requirements.

**Request Body:**
```json
{
  "assetId": 5500,
  "maxOILong": 500000000000,
  "maxOIShort": 500000000000,
  "spreadLong": 100,
  "spreadShort": 100
}
```

**Response:**
```json
{
  "success": true,
  "proof": {
    "assetId": "5500",
    "maxOILong": "500000000000",
    "maxOIShort": "500000000000",
    "spreadLong": "100",
    "spreadShort": "100",
    "timestamp": "1720000000",
    "sig": "0x..."
  }
}
```
