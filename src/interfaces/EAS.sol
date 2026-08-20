// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Minimal EAS interfaces for Base predeploys.
 *      EAS Core:        0x4200000000000000000000000000000000000021
 *      Schema Registry: 0x4200000000000000000000000000000000000020
 *      (verify per-chain before use)
 */
struct AttestationData {
    address recipient;
    uint64 expirationTime;
    bool revocable;
    bytes32 refUID;
    bytes data;
    uint256 value;
}

struct AttestationRequest {
    bytes32 schema;
    AttestationData data;
}

interface IEAS {
    function attest(AttestationRequest calldata request) external payable returns (bytes32);
    function getAttestation(bytes32 uid)
        external
        view
        returns (
            bytes32 uid_,
            bytes32 schema,
            address recipient,
            address attester,
            uint64 time,
            uint64 expirationTime,
            bool revocable,
            bytes32 refUID,
            bytes memory data,
            uint256 value
        );
}

interface ISchemaRegistry {
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);
    function getSchema(bytes32 uid)
        external
        view
        returns (
            bytes32 uid_,
            address resolver,
            bool revocable,
            string memory schema,
            address attester,
            uint64 time
        );
}
