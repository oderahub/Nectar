// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGoodDollarIdentity
/// @notice Interface to call the GoodDollar Identity contract on Celo.
/// @dev Mainnet address: 0xC361A6E67822a0EDc17D899227dd9FC50BD62F42
interface IGoodDollarIdentity {
    /// @notice Returns true if the address has a valid, unexpired FaceTec scan.
    function isWhitelisted(address account) external view returns (bool);

    /// @notice Returns true if the address has been flagged for fraud/abuse.
    function isBlacklisted(address account) external view returns (bool);
}
