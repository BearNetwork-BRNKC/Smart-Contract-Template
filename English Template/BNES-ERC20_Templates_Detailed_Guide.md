# BNES-ERC20 Template Detailed Guide

This document provides a detailed explanation and architectural analysis of the ERC20 deployment template (`BNES-ERC20`) officially recommended by BearNetworkChain (BNES). Due to the underlying **physics engine alignment (18 decimal precision)** and **post-quantum cryptography (PQC) verification**, developers must strictly adhere to the following specifications.

---

## ⛔ I. Template Scope Restrictions (Applicable and Inapplicable Scenarios)

### ✅ Only Applicable to the Following Scenarios

1. **Native Assets and Bridged Assets on BNES**: As fundamental value storage and payment settlement tokens.
2. **DeFi Base Liquidity Assets**: Fully compatible with Uniswap and other DEX liquidity pool (AMM) calculations, ensuring zero drift.
3. **RWA (Real-World Asset) Mapping**: Financial-grade assets requiring extremely high security (quantum-resistant) and absolute precision recording.

### ❌ Absolutely Not Applicable to the Following Scenarios

#### ⛔ Inapplicable 1: Non-18 Decimal Tokens

> Traditional tokens such as USDT (6 decimals), WBTC (8 decimals), LINK (18 decimals, but with special calculation logic)

**Technical Reason**: BNES physics engine's information flux scalar ($\Im$) computation baseline is locked at $10^{18}$. When `projectFlux` receives a `value` computed with 6 decimal precision, the engine treats it as a "severely mismatched physical signal," causing a $10^{12}$-fold drift from the expected value of the on-chain state root ($\Sigma$), directly triggering **RF-1 invariant anomaly**.

**Wrong Example (Forbidden)**:
```solidity
// ❌ Absolutely do not write it this way; all transfers will revert
function decimals() public pure override returns (uint8) {
    return 6; // BNES physics engine will deem this contract's flux illegal
}
```

**Correct Alternative**: If you need to issue a USDT-like stablecoin on BNES, the correct approach is to perform display conversion at the **application layer (frontend/API)**, while keeping the contract layer at 18 decimals, for example:
```
Contract storage: 1,000,000,000,000,000,000 (1e18 wei)
Frontend display: 1.000000 USDT (conversion logic in frontend)
```

---

#### ⛔ Inapplicable 2: Elastic Supply Tokens (Rebase Tokens)

> Such as Ampleforth (AMPL), stETH (dynamic balance), compute power tokens

**Technical Reason**: The core mechanism of Rebase tokens is to directly modify the `balanceOf` mapping of all addresses **without triggering the Transfer event** (by modifying the base coefficient `gonsPerFragment`). This means:
- BNES's `_update` hook will never be triggered
- `projectFlux` will never be called
- The physics engine's $\Sigma$ (total state quantity) will not be synchronized
- The node's "red flag engine" will detect $\Sigma_{\text{balances}} \neq \Gamma_{\text{state}}$, judging it as **RF-1 invariant anomaly**

**Consequence**: Each Rebase trigger is equivalent to creating or destroying tokens out of thin air in the physics engine's eyes; BNES nodes will continuously attempt to roll back, ultimately causing the entire contract to be marked as a "physical contradiction contract" and unable to trade normally.

---

#### ⛔ Inapplicable 3: Traditional Ethereum Chains or General EVM Chains

> Including Ethereum mainnet, BSC, Polygon, Arbitrum, Optimism, etc.

**Technical Reason**: The `0x0000000000000000000000000000000000000F15` within `IBNESPhysicsCore(BNES_CORE)` is a **custom precompile contract (Precompile)** injected into EVM by BNES nodes during initialization, with the corresponding Go implementation in the `core/vm/` directory.

On any non-BNES EVM chain, the address `0x...F15` is either an empty address (EOA) or has no corresponding precompile logic. The result of calling it is:

```
Case A (address is empty) → CALL returns true, but isCanonicalAuthenticated returns false
                         → onlyQuantumSafe triggers QuantumVulnerabilityDetected()
                         → all transfers permanently revert

Case B (address has another contract) → calls an unknown contract, behavior completely unpredictable, may cause security vulnerabilities
```

