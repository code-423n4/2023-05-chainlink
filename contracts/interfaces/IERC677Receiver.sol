// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IERC677Receiver {
  function onTokenTransfer(address sender, uint256 amount, bytes calldata data) external;
}
