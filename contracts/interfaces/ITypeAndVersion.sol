// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

abstract contract ITypeAndVersion {
    function typeAndVersion() external pure virtual returns (string memory);
}