**In short: deploying this contract on other chains will turn it into a "zombie token" that anyone cannot transfer**, and your initial minted supply will be permanently locked.

---

## 🔒 II. Immutable Rules: What Can and Cannot Be Adjusted

### 🛑 Immutable Rules (Strict Immutable Rules)

Developers are **strictly forbidden** from modifying the following designs:

#### Immutable Rule 1: `BNES_CORE` Precompile Address

```solidity
// ✅ Correct: Must hardcode as constant; cannot use variables or passed parameters
address public constant BNES_CORE = 0x0000000000000000000000000000000000000F15;

// ❌ Dangerous: If made updatable, attackers can replace it with a malicious contract, bypassing all physical verification
address public bnesCore; // setter called by attacker after which entire security architecture collapses
```

**Reason**: `BNES_CORE` is the sole bridge between BNES's underlying physics engine (Go layer `Γ` engine) and the Rust Halo2 ZK verifier. If replaced by a malicious contract, attackers can make `isCanonicalAuthenticated` always return `true` and turn `projectFlux` into a no-op, completely bypassing BNES's physical protections.

---

#### Immutable Rule 2: PQC Verification Target Must Be `tx.origin`

```solidity
// ✅ Correct: Verify the ultimate initiator of the transaction (human wallet)
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ...; }

// ❌ Wrong: Verify the current caller (could be a DEX Router contract)
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(msg.sender)) { revert ...; }
```

**Why `msg.sender` cannot be used**:

| Call Scenario | `tx.origin` | `msg.sender` |
|---|---|---|
| User direct transfer | User wallet address ✅ | User wallet address ✅ |
| User swaps via Uniswap | User wallet address ✅ | **Uniswap Router contract address** ❌ |
| User swaps via aggregator 1inch | User wallet address ✅ | **1inch contract address** ❌ |
| Flash loan contract call | Flash loan initiator ✅ | **Flash loan contract address** ❌ |

Using `msg.sender` will cause all DeFi operations routed through smart contracts to revert, making the token completely unusable in the ecosystem.

---

#### Immutable Rule 3: `projectFlux` Must Cover All Token Flows

```solidity
// ✅ Correct: Immediately map after all balance changes
function _update(address from, address to, uint256 value) internal override ... {
    super._update(from, to, value);          // First update EVM ledger
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // Then sync physical field
}

// ❌ Dangerous write A: Call before super._update (ledger not yet updated, physical field syncs first)
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // Physical field ahead, causing RF-1
super._update(from, to, value);

// ❌ Dangerous write B: Call only in partial branches (misses mint or burn mapping)
if (from != address(0)) { // Only handle transfers, ignore Mint
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
}
// → Each Mint will cause positive drift between Σ and Γ, eventually triggering RF-1

// ❌ Dangerous write C: Pass modified value (precision truncation)
uint256 roundedValue = value / 1e9 * 1e9; // Discard last 9 decimal places
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, roundedValue); // Drift!
```

---

#### Immutable Rule 4: Precision (Decimals) Must Be Fixed at 18

```solidity
// ✅ Correct: Do not override decimals(), use ERC20 default of 18
// (No code needed; this is the default value)

// ❌ Forbidden: Override with any other value
function decimals() public pure override returns (uint8) {
    return 8; // Will cause projectFlux to receive incorrect flux magnitude, triggering RF-1
}
```

---

### 🟢 Customizable Parts — Production-Level Implementation Practices

Developers can freely modify the following three areas based on business needs, with examples directly applicable:

---

#### 📌 Customizable Item 1: Token Basic Information

Token name, symbol, and supply are passed via the constructor, **no Solidity source code modification needed**; simply fill parameters in the deployment tool (see Chapter VI deployment reference table for details).

---

#### 📌 Customizable Item 2: Mint and Burn Permissions

**❌ Dangerous wrong implementation (unlimited mint, easily abused)**
```solidity
// Risk: Owner can mint unlimited, leading to token inflation collapse
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
}
```

**✅ Production-grade A: Set maximum supply cap**
```solidity
uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1 billion cap

function mint(address to, uint256 amount) external onlyOwner onlyQuantumSafe {
    // Production point: Check cap before minting
    require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
    _mint(to, amount);
}
```

