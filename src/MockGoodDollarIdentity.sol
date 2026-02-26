// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockGoodDollarIdentity {
    mapping(address => bool) private whitelisted;
    mapping(address => bool) private blacklisted;

    function isWhitelisted(address account) external view returns (bool) {
        return whitelisted[account];
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    // Cheat code function for testnet: instantly verify any user
    function testnetSimulateFaceScan(address account) external {
        whitelisted[account] = true;
    }

    // Cheat code function for testing evictions and failures
    function testnetRevokeIdentity(address account) external {
        whitelisted[account] = false;
    }

    function testnetBlacklist(address account) external {
        blacklisted[account] = true;
    }
}
