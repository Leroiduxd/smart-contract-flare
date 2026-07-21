# 🔒 Official Flare Confidential Compute (FCC) TEE Local Stack

This directory contains the **official 3-service Flare Confidential Compute (FCC) TEE backend stack** configured to run locally on your Mac, matching the Flare Developer Documentation.

---

## 🏗️ Architecture Stack

The local TEE execution stack consists of 3 Docker services:

1. **`extension-tee`** (Port `8000`): Your local TEE enclave business logic (secure key storage & signature execution inside memory).
2. **`ext-proxy`** (Port `6674`): Official Flare TEE proxy container (`ghcr.io/flare-foundation/fce-proxy:latest`). Watches the Coston2 blockchain for instructions targeting your extension and routes results back.
3. **`redis`** (Port `6379`): Internal proxy state store.

---

## 🛠️ Step-by-Step Setup Guide on Mac

### 1. Prerequisites
- **Docker Desktop** installed and running on your Mac.
- **ngrok** (or any HTTPS tunnel to expose local port `6674`).

### 2. Start the HTTPS Tunnel
Open a terminal and run:
```bash
ngrok http 6674
```
Copy the generated `https://xxxx.ngrok-free.app` URL.

### 3. Configure Environment Variables
Create a `.env` file inside `fcc-tee/`:
```bash
TUNNEL_URL=https://xxxx.ngrok-free.app
PRIVATE_KEY=your_coston2_private_key
EXTENSION_ID=65536
```

### 4. Launch the Complete Local FCC TEE Stack
From the `fcc-tee/` directory, run:
```bash
docker-compose up --build -d
```

---

## 📡 Service Inspection

- **Check running TEE containers:**
  ```bash
  docker-compose ps
  ```

- **Inspect Enclave logs:**
  ```bash
  docker-compose logs -f extension-tee
  ```

- **Inspect Flare Proxy logs:**
  ```bash
  docker-compose logs -f ext-proxy
  ```

- **Test local enclave health:**
  ```bash
  curl http://localhost:8000/health
  ```