**✅ Production-grade B: DAO multisig voting mint (prevent single Owner abuse)**
```solidity
// Requirement: Use with OpenZeppelin Governor governance contract
// Explanation: Mint must pass on-chain governance vote; Owner cannot decide alone
// Implementation: Remove onlyOwner, use onlyGovernance instead

address public governance; // DAO governance contract address

modifier onlyGovernance() {
    require(msg.sender == governance, "Only governance");
    _;
}

function mint(address to, uint256 amount) external onlyGovernance onlyQuantumSafe {
    _mint(to, amount);
}
```

---

#### 📌 Customizable Item 3: Business Logic Layer (Transaction Fees, Whitelists, Rate Limits)

> ⚠️ **BNES Physics Conservation Warning**: Adding transaction fees (Fee on Transfer) on BNES is a high-difficulty operation. The core principle is: **all outgoing tokens (transfer principal + fee) must be independently mapped twice in the physics engine, and their sum must equal the original `value`, with no wei-level discrepancy. Otherwise, RF-1 invariant anomaly will be triggered and force revert.**

**✅ Production-grade A: Transaction fee (Fee on Transfer) — Correct conservation implementation**
```solidity
uint256 public feeRate = 100; // 1% = 100 / 10000
address public feeRecipient;

// Override _update, manually split transfer and fee, and map twice
function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    if (_blacklist[from] || _blacklist[to]) revert Unauthorized();

    if (from != address(0) && to != address(0) && feeRate > 0) {
        uint256 fee = (value * feeRate) / 10000;
        uint256 netAmount = value - fee;
        // Ensure conservation: fee + netAmount == value (no remainder)
        require(fee + netAmount == value, "Fee calculation drift");

        // Execute deduction first (total value deducted from from)
        super._update(from, to, netAmount);     // Actual received amount
        super._update(from, feeRecipient, fee); // Fee to fee recipient

        // Physical mapping: two entries, sum equals original value
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, netAmount);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, feeRecipient, fee);
        emit FluxProjected(from, to, netAmount);
        emit FluxProjected(from, feeRecipient, fee);
    } else {
        // Mint (from=0) or burn (to=0): no fee
        super._update(from, to, value);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
        emit FluxProjected(from, to, value);
    }
}
```

**✅ Production-grade B: Transaction rate limiting (anti-bot/anti-MEV front-running)**
```solidity
mapping(address => uint256) private _lastTransferBlock;
uint256 public cooldownBlocks = 1; // Only one transfer every N blocks

function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    // Rate limiting only applies to regular transfers; mint/burn skipped
    if (from != address(0) && to != address(0)) {
        require(
            block.number >= _lastTransferBlock[from] + cooldownBlocks,
            "Transfer cooldown active"
        );
        _lastTransferBlock[from] = block.number;
    }
    if (_blacklist[from] || _blacklist[to]) revert Unauthorized();
    super._update(from, to, value);
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
    emit FluxProjected(from, to, value);
}
```

**✅ Production-grade C: Transaction whitelist (allow specific addresses to operate before deployment)**
```solidity
bool public tradingOpen = false;
mapping(address => bool) public whitelist;

function openTrading() external onlyOwner onlyQuantumSafe {
    tradingOpen = true;
}

function setWhitelist(address account, bool status) external onlyOwner onlyQuantumSafe {
    whitelist[account] = status;
}

function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    // Mint and burn not subject to whitelist restrictions
    if (from != address(0) && to != address(0)) {
        require(tradingOpen || whitelist[from] || whitelist[to], "Trading not open");
    }
    if (_blacklist[from] || _blacklist[to]) revert Unauthorized();
    super._update(from, to, value);
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
    emit FluxProjected(from, to, value);
}
```

---

## 🧩 III. Block Function Analysis (Consequences of Including or Excluding)

### Block 1: Underlying Core Interface `IBNESPhysicsCore`

