const hre = require("hardhat");

async function main() {
  // Reset network to fork Coston2 at block 33006962
  await hre.network.provider.request({
    method: "hardhat_reset",
    params: [
      {
        forking: {
          jsonRpcUrl: "https://coston2-api.flare.network/ext/bc/C/rpc",
          blockNumber: 33006962,
        },
      },
    ],
  });

  const VAULT_ADDRESS = "0x9a1399F58F75E36424bD0E74744f562d513a0df6";
  const CORE_ADDRESS = "0x379f934b2404c34B399Dfa7d15da1C550d341838";
  const USDT_ADDRESS = "0x1771cD797E23Fd3C7bcf8912110ac78084302961";

  const usdt = await hre.ethers.getContractAt("USDTMock", USDT_ADDRESS);
  const vault = await hre.ethers.getContractAt("BrokexVault", VAULT_ADDRESS);
  const core = await hre.ethers.getContractAt("BrokexCore", CORE_ADDRESS);

  const usdtBal = await usdt.balanceOf(VAULT_ADDRESS);
  const totalSupply = await vault.totalSupply();
  const lpPrice = await vault.getLPPrice.staticCall();
  const totalUnrealizedPnL = await core.getTotalUnrealizedPnL.staticCall();
  const goldPrice = await core.getPriceExternal.staticCall(5500);

  console.log("=== FORKED STATE AT BLOCK 33006962 ===");
  console.log("USDT Balance:       ", usdtBal.toString());
  console.log("LP Total Supply:    ", totalSupply.toString());
  console.log("LP Price:           ", lpPrice.toString());
  console.log("Total Unrealized PnL:", totalUnrealizedPnL.toString());
  console.log("Gold Price:         ", goldPrice.toString());

  const exp = await core.exposures(5500);
  console.log("OI Long:            ", exp.openInterestLong.toString());
  console.log("Avg Entry Long:     ", exp.avgEntryPriceLong.toString());

  const nextId = await core.nextTradeId();
  console.log("Next Trade ID:      ", nextId.toString());

  for (let i = 1; i < Number(nextId); i++) {
    const t = await core.trades(i);
    console.log(`Trade #${i}:`);
    console.log(`  State:     `, t.state.toString());
    console.log(`  Margin:    `, t.margin.toString());
    console.log(`  Leverage:  `, t.leverage.toString());
    console.log(`  OpenPrice: `, t.openPrice.toString());
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
