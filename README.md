# Chainlink Cross-Chain Services: CCIP and ARM Network audit details
- Total Prize Pool: $300,000 USDC 
  - HM awards: $180,250 USDC 
  - QA awards: $4,875 USDC 
  - Bot Race awards: $5,000 USDC 
  - Gas awards: $4,875 USDC 
  - Judge awards: $38,400 USDC 
  - Lookout awards: $15,600 USDC 
  - Scout awards: $1,000 USDC 
  - Mitigation Review: $50,000 USDC (*Opportunity goes to top 3 certified wardens based on placement in this audit.*)
- Join [C4 Discord](https://discord.gg/code4rena) to register
- Submit findings [using the C4 form](https://code4rena.com/contests/YYYY-MM-sponsorName-contest/submit)
- [Read our guidelines for more details](https://docs.code4rena.com/roles/wardens)
- Starts May 26, 2023 20:00 UTC 
- Ends June 12, 2023 20:00 UTC 

**IMPORTANT NOTE:** Prior to receiving payment from this audit you MUST become a [Certified Warden](https://code4rena.com/certified-contributor-application/)  (successfully complete KYC). You do not have to complete this process before competing or submitting bugs. You must have started this process within 48 hours after the audit ends, i.e. **by June 14, 2023 at 20:00 UTC in order to receive payment.**

## Automated Findings / Publicly Known Issues

Automated findings output for the audit can be found [here](add link to report) within 24 hours of audit opening.

# Overview

The Cross-Chain Interoperability Protocol (CCIP) provides a standard for developers to build applications that can
send messages and transfer value across multiple blockchains.

## Architecture

A CCIP `lane` is a set of contracts and off-chain DONs(Decentralized Oracle Networks) that enable a message to be securely sent from Chain A to Chain B.

### Lane Diagram
![image](https://github.com/code-423n4/2023-05-chainlink/assets/47150934/c954ab33-b856-4306-ab36-5cf79a43a338)

Contracts in white are chain specific, contracts in green are lane specific. The purple `Dapp`s are customer contracts.

NOTE: This image only shows a simplified view of the message flow, it does not include all CCIP contracts, most notably it omits the ARM and PriceRegistry.

### Lane Components

**Source Router**
- The entry and exit point for all CCIP transactions.
- This contract will be responsible for initiating `ccipSend` and handling token approvals.
- This contract will then route to the destination-specific OnRamp.
- One router can send messages to various chains, therefore, only a single router exists per chain, and is shared across lanes. This means customers only have to know about one single address to send and receive messages.
- This is also the only contract that they ever have to approve tokens for.

**EVM2EVM OnRamp**
- Lane specific keeper of sequenceNumbers and nonces.
- As opposed to the router, this contract is lane specific, meaning there is an onRamp instance for every lane.
- This contract performs destination chain-specific validity checks.
- This contract is Responsible for fee calculations and charging fees.
- If the message includes tokens, the contract interacts with the TokenPool to lock or burn the token.
- Emits the `CCIPSendRequested` event.

**TokenPools**
- An abstraction layer over ERC20 tokens to facilitate OnRamp and OffRamp token-related operations.
- Token pools have several types, e.g. LockReleaseTokenPool, BurnMintTokenPool. The interfaces are abstract to allow for CCIP to not have to know if a tokens need to be burned or locked in a pool.
- TokenPools can rate limit the number of tokens released to limit risk.
- TokenPools are shared across lanes. For a token on a given chain, different onRamps and offRamps will use the same token pool instance.
- One token pool is deployed for each token.

**DON (Decentralized Oracle Network)**
- Chainlink Decentralized Oracle Networks run Chainlink OCR2 — a BFT protocol among `n` participants, up to `f` of which can be faulty (e.g. act maliciously).
- The protocol runs in rounds and in each round a value may be agreed upon (the report). A report that is produced is attested by a quorum of participants. The report is then transmitted on-chain by one of the participants. No one single participant is responsible for transmitting on every round, and all of them will attempt to do so in a round-robin fashion until a transmission has taken place.
- CCIP has two OCR2 DON committees:
  - Committing DON: responsible for committing to the cross-chain message using a merkle root.
  - Executing DON: responsible for executing the cross-chain message.

**CommitStore**
- Implements `OCR2Base`, entry point for the Committing DON. CommitStore is lane-specific.
- Checks if every report is transmitted by a valid Committing DON node and signed by right number of nodes in the DON.
  Stores merkle roots on the destination chain for contiguous sequence numbers of a given lane.
- Messages are aggregated in batches, and a merkle tree is built for each batch. During Executing DON transmissions, or manual execution, a message can be look up in the merkle tree to verify its existence and correctness.

**EVM2EVM OffRamp**
- Implements `OCR2BaseNoChecks`, entry point for the Executing DON. OffRamp is lane-specific.
- Checks if a report is transmitted by a executing DON node, does not check signatures. Any Executing DON node can in theory attempt message execution at any time.
- Mainly uses OCR2 for allowListing and compatibility with existing code.
- Ensures that the message is authentic by verifying the proof provided by the Executing DON against the committed merkle root in CommitStore.
- Ensures that the ARM (Active Risk Management Network) is not stopping message execution.
- Ensures that message execution state is valid, e.g. each message can only be executed once.
- Release or mint sent tokens to the receiver.
- Invokes destination router.

**Destination Router**
- A fixed address from which ccipReceive calls are made.
- The distinction between source and destination routers is only made as an example, they are in fact a single contract per chain that does both tasks.

### Additional Components

**PriceRegistry**
- Keeper of pricing information any token in the system and the gas cost of destination chains.
- It is only deployed once per chain and thereby aggregates all price information of all lanes. Receives feeUpdates from the Commit DON to update the gas costs for other lanes.

**ARM**
- Active Risk Management Network
- Entry point for the ARM DON, this DON is not a CL Node but a separate, minimal, Rust implementation of a DON.
- Is able to halt the entire CCIP protocol using DON voting. This should only happen in critical failure scenarios.

**Libraries**
- RateLimiter
  - Bucket based rate limiter for token value. NOTE: does not rate limit the data field of a CCIP message, even though significant value could be contained there. This is because CCIP has no way of knowing that the effect of the bytes payload is on the destination chain.

### Message Lifecycle

1. [Approvals] Sending dapp, for a given message, must approve at least feeAmount of the feeToken to the router where feeAmount is the amount returned by `getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage message) returns (uint256 fee)`.  If the dapp is using sending tokens then, before calling `ccipSend` the sender must have approved the router to take at least the token amount they want to transfer. Dapp may manage the approval or provide an infinite one should they not want to deal with that.

2. The sender calls `ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message) returns (bytes32 messageId)` providing the message they wish to send to `destinationChainID`. All relevant information is included in the message and a unique messageId is returned for tracking purposes.

3. The Committing DON comes to consensus on finalized events emitted from `ccipSend`, batches them into a root and writes the root to the destination chain. DON’s signatures are verified on the destination chain.

4. Members of the ARM (Active Risk Management Network) verify the Committing DON’s root and vote to “bless” it. Once sufficient votes have been acquired, it becomes available for execution.

5. The Executing DON comes to consensus on a set of executable messages (correct sequencing, within lane rate limits etc.) and submits a batch of executions to the offramp. For each execution the message gets routed through the router on the destination chain to the users specified receiver via `ccipReceive(Client.Any2EVMMessage calldata message)`

### Interfaces

- Contract interfaces are defined under `/contracts/interfaces`
- Client-facing CCIP message types are defined in `/contracts/libraries/Client.sol`

### Examples

You can find example application code under `/contracts/applications`

| Example              | Description                                                              |
|----------------------|--------------------------------------------------------------------------|
| PingPongDemo.sol     | A simple ping-pong contract for demonstrating cross-chain communication  |
| ImmutableExample.sol | Example of an immutable client example which supports EVM/non-EVM chains |

NOTE: these contracts are examples and not in scope of this audit.

## Trust Assumptions

- Owner for all contracts will be a Committing DON controlled owner contract
- Tokens will be audited prior to whitelisting.
- Reasons for not listing a token could be, but are not limited to:
  - Tokens that are rebasing.
  - Tokens with fee-on-transfer logic.
  - Token decimals and token prices outside a reasonable range. Can cause price format (see below) to overflow or be truncated to 0.

## Price Format

Both Billing and AggregateRateLimiter (Rate limit based on aggregated USD value) requires token price feeds.
Token prices are stored in PriceRegistry.

Since tokens can vary in `decimals`, prices are stored as USD (with 18 decimals) per 1e18 of the smallest token denomination.
A price of `1e18` represents 1 USD per 1e18 token amount.

Examples:
- 1 USDC = 1.00 USD per full token, each full token is 1e6 units -> 1 * 1e18 * 1e18 / 1e6 = 1e30
- 1 ETH = 2,000 USD per full token, each full token is 1e18 units -> 2000 * 1e18 * 1e18 / 1e18 = 2_000e18
- 1 LINK = 5.00 USD per full token, each full token is 1e18 units -> 5 * 1e18 * 1e18 / 1e18 = 5e18

## Billing

A single fee is paid on the source chain. The message will be executed on the destination chain with the caveat that execution might be delayed. See section below on execution latency for details.

### Fee Calculation

A cache of recent destination gas prices and feeToken prices, is maintained on the source chain. Updates are done either by piggy backing on commits to that source chain or via timeout. The timeout provides a configurable maximum destination gas price staleness. The fee charged is calculated as follows:

```
fee(msg) = execution_fee + token_transfer_fee;
```

**Execution Fee**
```
execution_fee = network_fee + feeTokenPerUnitGasOnDestination * (msg.gasLimit + destinationGasOverhead) * (multiplier) 
```
Details on each parameter:
- `network_fee`: the fee for CCIP node operators and any coordinator
- `feeTokenPerUnitGasOnDestination`: the cached destination gas price per unit fee token
- `msg.gasLimit`: the user specified message gas limit, current maximum is 4M
- `destinationGasOverhead`: the average overhead incurred on the destination chain by CCIP to process the message
- `multiplier`: a scaling factor for execution costs, will be tuned according to actual execution costs to avoid CCIP node operators from incurring losses (unusual gas spikes etc.).

**Token Transfer Fee**
```
token_transfer_fee =
sum_each_token_transfer_USD(
	min(
		maxFee,
		max(minFee, bpsValue)
	)
).convert_USD_value_to_fee_token()
```
where `bpsValue` is defined as `tokenAmount * price * bps ratio`

Details on each parameter:
- `minFee`
  - the minimum fee to charge per transfer of a given token , denoted in US cents
  - will be charged even if the value or amount of token transferred is 0
  - can be 0

- `maxFee`
  - the maximum fee to charge per transfer of a given token
  - denoted in US cents
  - can be 0

- `ratio`
  - the bps fee to charge per transfer of a given token
  - denoted in 0.1 bps, or 0.001%
  - stored as uint16, range is [0, 65%]
  - can be 0

## Execution

### Execution Latency
If the fee paid on source is within an acceptable range of the estimated execution cost,
the Executing DON will execute immediately after (sourceChainFinality + root committed + ARM approval of the root).
Should the fee be significantly lower than the estimated execution cost (i.e. gas price spike), CCIP will
slowly ignore greater portion of the fee gap to eventually ensure execution.

Long delay (> 1hr) scenarios should be exceedingly rare (occurring on the order of once a year) and only apply to
specific chains (e.g. eth mainnet), nevertheless, if a user wishes to execute anyway, they will
have the option of manually executing the message after a window of time through the CCIP explorer.

### Gas Limit
The `gasLimit` specifies the maximum amount of gas that can be consumed to execute the `ccipReceive()` implementation on the destination blockchain. Unspent gas is not refunded.

If you want to transfer tokens directly to an EOA address as `receiver` on the destination chain, you should explicitly set `gasLimit` to `0` given there is no `ccipReceive()` implementation to call (and consume gas).

If `extraArgs` is left empty (0 length byte array), a default of `200,000` gas will be set.

Following options might be helpful to estimate the proper gas limit:

- Ethereum client RPC: `eth_estimateGas`, see also [https://ethereum.github.io/execution-apis/api-documentation/](https://ethereum.github.io/execution-apis/api-documentation/) and [https://docs.alchemy.com/reference/eth-estimategas](https://docs.alchemy.com/reference/eth-estimategas). To be applied on `receiver.ccipReceive()`. Note the limitation if you set the `onlyRouter` modifier on `ccipReceive()` (see example contract above).
- Foundry gas tests: see [https://book.getfoundry.sh/forge/gas-tracking](https://book.getfoundry.sh/forge/gas-tracking)
- Hardhat plugin for gas tests: see [https://github.com/cgewecke/eth-gas-reporter](https://github.com/cgewecke/eth-gas-reporter)
- Use a blockchain explorer to look up the gas consumption of a particular internal tx (i.e. call `ccipReceive()`)

### Sequencing

Messages from a given sender to a given destination chain will always be executed in the order in which they are sent.
If the `strict: true`  is set in `extraArgs`, then a `ccipReceive` revert will
⚠️**cause subsequent message from the same sender to be blocked until that message is executed** ⚠️.
Use with extreme caution to avoid blocking messages from the sender forever.
Receiver dapps using `strict: true` should be prepared to do one of the following:

- Take some out of band action to alter the dapp state to permit a successful manually execution of the message so the sequence can continue (effectively implement a “skip message” escape hatch)
- Abandon the inflight messages from the sender via a source chain upgrade or some other mechanism

Furthermore they need to be certain that the receiver is the intended receiver. We recommend testing without strict first.

### Manual Execution

Manual execution will be available through CL supplied scripts or via the CCIP UI. Anyone can develop their own tooling
to assist in manually executing but given the need to construct a valid merkle tree CCIP will be issuing tooling to assist in this process.

Manual execution window begins after `permissionLessExecutionThresholdSeconds` has passed since the time the message was included in CommitStore.

## Chain Selector

CCIP does not use (evm)chainIds as the protocol is chain family agnostic and there is no unified schema that would fit all chain families.
This is why CCIP introduces the notion of CCIP Chain Selectors, a randomly chosen uint64 value per unique blockchain.
Upon deploying to a new blockchain, if no chainSelector is available yet, one will be issued.
These chainSelectors are required for sending txs, as ccipSend requires the destination to be specified with this selector, and not a chainId.


# Scope

| Contract                                                                                       | SLOC | Purpose                                                                                                                | Libraries used                                           |  
|------------------------------------------------------------------------------------------------|------|------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------|
| [Router.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/Router.sol)                                                             | 183  | Entry and exit contract for CCIP                                                                                       | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [ARM.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/ARM.sol)                                                                   | 422  | Active Risk Management, a second layer of security for CCIP                                                            | -                                                        |
| [PriceRegistry.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/PriceRegistry.sol)                                               | 165  | Contains pricing information in USD for any CCIP supported token for that chain                                        | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [CommitStore.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/CommitStore.sol)                                                   | 137  | Security critical contract that stores the merkle roots for tx batches                                                 | -                                                        |
| [AggregateRateLimiter.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/AggregateRateLimiter.sol)                                 | 52   | Token bucket based rate limiting with token prices                                                                     | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [OwnerIsCreator.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/OwnerIsCreator.sol)                                             | 5    | Simply contracts that enforces the creator becomes the owner                                                           | -                                                        |
| [onRamp/EVM2EVMOnRamp.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/onRamp/EVM2EVMOnRamp.sol)                                 | 526  | The chain family specific gateway to a destination chain. Emits the ccipSendRequested event                            | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |                              
| [offRamp/EVM2EVMOffRamp.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/offRamp/EVM2EVMOffRamp.sol)                             | 365  | The chain family specific execution contract on the destination chain.                                                 | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [ocr/OCR2Abstract.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/ocr/OCR2Abstract.sol)                                         | 72   | Abstract contract for OCR2 logic                                                                                       | -                                                        |
| [ocr/OCR2Base.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/ocr/OCR2Base.sol)                                                 | 169  | Base contract for OCR2 logic, checks transmitters and signatures are valid before calling underlying contracts         | -                                                        |
| [ocr/OCR2BaseNoChecks.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/ocr/OCR2BaseNoChecks.sol)                                 | 137  | Base contract for OCR2 logic, only checks transmitters and **not** signatures before calling underlying contracts      | -                                                        |
| [pools/TokenPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/TokenPool.sol)                                           | 89   | Abstract base functionality of a token pool                                                                            | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [pools/BurnMintTokenPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/BurnMintTokenPool.sol)                           | 30   | Burn mint implementation of a token pool, required burn and mint privileges from the token                             | -                                                        |
| [pools/LockReleaseTokenPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/LockReleaseTokenPool.sol)                     | 49   | Lock release implementation of a token pool. Does not require permissions but does require liquidity to release tokens | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [pools/ThirdPartyBurnMintTokenPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/ThirdPartyBurnMintTokenPool.sol)       | 43   | Example contract for third party owned burn mint pools. Contains extra checks on adding offRamps                       | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [pools/USDC/USDCTokenPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/USDC/USDCTokenPool.sol)                         | 110  | USDC specific implementation of a token pool                                                                           | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [pools/tokens/ERC677.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/tokens/ERC677.sol)                                   | 20   | Basic ERC677 implementation                                                                                            | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [pools/tokens/BurnMintERC677.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/pools/tokens/BurnMintERC677.sol)                   | 39   | Burn mint ERC677 to be compliant with token pool requirements                                                          | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [libraries/Internal.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/libraries/Internal.sol)                                     | 81   | Internal structs, functions and enum                                                                                   | -                                                        |
| [libraries/Client.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/libraries/Client.sol)                                         | 29   | Client facing structs and function to be shared with customers                                                         | -                                                        |
| [libraries/RateLimiter.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/libraries/RateLimiter.sol)                               | 73   | Basic bucket based rate limiter library                                                                                | -                                                        |
| [libraries/MerkleMultiProof.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/libraries/MerkleMultiProof.sol)                     | 38   | Merkle multi proof to allow multiple leaves to be proven efficiently                                                   | -                                                        |
| [libraries/USDPriceWith18Decimals.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/libraries/USDPriceWith18Decimals.sol)         | 9    | Basic math operations to work with our 18 decimal token prices                                                         | -                                                        |
| [interfaces/IPriceRegistry.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IPriceRegistry.sol)                       | 20   | PriceRegistry interface                                                                                                | -                                                        |
| [interfaces/pools/IPool.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/pools/IPool.sol)                             | 19   | Token pool interface                                                                                                   | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [interfaces/IEVM2AnyOnRamp.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IEVM2AnyOnRamp.sol)                       | 18   | Generic onRamp interface                                                                                               | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [interfaces/IRouterClient.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IRouterClient.sol)                         | 17   | External Router interface                                                                                              | -                                                        |
| [interfaces/IRouter.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IRouter.sol)                                     | 11   | Internal Router interface                                                                                              | -                                                        |
| [interfaces/IARM.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IARM.sol)                                           | 9    | ARM interface                                                                                                          | -                                                        |
| [interfaces/ICommitStore.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/ICommitStore.sol)                           | 9    | CommitStore interface                                                                                                  | -                                                        |
| [interfaces/pools/IBurnMintERC20.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/pools/IBurnMintERC20.sol)           | 7    | BurnMintERC20 interface                                                                                                | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [interfaces/IERC677.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IERC677.sol)                                     | 6    | ERC677 interface                                                                                                       | -                                                        |
| [interfaces/IAny2EVMMessageReceiver.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IAny2EVMMessageReceiver.sol)     | 5    | Generic message receiver interface                                                                                     | -                                                        |
| [interfaces/IWrappedNative.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IWrappedNative.sol)                       | 5    | Wrapped native interface                                                                                               | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |
| [interfaces/IAny2EVMOffRamp.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IAny2EVMOffRamp.sol)                     | 4    | Generic offRamp interface                                                                                              | -                                                        |
| [interfaces/IERC677Receiver.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/IERC677Receiver.sol)                     | 4    | ERC677 receiver interface                                                                                              | -                                                        |
| [interfaces/ITypeAndVersion.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/ITypeAndVersion.sol)                     | 4    | TypeAndVersion interface                                                                                               | -                                                        |
| [interfaces/automation/ILinkAvailable.sol](https://github.com/code-423n4/2023-05-chainlink/blob/main/contracts/interfaces/automation/ILinkAvailable.sol) | 4    | LinkAvailable interface                                                                                                | -                                                        |
| SUM                                                                                            | 2985 |                                                                                                                        |                                                          |


## Out of scope

Any file not in the `contracts` folder is out of scope.
There are two external dependencies: the folder `foundry-lib` contains the Foundry dependency `forge-std` and the folder `vendor` contains OpenZeppelin contracts.
Besides these two folders, there is a `libraries` folder containing generic Chainlink contracts that are not specific to CCIP and also out of scope.


```
/contracts/applications/*
/contracts/pools/USDC/{IMessageReceiver.sol, ITokenMessenger.sol}
/contracts/test/*
/libraries/*
/vendor/*
/foundry-lib/*
```
# Additional Context

The MerkleMultiProof uses an algorithm to allow solving of multiple leaves, based on figure 7 of [Improving Stateless Hash-Based Signatures](https://eprint.iacr.org/2017/933.pdf).

## Areas of concern

The main points of concern would be 
- Re-execution
- Re-entrancy
- Loss of funds
- Arbitrary execution
- AFN bypass
- Rate limiting violations
- DoS
  - We are aware of the potential DoS vector of sending large amounts of tokens back and forth. We believe charging tokens bps to be a sufficient disincentive for this attack vector.

## Scoping Details 
```
- If you have a public code repo, please share it here: N/A 
- How many contracts are in scope?: 38
- Total SLoC for these contracts?: With test files: 9833, Without test files: 2985 
- How many external imports are there?: 1: Openzeppelin v4.8.0 
- How many separate interfaces and struct definitions are there for the contracts within scope?: 15 interfaces and ~50 struct definitions
- Does most of your code generally use composition or inheritance?:   
- How many external calls?:  N/A
- What is the overall line coverage percentage provided by your tests?: 97%
- Is there a need to understand a separate part of the codebase / get context in order to audit this part of the protocol?: No  
- Please describe required context:  N/A 
- Does it use an oracle?:  Yes, Chainlink DON
- Does the token conform to the ERC20 standard?:  N/A
- Are there any novel or unique curve logic or mathematical models?: Merkle multi proof
- Does it use a timelock function?:  N/A
- Is it an NFT?: N/A 
- Does it have an AMM?: N/A 
- Is it a fork of a popular project?:   No
- Does it use rollups?:  N/A 
- Is it multi-chain?:  N/A
- Does it use a side-chain?: Yes; this is a cross-chain product. EVM compatible.
```


# Tests

This repository uses Foundry tests that are located in `contracts/test`.
All dependencies have been made part of this repository and no manual installation is required.

If the test produce failures or unexpected results, please ensure your local foundry dependencies are up to date using `foundryup`.
All tests have been successfully run with `nightly-a26edce5d2e1ad28d833328b22e857ecb7075e63`.

To run the test

```
forge test
```

To generate a gas snapshot

```
forge snapshot
```

To generate a code coverage report. Please note that Foundry code coverage doesn't appear to work well with libraries, often reporting zero coverage.

```
forge coverage
```


To install Foundry 

```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

To run Slither

```
slither . --foundry-out-directory artifacts
```