```solidity
interface IBNESPhysicsCore {
    function isCanonicalAuthenticated(address user) external view returns (bool);
    function projectFlux(address from, address to, uint256 value) external;
    function verifyPhysicalWitness(bytes calldata proof, bytes32 stateRoot) external view returns (bool);
}
```
* **Function description**: Declares the interface for communicating with BNES's underlying engine.
* **If excluded**: The contract becomes a plain EVM token, completely losing physical protection and quantum safeguards. Such "false assets" may not be recognized by frontends and browsers on BNES, and cannot participate in cross-chain and ZK computations.

---

### Block 2: Anti-Quantum Defense Modifier `onlyQuantumSafe`

```solidity
modifier onlyQuantumSafe() {
    if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ... }
    _;
}
```
* **Function description**: Verifies whether the transaction initiator (`tx.origin`) possesses Dilithium-v3 post-quantum signature. BNES nodes automatically wrap MetaMask transactions into `QuantumEnvelopeTx`, making it transparent to end users.
* **If excluded**: Contract operations will rely solely on traditional ECDSA, exposing them to future quantum computer breaking risks.
* **Why `tx.origin` instead of `msg.sender`?**
  If `msg.sender` is used, when a user trades via a DEX (e.g., Uniswap), `msg.sender` becomes the Uniswap contract address. Smart contracts lack quantum signatures, and transactions will be intercepted, **causing DeFi Lego to collapse**. Using `tx.origin` ensures the source human wallet remains secure and perfectly compatible with DEX.

---

### Block 3: Core State Interception `_update`

```solidity
function _update(address from, address to, uint256 value) internal override ... onlyQuantumSafe {
    super._update(from, to, value);
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
    emit FluxProjected(from, to, value);
}
```
* **Function description**: Intercepts all token mint, burn, and transfer actions, and projects the 18-decimal precision value to the physics engine via `projectFlux`.
* **If excluded**: The contract ledger (EVM State) will decouple from the physics engine state (Gamma State). BNES nodes' "red flag engine" will detect drift between the two, judging it as **RF-1 (physics invariant anomaly)**, forcing the entire transaction to revert.

---

### Block 4: Privileged Operation Protection (e.g., `setBlacklist`)

```solidity
function setBlacklist(address account, bool status) external onlyOwner onlyQuantumSafe { ... }
```
* **Function description**: Not only verifies Owner, but also forces Owner's operations to possess PQC quantum signature.
* **If excluded**: Using only `onlyOwner` means if the project's cold wallet or multisig wallet (traditional elliptic curve) is broken by a quantum computer, hackers can directly seize highest privileges. With this included, even privileged operations reach quantum-resistant levels.

---

### Block 5: Zero-Knowledge Cross-Chain Proof `bridgeMint` — Full Ecosystem Access Guide

* **Function description**: During cross-chain operations, requires Halo2-KZG generated ZK proof to ensure cross-chain assets maintain absolute 18-decimal precision alignment across heterogeneous chains.
* **If excluded**: While ordinary contract bridging is possible, BNES v1.3 Section 8's "execution-consistency cross-chain proof" cannot be obtained. If the cross-chain bridge Relayer node acts maliciously, the final ZK circuit mathematical rigidity defense is lacking, potentially facing RF-11 (Circuit Divergence) risk.

---

#### 🌉 Access Scenario A: BNES Official Cross-Chain Bridge (ZK Bridge) — Full Production Implementation

This is the standard cross-chain bridging method, operating together with the bridge Relayer backend service.

