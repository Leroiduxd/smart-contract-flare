require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true
    }
  },
  networks: {
    coston2: {
      url: "https://coston2-api.flare.network/ext/bc/C/rpc",
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      chainId: 114
    }
  }
};
