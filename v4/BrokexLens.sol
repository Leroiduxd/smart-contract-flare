// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IBrokexCore {
    struct Trade {
        uint256 id;
        address trader;
        uint256 assetId;
        uint8   state;
        uint8   direction;
        uint8   orderType;
        uint256 margin;
        uint256 leverage;
        uint256 targetPrice;
        uint256 openPrice;
        uint256 closePrice;
        uint256 stopLoss;
        uint256 takeProfit;
        uint256 openTimestamp;
        uint256 closeTimestamp;
        uint256 borrowFee;
    }

    struct AssetConfig {
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 minTradeSize;
        uint256 commissionBps;
        uint256 borrowRateHourly;
        uint256 profitCap;
        uint256 executionTolerance;
        uint256 maxProofAge;
        uint256 maxTraderOI;
        uint256 maxGlobalOI;
        uint256 lockedCapitalBps;
        uint256 liqThresholdBps;
        bool    listed;
        bool    frozen;
    }

    function trades(uint256 tradeId)                             external view returns (Trade memory);
    function nextTradeId()                                       external view returns (uint256);
    function openInterestLong(uint256 assetId)                   external view returns (uint256);
    function openInterestShort(uint256 assetId)                  external view returns (uint256);
    function avgEntryPriceLong(uint256 assetId)                  external view returns (uint256);
    function avgEntryPriceShort(uint256 assetId)                 external view returns (uint256);
    function totalLockedCapital()                                external view returns (uint256);
    function traderOpenInterest(uint256 assetId, address trader) external view returns (uint256);
    function assets(uint256 assetId)                             external view returns (AssetConfig memory);
    function paused()                                            external view returns (bool);
    function emergencyMode()                                     external view returns (bool);
    function owner()                                             external view returns (address);
    function kmsSigner()                                         external view returns (address);
    function USDC()                                              external view returns (address);
    function getFreeCapital()                                    external view returns (uint256);
}

interface IBrokexVault {
    function owner()               external view returns (address);
    function coreContract()        external view returns (address);
    function totalSupply()         external view returns (uint256);
    function lastKnownPrice()      external view returns (uint256);
    function getFreeLiquidity()    external view returns (uint256);
    function getRequiredFreeUSDC() external view returns (uint256);
    function totalPendingLP()      external view returns (uint256);
    function USDC()                external view returns (address);
}