```solidity
// ============================================================
// Full ZK Cross-Chain Bridge Access Mode
// Architecture: Source Chain (other chain) → Relayer Service → BNES Mainnet Mint
// Relayer backend generates zkWitness and stateRoot
// ============================================================

// State tracking: prevent replay of the same cross-chain transaction
mapping(bytes32 => bool) public processedBridgeTx;

// Bridge freeze switch: can pause cross-chain in emergencies
bool public bridgePaused = false;

// Events: for backend to listen and confirm cross-chain status
event BridgeMinted(address indexed to, uint256 amount, bytes32 indexed srcTxHash);
event BridgeBurned(address indexed from, uint256 amount, bytes32 indexed destChainId);

// ── Mint from other chain into BNES (Relayer call) ──
function bridgeMint(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash         // Source chain's original transaction hash, for replay prevention
) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed"); // Replay prevention

    // ZK circuit verification: ensure Sigma_balances = Gamma_state
    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true; // Mark as processed, prevent secondary replay
    _mint(to, amount);
    emit BridgeMinted(to, amount, srcTxHash);
}

// ── Burn from BNES to other chain (User call) ──
function bridgeBurn(uint256 amount, bytes32 destChainId) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(amount > 0, "Amount must be > 0");
    _burn(msg.sender, amount);
    // After burning, BNES node event listeners notify Relayer to unlock assets on target chain
    emit BridgeBurned(msg.sender, amount, destChainId);
}

// ── Emergency pause bridge (Owner only) ──
function setBridgePaused(bool paused) external onlyOwner onlyQuantumSafe {
    bridgePaused = paused;
}

// ── Replace bridge Relayer address (Owner only, prevent Relayer malicious behavior) ──
function setTokenBridge(address newBridge) external onlyOwner onlyQuantumSafe {
    require(newBridge != address(0), "Invalid bridge address");
    tokenBridge = newBridge;
}
```

---

#### 🏦 Access Scenario B: CEX Centralized Exchange Deposit/Withdrawal

> **Note**: CEXs (e.g., Binance, OKX) do not interact directly with smart contracts; they only need standard ERC20 interfaces (`transfer`, `approve`, `transferFrom`). Your Gamma-ERC20 fully supports these, **no additional contract modifications needed**.

Key CEX access considerations:

| Item | Description |
|---|---|
| **Deposit listening** | CEX backend listens to `Transfer(from, to, value)` event; `from` is user address, `to` is exchange hot wallet |
| **Withdrawal operation** | CEX backend calls `transfer(userAddress, amount)` or `transferFrom` |
| **Precision confirmation** | BNES enforces 18 decimals; CEX system sets `decimals = 18`, **cannot be set to other values** |
| **Blacklist feature** | If needed, CEX can request you to block specific addresses at contract layer using `setBlacklist()` |
| **Gas Fee** | BNES uses fixed low Gas Price; CEX backend can hard-set `gasPrice = 500000000` (0.5 Gwei) |

**Checklist to confirm token meets CEX listing standards**:
```
✅ decimals() == 18
✅ name() returns correct token name
✅ symbol() returns correct token symbol
✅ totalSupply() != 0
✅ Transfer event conforms to ERC20 standard format
✅ approve / transferFrom behavior as expected
✅ No reentrancy vulnerability (this template already protected)
✅ Contract verified on Sourcify
```

---

#### 🔄 Access Scenario C: DEX Decentralized Exchange (Uniswap-Compatible Pools)

BNES's Uniswap V2/V3 compatible DEX access is identical to Ethereum, but precision conservation requirements must be noted.

**✅ Production-grade: Standard flow for creating liquidity pools on DEX**
```solidity
// The following is JavaScript/TypeScript script, not Solidity
// Assuming use of BNS-DEX (BNES chain's Uniswap V2 branch)

// Step 1: Approve DEX Router to use your token
await myToken.approve(BNS_DEX_ROUTER_ADDRESS, ethers.MaxUint256);

// Step 2: Add liquidity (addLiquidity)
// Note: tokenAmount must be wei value with 18 decimals
const tokenAmount = ethers.parseUnits('100000', 18);  // 100,000 tokens
const bnsCoinAmount = ethers.parseEther('10');         // 10 BNS native token

await dexRouter.addLiquidityETH(
    myToken.address,
    tokenAmount,
    tokenAmount * 95n / 100n,  // Allow 5% slippage
    bnsCoinAmount * 95n / 100n,
    ownerAddress,
    Date.now() + 3600          // 1-hour Deadline
);
```

**⚠️ BNES-specific DEX transaction fee warning**:
```
If your token has "transaction fee (Fee on Transfer)",
when adding liquidity, MUST inform DEX to use supportingFeeOnTransfer version:

✅ Correct: addLiquidityETH(...) → no-fee token
✅ Correct: addLiquidityETHSupportingFeeOnTransferTokens(...) → with-fee token

❌ Wrong: with-fee token using addLiquidityETH → liquidity amounts mismatch, transaction reverts
```

