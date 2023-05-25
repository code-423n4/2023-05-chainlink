// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ConfirmedOwner} from "../libraries/internal/ConfirmedOwner.sol";

/// @title The OwnerIsCreator contract
/// @notice A contract with helpers for basic contract ownership.
contract OwnerIsCreator is ConfirmedOwner {
  constructor() ConfirmedOwner(msg.sender) {}
}
