// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { NftArenazPowersInterface } from "./NftArenazPowersInterface.sol";

contract NftArenazPowers is Ownable, NftArenazPowersInterface {
    mapping(address => bytes32) public nftPowerMerkleRoots;

    function verifyNftPower(bytes32[] calldata merkleProof, uint256 nftId, uint256 nftPower, address nftContractAddress) public view returns (bool) {
        bytes32 leaf = keccak256(abi.encode(nftId, nftPower));
        return MerkleProof.verify(merkleProof, nftPowerMerkleRoots[nftContractAddress], leaf);
    }

    function setNftPowerMerkleRoot(address nftContractAddress, bytes32 merkleRoot) external onlyOwner
    {
        nftPowerMerkleRoots[nftContractAddress] = merkleRoot;
    }
}