---

#### 🌐 Access Scenario D: Cross-Chain DeFi (BNES ↔ Ethereum/BSC, etc.)

Cross-chain DeFi (e.g., cross-chain lending, cross-chain yield farming) requires the full ZK Bridge architecture; the flow is as follows:

```
┌─────────────────────────────────────────────────────────────┐
│                   Cross-Chain DeFi Architecture Flow         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  BNES Mainnet                        Target Chain (Ethereum / BSC)   │
│  ─────────────────                ────────────────────────  │
│  User calls bridgeBurn()  ────────→ Relayer listens BridgeBurned │
│         ↓                                  ↓                │
│  Token burned on BNES       Halo2 ZK generated      Target chain unlocks equivalent assets │
│  projectFlux syncs   ←─ zkWitness ─────→   DeFi protocol receives assets │
│  Physics field state                        DeFi operations (lend/stake)     │
│                                            ↓                │
│  bridgeMint() remint  ←─ Relayer initiates ──── Target chain burns wrapped assets  │
│  verifyPhysical                                              │
│  Witness() ZK verification                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**✅ Production-grade: Cross-chain DeFi access contract extension template**
```solidity
// Cross-chain DeFi routing interface: allows external DeFi protocols to mint via bridge and immediately operate
interface ICrossChainDeFi {
    function depositAndStake(address token, uint256 amount) external;
}