/// @title BrokexLens V4 — Read-Only Aggregator & Lens for Brokex V4 Protocol
/// @notice Single-call protocol state aggregator adapted specifically for BrokexCore V4 & BrokexVault V4.
contract BrokexLens {

    IBrokexCore public immutable core;
    IBrokexVault public immutable vault;

    constructor(address coreAddress, address vaultAddress) {
        core  = IBrokexCore(coreAddress);
        vault = IBrokexVault(vaultAddress);
    }

    struct ProtocolSnapshot {
        uint256 lastTradeId;
        bool    paused;
        bool    emergencyMode;
        address coreOwner;
        address kmsSigner;
        uint256 lpTotalCapital;
        uint256 lpFreeCapital;
        uint256 lpLockedCapital;
        uint256 vaultUsageBps;
        address vaultOwner;
        address vaultCore;
        bool    coreLocked;
        uint256 lpTotalSupply;
        uint256 lpLastKnownPrice;
        uint256 requiredFreeUSDC;
    }

    struct AssetSnapshot {
        uint256 assetId;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 totalOpenInterest;
        uint256 avgEntryPriceLong;
        uint256 avgEntryPriceShort;
        bool    listed;
        bool    frozen;
    }

    struct TradeSummary {
        uint256 id;
        address trader;
        uint256 assetId;
        uint8   state;
        uint8   direction;
        uint256 margin;
        uint256 leverage;
        uint256 openPrice;
        uint256 liqPrice;
    }

    function _calcLiqPrice(IBrokexCore.Trade memory t, uint256 liqBps) internal pure returns (uint256) {
        if (t.leverage == 0) return 0;
        uint256 p = t.state == 1 ? t.openPrice : t.targetPrice;
        uint256 move = (p * liqBps) / (t.leverage * 1e6);
        if (t.direction == 1) {
            return p > move ? p - move : 0;
        }
        return p + move;
    }

    function getTradeSummary(uint256 tradeId) external view returns (TradeSummary memory s) {
        IBrokexCore.Trade memory t = core.trades(tradeId);
        IBrokexCore.AssetConfig memory cfg = core.assets(t.assetId);
        s = TradeSummary({
            id:          t.id,
            trader:      t.trader,
            assetId:     t.assetId,
            state:       t.state,
            direction:   t.direction,
            margin:      t.margin,
            leverage:    t.leverage,
            openPrice:   t.openPrice,
            liqPrice:    _calcLiqPrice(t, cfg.liqThresholdBps)
        });
    }

    function getTradeRangeSummaries(uint256 startId, uint256 length)
        external view returns (TradeSummary[] memory result)
    {
        result = new TradeSummary[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 id = startId + i;
            IBrokexCore.Trade memory t = core.trades(id);
            IBrokexCore.AssetConfig memory cfg = core.assets(t.assetId);
            result[i] = TradeSummary({
                id:          t.id,
                trader:      t.trader,
                assetId:     t.assetId,
                state:       t.state,
                direction:   t.direction,
                margin:      t.margin,
                leverage:    t.leverage,
                openPrice:   t.openPrice,
                liqPrice:    _calcLiqPrice(t, cfg.liqThresholdBps)
            });
        }
    }

    function getProtocolSnapshot() external view returns (ProtocolSnapshot memory s) {
        uint256 nextId        = core.nextTradeId();
        uint256 lastId        = nextId > 1 ? nextId - 1 : 0;
        
        address usdcAddress   = vault.USDC();
        uint256 totalCapital  = IERC20(usdcAddress).balanceOf(address(vault));
        uint256 lockedCapital = core.totalLockedCapital();
        uint256 freeCapital   = core.getFreeCapital();

        s = ProtocolSnapshot({
            lastTradeId:        lastId,
            paused:             core.paused(),
            emergencyMode:      core.emergencyMode(),
            coreOwner:          core.owner(),
            kmsSigner:          core.kmsSigner(),
            lpTotalCapital:     totalCapital,
            lpFreeCapital:      freeCapital,
            lpLockedCapital:    lockedCapital,
            vaultUsageBps:      totalCapital > 0 ? (lockedCapital * 10_000) / totalCapital : 0,
            vaultOwner:         vault.owner(),
            vaultCore:          vault.coreContract(),
            coreLocked:         vault.coreContract() != address(0),
            lpTotalSupply:      vault.totalSupply(),
            lpLastKnownPrice:   vault.lastKnownPrice(),
            requiredFreeUSDC:   vault.getRequiredFreeUSDC()
        });
    }

    function getAssetSnapshot(uint256 assetId) external view returns (AssetSnapshot memory s) {
        uint256 oiLong  = core.openInterestLong(assetId);
        uint256 oiShort = core.openInterestShort(assetId);
        uint256 avgLong = core.avgEntryPriceLong(assetId);
        uint256 avgShort= core.avgEntryPriceShort(assetId);
        IBrokexCore.AssetConfig memory cfg = core.assets(assetId);
        s = AssetSnapshot({
            assetId:           assetId,
            openInterestLong:  oiLong,
            openInterestShort: oiShort,
            totalOpenInterest: oiLong + oiShort,
            avgEntryPriceLong: avgLong,
            avgEntryPriceShort:avgShort,
            listed:            cfg.listed,
            frozen:            cfg.frozen
        });
    }

    function getTraderOI(uint256 assetId, address trader) external view returns (uint256) {
        return core.traderOpenInterest(assetId, trader);
    }
}
