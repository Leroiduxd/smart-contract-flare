// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ContractRegistry } from "@flarenetwork/flare-periphery-contracts/flare/ContractRegistry.sol";
import { FtsoV2Interface } from "@flarenetwork/flare-periphery-contracts/flare/FtsoV2Interface.sol";

contract BrokexOracleFTSO {
    // ID du feed PAXG/USD (catégorie 01 = Crypto, "PAXG/USD" encodé en hex, paddé à 21 bytes)
    bytes21 public constant PAXG_USD_ID =
        0x01504158472f555344000000000000000000000000;

    // seuil de fraîcheur max toléré (ex: 3600 secondes / 1 heure pour éviter les blocages en testnet)
    uint256 public constant MAX_STALENESS = 3600;

    error PriceTooStale(uint256 timestamp, uint256 nowTs);

    function getGoldPrice() public returns (uint256) {
        FtsoV2Interface ftsoV2 = ContractRegistry.getFtsoV2();
        (uint256 value, int8 dec, uint64 timestamp) = ftsoV2.getFeedById(PAXG_USD_ID);

        if (block.timestamp - timestamp > MAX_STALENESS) {
            revert PriceTooStale(timestamp, block.timestamp);
        }

        // Ajustement à 10^6 (6 décimales)
        uint256 price;
        if (dec > 6) {
            price = value / (10 ** uint256(int256(dec) - 6));
        } else if (dec < 6) {
            price = value * (10 ** uint256(6 - int256(dec)));
        } else {
            price = value;
        }

        return price;
    }
}