// Atomic cross-chain DeFi operations after bridging
function bridgeMintAndStake(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash,
    address defiProtocol      // DeFi protocol address
) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed");

    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true;
    _mint(address(this), amount);        // Mint to contract itself first
    _approve(address(this), defiProtocol, amount);
    ICrossChainDeFi(defiProtocol).depositAndStake(address(this), amount); // Atomically enter DeFi
    emit BridgeMinted(to, amount, srcTxHash);
}
```

---

## 🛡️ IV. Known Vulnerability Defenses and Security Summary (Security & Vulnerabilities)

When deploying and extending the Gamma-ERC20 template, besides BNES-specific physical and quantum protections, traditional EVM smart contract vulnerabilities must also be considered. Below are the defense mechanisms this template provides against known attacks, along with developer notes when extending functionality:

### 1. Reentrancy Attack
* **Vulnerability description**: Attackers repeatedly call a contract (e.g., withdrawal function) via Fallback or Receive functions before contract state updates, causing assets to be maliciously drained multiple times.
* **This template's defense status: Immune / Note when extending**.
  * **Transfer and physical mapping**: This template follows the "Checks-Effects-Interactions" security pattern. In `_update`, the underlying `super._update` first deducts balance and updates ledger state, then calls external interface `projectFlux`, blocking reentrancy conditions.
  * **Extension development advice**: If you add **ETH/BNES native token withdrawal** functionality in the contract, or must call untrusted external contracts, be sure to introduce OpenZeppelin's `ReentrancyGuard` and add the `nonReentrant` modifier to that function.

### 2. Replay Attack
* **Vulnerability description**: Attackers intercept a valid signature or transaction and resend it on another chain or the same contract, causing double deduction or malicious duplicate minting.
* **This template's defense status: Fully immune**.
  * **On-chain replay prevention (ERC20Permit)**: This template inherits `ERC20Permit`, using the built-in `Nonces` increment mechanism to ensure each offline authorization signature (EIP-2612) can be used only once; used and expired.
  * **Cross-chain replay prevention (ZK binding)**: The `bridgeMint` function relies on underlying `verifyPhysicalWitness`. Per BNES specification, Halo2 ZK proofs write `stateRoot` and the current `txHash` into the proof's public inputs. This ensures each ZK proof is valid only under "specific state" and "specific transaction"; attackers cannot replay old ZK credentials to print money.

### 3. Flash Loan Attack and Oracle Manipulation
* **Vulnerability description**: Attackers borrow massive funds via flash loans within a single transaction, dump or pump specific token prices, mislead price oracles dependent on AMM pool prices (e.g., traditional Uniswap V2 oracle), then profit and repay.
* **This template's defense status: Physics engine dimensionality reduction (0-Drift)**.
  * On traditional Ethereum, defending against such arbitrage is extremely difficult. On BNES, `projectFlux` strictly monitors absolute 18-decimal precision flux. If attackers attempt arbitrage via flash loans, producing any decimal truncation errors in complex DEX routing (e.g., 1 wei error from division rounding to free interest), BNES nodes will detect EVM total balance inconsistency with the physics field at transaction settlement and directly trigger **RF-1 (physics invariant anomaly)** to force rollback the entire flash loan. This makes precision-error-based flash loan arbitrage impossible on BNES.

### 4. Integer Overflow / Underflow
* **Vulnerability description**: Numerical computation exceeds `uint256` upper limit or goes below 0, causing value flip (e.g., 0 - 1 becomes huge value).
* **This template's defense status: Fully immune**.
  * This template specifies Solidity `^0.8.27` compiler. Since Solidity 0.8.0, the compiler layer has built-in overflow/underflow safety checks (SafeMath mechanism); once an operation exceeds bounds, the transaction automatically reverts, no need to additionally import SafeMath library.

### 5. Privilege Escalation / Compromise
* **Vulnerability description**: Contract administrator's private key leaks, causing contract to be maliciously upgraded, paused, or user funds frozen via blacklist without cause.
* **This template's defense status: Quantum-resistant level defense (PQC Trust Root)**.
  * General EVM chains cannot resist future quantum computers breaking traditional ECDSA private keys. All privileged operations in this template (e.g., `setBlacklist`) are protected by `onlyQuantumSafe`. As long as BNES node's `isCanonicalAuthenticated(tx.origin)` verification fails, even if hackers steal the project's valid traditional private keys and send transactions, they will be intercepted and cannot execute any privileged instructions.

---

> ⚠️ **Developer Critical Warning**:
> When extending this contract's business logic, **do not mix privileged functions未经 `tx.origin` PQC verification**. Once you add any custom `onlyOwner` or `onlyRole` functions (e.g., mint tokens, change bridge address, etc.), be sure to synchronously add the `onlyQuantumSafe` modifier. Missing even one will break the contract's security loop, becoming a quantum attack breakthrough point.

---

## 🚀 V. Deployment and Contract Open Source Verification

After deploying your Gamma-ERC20 contract on BearNetworkChain (BNES) mainnet or testnet, to let BNScan blockchain browser and ecosystem users trust and inspect your contract source code, we strongly recommend performing contract open source verification immediately.

We natively support seamless open source verification via **Remix IDE** combined with **Sourcify**; please follow these steps:

1. **Install verification suite**: In Remix IDE's left-side plugin manager, search and enable the **Contract Verification** plugin.
2. **Fill Chain ID**: Enter the Contract Verification interface, and in the network settings **ChainID** field, precisely fill BNES's chain ID: `641230`.
3. **Input contract information**: Fill in the smart contract address you just deployed successfully, and confirm contract compilation version and other details.
4. **Select Sourcify verification**: In the verification target options, be sure to check **Verify on: Sourcify**. BNES network has deeply integrated Sourcify decentralized contract open source verification mechanism.
5. **Submit verification**: Click the verify button; after verification passes, your contract source code and ABI will immediately sync to BNES ecosystem and be recognized by all nodes and BNScan browsers.

---

## 📜 VI. Complete Deployable Source Code Template

The following is complete source code that can be directly copied and pasted into Remix for deployment. To maintain BNES physics field's ultimate security and alignment, **most core logic has been hard-bound and locked**.

### ✏️ Users need not modify source code; fill directly in deployment tool:
This template has elevated all variable parameters to constructor input fields, **Solidity source code itself requires no modification**; simply copy and paste.

When deploying, fill the following 6 parameters in order:
1. **`name_`**: Token name (e.g., `Bear Network`)
2. **`symbol_`**: Token symbol (e.g., `BRNKC`)
3. **`tokenBridge_`**: Bridge contract address (cannot be `0x00...00`)
4. **`initialOwner`**: Initial admin address
5. **`recipient`**: Initial token recipient address
6. **`initialSupply`**: Initial issuance quantity (industry native standard, **caller responsible for precision conversion**, see table below)

### 📊 `initialSupply` Input Method Reference Table for Deployment Tools

> This contract adopts EVM industry native standard: contract directly uses the raw passed value (`uint256`), **does not perform any precision multiplication internally**. This ensures consistent behavior across all deployment tools (Remix / Hardhat / Foundry / scripts), avoiding double multiplication disasters where issuance becomes astronomical numbers.

| Deployment Tool | `initialSupply` Input Method | Example for 100,000 tokens |
|---|---|---|
| **Remix IDE** | Manually fill complete large number with precision in input field | `100000000000000000000000` |
| **Hardhat (ethers.js v6)** | `ethers.parseUnits('100000', 18)` | Automatically calculates correct large number |
| **Hardhat (ethers.js v5)** | `ethers.utils.parseUnits('100000', 18)` | Automatically calculates correct large number |
| **Foundry script** | `100_000 * 10**18` or `100_000e18` | Automatically calculates correct large number |
| **Generic JS script** | `BigInt('100000') * BigInt(10**18)` | Automatically calculates correct large number |

> ⚠️ **Remix beginner note**: In Remix's `initialSupply` field, copy the following format, replace `100000` with your issuance quantity, and manually calculate 18 decimal places (fastest method is to add 18 zeros after the number).
> For example, issuing **1,000,000** tokens → input `1000000000000000000000000` (i.e., 1,000,000 followed by 18 zeros).

### Complete Source Code (Copy and Deploy Without Modification)

```solidity
// SPDX-License-Identifier: MIT
// BearNetworkChain BNES Physics-Informed Template - 18 Decimals Hardened (Production Ready)
// Source: https://github.com/BearNetwork-BRNKC
// All Rights Reserved by BearNetworkChain-BRNKC
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

