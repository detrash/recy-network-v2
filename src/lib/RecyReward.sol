// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library RecyReward {
    uint256 private constant ONE_E18 = 1e18;

    // Exact cumulative supply caps (sum of all 6 epochs = 22,000,000 cRECY hard cap)
    uint256 public constant FIRST_EPOCH  = 2_138_428 * ONE_E18;  // +2,138,428 @ 1 cRECY/kg
    uint256 public constant SECOND_EPOCH = 3_528_409 * ONE_E18;  // +1,389,981 @ 0.5 cRECY/kg
    uint256 public constant THIRD_EPOCH  = 9_882_748 * ONE_E18;  // +6,354,339 @ 0.1 cRECY/kg
    uint256 public constant FOURTH_EPOCH = 12_775_428 * ONE_E18; // +2,892,680 @ 0.01 cRECY/kg
    uint256 public constant FIFTH_EPOCH  = 15_895_114 * ONE_E18; // +3,119,686 @ 0.0001 cRECY/kg
    uint256 public constant SIXTH_EPOCH  = 22_000_000 * ONE_E18; // +6,104,886 @ 0.000002815328847 cRECY/kg
    uint256 public constant LAST_EPOCH   = SIXTH_EPOCH;

    // Milligrams of waste required to mint 1 whole cRECY (1e18 wei)
    uint256 public constant FIRST_EPOCH_REWARD  = 1_000_000;       // 1 kg
    uint256 public constant SECOND_EPOCH_REWARD = 2_000_000;       // 2 kg
    uint256 public constant THIRD_EPOCH_REWARD  = 10_000_000;      // 10 kg
    uint256 public constant FOURTH_EPOCH_REWARD = 100_000_000;     // 100 kg
    uint256 public constant FIFTH_EPOCH_REWARD  = 10_000_000_000;  // 10,000 kg
    uint256 public constant SIXTH_EPOCH_REWARD  = 355_198_292_755; // 355,198.292755 kg
    uint256 public constant LAST_EPOCH_REWARD   = SIXTH_EPOCH_REWARD;

    /**
     * @notice Computes cRECY reward (in wei) for `amount` (in milligrams) given current token `supply`.
     * @dev Internal pure function inlined into RecyReport (eliminates external library deploy & DELEGATECALL).
     */
    function calculateReward(uint128 amount, uint256 supply) internal pure returns (uint128) {
        if (amount == 0 || supply >= SIXTH_EPOCH) {
            return 0;
        }

        uint256 divisor;
        if (supply < FIRST_EPOCH) {
            divisor = FIRST_EPOCH_REWARD;
        } else if (supply < SECOND_EPOCH) {
            divisor = SECOND_EPOCH_REWARD;
        } else if (supply < THIRD_EPOCH) {
            divisor = THIRD_EPOCH_REWARD;
        } else if (supply < FOURTH_EPOCH) {
            divisor = FOURTH_EPOCH_REWARD;
        } else if (supply < FIFTH_EPOCH) {
            divisor = FIFTH_EPOCH_REWARD;
        } else {
            divisor = SIXTH_EPOCH_REWARD;
        }

        return SafeCast.toUint128((uint256(amount) * ONE_E18) / divisor);
    }
}