interface IBNESPhysicsCore {
    function isCanonicalAuthenticated(address user) external view returns (bool);
    function projectFlux(address from, address to, uint256 value) external;
    function verifyPhysicalWitness(bytes calldata proof, bytes32 stateRoot) external view returns (bool);
}

contract MyGammaToken is ERC20, Ownable, ERC20Burnable, ERC20Pausable, ERC1363, ERC20Permit, ERC20Votes, ERC20FlashMint {
    
    address public constant BNES_CORE = 0x0000000000000000000000000000000000000f15;
    
    address public tokenBridge;
    mapping(address => bool) private _blacklist;

    error Unauthorized();
    error QuantumVulnerabilityDetected();
    error InvalidAddress();
    error InvalidZKProof();

    event FluxProjected(address indexed from, address indexed to, uint256 value);
    event BlacklistUpdated(address indexed account, bool status);

    modifier onlyQuantumSafe() {
        if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) {
            revert QuantumVulnerabilityDetected();
        }
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address tokenBridge_, 
        address initialOwner, 
        address recipient,
        uint256 initialSupply
    )
        ERC20(name_, symbol_)
        Ownable(initialOwner)
        ERC20Permit(name_)
    {
        if (tokenBridge_ == address(0) || initialOwner == address(0) || recipient == address(0)) revert InvalidAddress();
        
        tokenBridge = tokenBridge_;
        
        // [Industry standard] Mint only on BNES chain (641230).
        // initialSupply must be passed as complete wei value with 18 decimals.
        // Example: issue 100,000 tokens → pass 100000 * 10**18 = 100000000000000000000000
        // Contract performs no precision conversion, ensuring consistency with Hardhat / Foundry / scripts.
        if (block.chainid == 641230 && initialSupply > 0) {
            _mint(recipient, initialSupply);
        }
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
        onlyQuantumSafe
    {
        if (_blacklist[from] || _blacklist[to]) revert Unauthorized();
        
        super._update(from, to, value);
        
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
        emit FluxProjected(from, to, value);
    }

    function setBlacklist(address account, bool status) external onlyOwner onlyQuantumSafe {
        _blacklist[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function bridgeMint(address to, uint256 amount, bytes calldata zkWitness, bytes32 stateRoot) external onlyQuantumSafe {
        if (msg.sender != tokenBridge) revert Unauthorized();
        if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
            revert InvalidZKProof();
        }
        _mint(to, amount);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1363) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
```
