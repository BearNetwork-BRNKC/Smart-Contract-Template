# BNES-ERC20 Template Detailed Specification

This document provides a detailed explanation and architectural analysis of the BearNetworkChain (BNES) officially recommended ERC20 deployment template (`BNES-ERC20`). Due to its underlying **physics engine alignment (18-decimal precision)** and **post-quantum cryptography (PQC) verification**, developers must strictly adhere to the following specifications.

---

## ⛔ I. Template Scope Restrictions (Applicable / Inapplicable Scenarios)

### ✅ Applicable Only To The Following Scenarios
1. **Native Assets on BNES**: Tokens serving as fundamental value storage and payment settlement.
2. **DeFi Core Liquidity Assets**: Fully compatible with DEX AMM calculations like Uniswap, guaranteeing zero drift.
3. **RWA (Real World Asset) Mapping**: Financial-grade assets requiring extreme security (quantum-resistant) and absolute precision recording.

### ❌ Absolutely Inapplicable To The Following Scenarios

#### ⛔ Inapplicable 1: Non-18 Decimal Tokens
> Traditional tokens such as USDT (6 decimals), WBTC (8 decimals), LINK (18 decimals, but with special calculation logic)

**Technical Reason**: BNES physics engine's information flux scalar ($\Im$) computation baseline is hardlocked at $10^{18}$. When `projectFlux` receives a `value` computed with 6-decimal precision, the engine interprets it as a "severely mismatched magnitude physical signal", producing $10^{12}$-fold drift from the expected chain state root ($\Sigma$), directly triggering **RF-1 Invariance Anomaly**.

**Wrong Example (Forbidden)**:
```solidity
// ❌ Never do this, it will revert all transfers
function decimals() public pure override returns (uint8) {
    return 6; // BNES physics engine will deem this contract's flux illegal
}
```

**Correct Alternative**: If you need to issue a USDT-like stablecoin on BNES, the correct approach is to perform display conversion at the **application layer (frontend / API)**, keeping contracts at 18 decimals:
```
Contract Storage: 1,000,000,000,000,000,000 (1e18 wei)
Frontend Display: 1.000000 USDT (conversion logic in frontend)
```

---

#### ⛔ Inapplicable 2: Resupply Tokens (Rebase Tokens)
> Such as Ampleforth (AMPL), stETH (dynamic balance), compute power tokens

**Technical Reason**: The core mechanism of rebase tokens is to directly modify the `balanceOf` mapping for all addresses **without triggering Transfer events** (via modifying the base coefficient `gonsPerFragment`). This means:
- BNES's `_update` hook will never be triggered
- `projectFlux` will never be called
- The physics engine's $\Sigma$ (total state) will not sync update
- Node "red flag engine" will detect $\Sigma_{\text{balances}} \neq \Gamma_{\text{state}}$, ruling it as **RF-1 Invariance Anomaly**

**Consequence**: Every rebase triggers is equivalent to creating or destroying tokens out of thin air in the physics engine's eyes, and BNES nodes will continuously attempt rollback, ultimately marking the entire contract as a "physical contradiction contract" that cannot trade normally.

---

#### ⛔ Inapplicable 3: Traditional Ethereum Chains or General EVM Chains
> Including Ethereum mainnet, BSC, Polygon, Arbitrum, Optimism, etc.

**Technical Reason**: The `0x0000000000000000000000000000000000000088` within `IBNESPhysicsCore(BNES_CORE)` is a **custom EVM precompile contract** injected by BNES nodes during initialization, with the corresponding Go implementation in the `core/vm/` directory.

On any non-BNES EVM chain, this address at `0x0000000000000000000000000000000000000088` is either an empty address (EOA) or simply has no corresponding precompile logic. The result of calling it:

```
Scenario A (empty address) → CALL returns true, but isCanonicalAuthenticated returns false
                          → onlyQuantumSafe triggers QuantumVulnerabilityDetected()
                          → all transfers permanently revert

Scenario B (address points to other contract) → call unknown contract, behavior completely unpredictable, may cause security vulnerabilities
```

**In short**: deploying this contract on another chain will turn it into a "zombie token" that anyone cannot transfer. Your initial minted amount will be permanently locked.

---

## 🔒 II. Explained Strict Immutable Rules (What Can Be Adjusted / What Cannot)

### 🛑 Strict Immutable Rules
Developers are **strictly forbidden** from modifying the following designs:

#### Immutable Rule 1: `BNES_CORE` Precompile Address
```solidity
// ✅ Correct: Must be hard-coded constant, cannot use variables or constructor params
address public constant BNES_CORE = 0x0000000000000000000000000000000000000088;

// ❌ Dangerous: If made updatable, attackers can replace it with malicious contract
address public bnesCore; // if setter is called by attacker, entire security architecture collapses
```
**Reason**: `BNES_CORE` is the sole bridge between BNES's underlying physics engine (Go layer $\Gamma$ engine) and Rust Halo2 ZK verifier. If replaced by a malicious contract, attackers can make `isCanonicalAuthenticated` always return `true`, turning `projectFlux` into a no-op, effectively bypassing all BNES physical protections.

---

#### Immutable Rule 2: PQC Verification Object Must Be `tx.origin`

```solidity
// ✅ Correct: Verify the ultimate transaction initiator (human wallet)
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ...; }

// ❌ Wrong: Verify current caller (may be DEX Router contract)
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(msg.sender)) { revert ...; }
```

**Why `msg.sender` Cannot Be Used**:

| Call Scenario | `tx.origin` | `msg.sender` |
|---|---|---|
| User direct transfer | User wallet address ✅ | User wallet address ✅ |
| User via Uniswap swap | User wallet address ✅ | **Uniswap Router contract** ❌ |
| User via aggregator 1inch | User wallet address ✅ | **1inch contract** ❌ |
| Flashloan contract call | Flashloan initiator ✅ | **Flashloan contract** ❌ |

Using `msg.sender` will cause all DeFi operations routed through smart contracts to revert, making the token completely unusable in the ecosystem.

---

#### Immutable Rule 3: `projectFlux` Must Cover All Token Flows

```solidity
// ✅ Correct: Immediately map after all balance changes occur
function _update(address from, address to, uint256 value) internal override ... {
    super._update(from, to, value);          // update EVM ledger first
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // then sync physics field
}

// ❌ Dangerous写法 A: call before super._update (ledger not updated yet, physics field syncs early)
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // physics field ahead, causing RF-1
super._update(from, to, value);

// ❌ Dangerous写法 B: only partially map branches (miss mint or burn mappings)
if (from != address(0)) { // only handles transfers, ignores Mint
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
}
// → every Mint will cause Σ and Γ positive drift accumulation, eventually triggering RF-1

// ❌ Dangerous写法 C: pass modified value (precision truncation)
uint256 roundedValue = value / 1e9 * 1e9; // drop last 9 decimals
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, roundedValue); // drift!
```

---

#### Immutable Rule 4: Precision (Decimals) Must Be Fixed At 18

```solidity
// ✅ Correct: don't override decimals(), use ERC20 default of 18
// (no code needed at all; this is the default value)

// ❌ Forbidden: override with any other number
function decimals() public pure override returns (uint8) {
    return 8; // will cause wrong flux magnitude passed to projectFlux, triggering RF-1
}
```

### 🟢 Customizable Parts — Production-Level Implementation Patterns

Developers can freely modify the following three areas based on business requirements and directly apply these examples:

---

#### 📌 Adjustable Item 1: Token Basic Information
Token name, symbol, supply are all passed via constructor, **no Solidity source code modification needed** — just fill parameters in deployment tools (see deployment对照表 in Chapter VI).

---

#### 📌 Adjustable Item 2: Mint & Burn Permissions

**❌ Dangerous Wrong Way (Unlimited Mint, easily inflated by attackers)**
```solidity
// Risk: Owner can mint infinitely, leading to token inflation collapse
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
}
```

**✅ Production Pattern A: Set Maximum Supply Cap (Max Supply Limit)**
```solidity
uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1 billion cap

function mint(address to, uint256 amount) external onlyOwner onlyQuantumSafe {
    // Production point: check against limit before minting
    require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
    _mint(to, amount);
}
```

**✅ Production Pattern B: DAO Multisig Voting Mint (Prevent Single Owner Abuse)**
```solidity
// Requirement: Use with OpenZeppelin Governor governance contract
// Description: minting must pass on-chain governance vote; owner cannot decide unilaterally
// Implementation: remove onlyOwner, use onlyGovernance instead

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

#### 📌 Adjustable Item 3: Business Logic Layer (Transfer Tax / Whitelist / Rate Limiting)

> ⚠️ **BNES Physical Conservation Warning**: Adding transfer tax on BNES is a high-difficulty operation. The core principle is: all tokens flowing out (transfer principal + tax) must be independently mapped twice in the physics engine, and their sum must equal the original `value`, with no wei-level gaps. Otherwise RF-1 invariance anomaly will force revert.

**✅ Production Pattern A: Transfer Tax (Fee on Transfer) — Correct Conservation Implementation**
```solidity
uint256 public feeRate = 100; // 1% = 100 / 10000
address public feeRecipient;

// Override _update, manually split transfer and fee, map twice
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
        super._update(from, to, netAmount);     // actual amount received
        super._update(from, feeRecipient, fee); // tax to fee wallet

        // Physics mapping: split into two, sum equals original value
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, netAmount);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, feeRecipient, fee);
        emit FluxProjected(from, to, netAmount);
        emit FluxProjected(from, feeRecipient, fee);
    } else {
        // Mint (from=0) or burn (to=0): no tax
        super._update(from, to, value);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
        emit FluxProjected(from, to, value);
    }
}
```

**✅ Production Pattern B: Transfer Rate Limiting (Anti-bot / Anti-MEV Front-running)**
```solidity
mapping(address => uint256) private _lastTransferBlock;
uint256 public cooldownBlocks = 1; // Only one transfer per N blocks

function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    // Rate limiting applies only to normal transfers; skip mint/burn
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

**✅ Production Pattern C: Whitelist (Open Specific Addresses for Early Operations at Deployment)**
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
    // Mint and burn are not restricted by whitelist
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

## 🧩 III. Block Function Analysis (Consequences of Including / Excluding)

### Block 1: Core Interface `IBNESPhysicsCore`
```solidity
interface IBNESPhysicsCore {
    function isCanonicalAuthenticated(address user) external view returns (bool);
    function projectFlux(address from, address to, uint256 value) external;
    function verifyPhysicalWitness(bytes calldata proof, bytes32 stateRoot) external view returns (bool);
}
```
* **Function Description**: Declares the interface for communicating with BNES's underlying engine.
* **Consequences of "Not Including"**: The contract becomes a normal EVM token, completely losing physical and quantum protection. Such "fake assets" may not be recognized by frontends or browsers on BNES, and cannot participate in cross-chain or ZK computations.

---

### Block 2: Anti-Quantum Defense Modifier `onlyQuantumSafe`
```solidity
modifier onlyQuantumSafe() {
    if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ... }
    _;
}
```
* **Function Description**: Verifies whether the transaction initiator (`tx.origin`) possesses Dilithium-v3 post-quantum signature. BNES nodes automatically wrap MetaMask transactions into `QuantumEnvelopeTx`, making this transparent to end users.
* **Consequences of "Not Including"**: Contract operations will rely solely on traditional ECDSA, exposing them to future quantum computer breaking attacks.
* **Why Use `tx.origin` Instead of `msg.sender`?**  
  If using `msg.sender`, when a user transacts via DEX (like Uniswap), `msg.sender` becomes the Uniswap contract address. Smart contracts have no quantum signatures, transactions will be intercepted, causing DeFi Lego to collapse. Using `tx.origin` ensures source human wallet security while perfectly compatible with DEXs.

---

### Block 3: Core State Interceptor `_update`
```solidity
function _update(address from, address to, uint256 value) internal override ... onlyQuantumSafe {
    super._update(from, to, value);
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
    emit FluxProjected(from, to, value);
}
```
* **Function Description**: Intercepts all token mint/burn/transfer behaviors and projects 18-decimal values to the physics engine via `projectFlux`.
* **Consequences of "Not Including"**: Contract ledger (EVM State) will decouple from physics engine state (Gamma State). BNES nodes' red flag engine will detect drift between them, ruling it as **RF-1 Physical Invariance Anomaly**, forcing entire transaction revert.

---

### Block 4: Privilege Operation Protection (e.g., `setBlacklist`)
```solidity
function setBlacklist(address account, bool status) external onlyOwner onlyQuantumSafe { ... }
```
* **Function Description**: Not only verifies Owner, but also forces all Owner operations to possess PQC quantum signatures.
* **Consequences of "Not Including"**: Using only `onlyOwner` means if the project's cold wallet or multisig (traditional elliptic curve) is compromised by a quantum computer, attackers can directly seize highest privileges. With this included, even privileged operations reach anti-quantum level.

---

### Block 5: Zero-Knowledge Cross-chain Proof `bridgeMint` — Full Ecosystem Integration Guide
Due to current primary adoption of **community Fox wallet intermediary cross-chain**, `bridgeMint` has been adjusted as an **optional module**.

**tokenBridge_ Handling Principle**:
- Can pass `address(0)` (recommended for community version)
- If future ZK Relayer contract bridging is needed, call `setTokenBridge()` to configure

```solidity
// State tracking: prevent replay of same cross-chain transaction
mapping(bytes32 => bool) public processedBridgeTx;

// Bridge freeze switch: can pause cross-chain in emergencies
bool public bridgePaused = false;

// Events: for backend listening to confirm cross-chain state
event BridgeMinted(address indexed to, uint256 amount, bytes32 indexed srcTxHash);
event BridgeBurned(address indexed from, uint256 amount, bytes32 indexed destChainId);

// ── Cross-chain mint into BNES (Relayer call) ──
function bridgeMint(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash         // source chain's original transaction hash for replay prevention
) external onlyQuantumSafe {
    if (tokenBridge == address(0)) revert BridgeDisabled("Community wallet bridge mode is active");
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed"); // replay prevention

    // ZK circuit verification: ensure Sigma_balances = Gamma_state
    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true; // mark as processed to prevent double replay
    _mint(to, amount);
    emit BridgeMinted(to, amount, srcTxHash);
}

// ── Cross-chain burn from BNES (user call) ──
function bridgeBurn(uint256 amount, bytes32 destChainId) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(amount > 0, "Amount must be > 0");
    _burn(msg.sender, amount);
    // After burning, BNES node's event listener notifies Relayer to unlock assets on target chain
    emit BridgeBurned(msg.sender, amount, destChainId);
}

// ── Emergency bridge pause (owner only) ──
function setBridgePaused(bool paused) external onlyOwner onlyQuantumSafe {
    bridgePaused = paused;
}

// ── Replace bridge Relayer address (owner only, prevent malicious relayer) ──
function setTokenBridge(address newBridge) external onlyOwner onlyQuantumSafe {
    require(newBridge != address(0), "Invalid bridge address");
    tokenBridge = newBridge;
}
```

---

#### 🌉 Integration Scenario A: BNES Community Cross-chain Bridge (ZK Bridge) — Full Production Implementation

This is the standard cross-chain bridging method, working together with bridge Relayer backend services.

```solidity
// ============================================================
// Full ZK cross-chain bridge integration mode
// Architecture: Source Chain → Relayer service → BNES mainnet minting
// Relayer backend generates zkWitness and stateRoot
// ============================================================

// State tracking: prevent replay of same cross-chain transaction
mapping(bytes32 => bool) public processedBridgeTx;

// Bridge freeze switch: can pause cross-chain in emergencies
bool public bridgePaused = false;

// Events: for backend listening to confirm cross-chain state
event BridgeMinted(address indexed to, uint256 amount, bytes32 indexed srcTxHash);
event BridgeBurned(address indexed from, uint256 amount, bytes32 indexed destChainId);

// ── Cross-chain mint into BNES (Relayer call) ──
function bridgeMint(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash         // source chain's original transaction hash for replay prevention
) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed"); // replay prevention

    // ZK circuit verification: ensure Sigma_balances = Gamma_state
    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true; // mark as processed to prevent double replay
    _mint(to, amount);
    emit BridgeMinted(to, amount, srcTxHash);
}

// ── Cross-chain burn from BNES (user call) ──
function bridgeBurn(uint256 amount, bytes32 destChainId) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(amount > 0, "Amount must be > 0");
    _burn(msg.sender, amount);
    // After burning, BNES node's event listener notifies Relayer to unlock assets on target chain
    emit BridgeBurned(msg.sender, amount, destChainId);
}

// ── Emergency bridge pause (owner only) ──
function setBridgePaused(bool paused) external onlyOwner onlyQuantumSafe {
    bridgePaused = paused;
}

// ── Replace bridge Relayer address (owner only, prevent malicious relayer) ──
function setTokenBridge(address newBridge) external onlyOwner onlyQuantumSafe {
    require(newBridge != address(0), "Invalid bridge address");
    tokenBridge = newBridge;
}
```

---

#### 🏦 Integration Scenario B: CEX Centralized Exchange Deposit/Withdrawal

> **Note**: CEXs (like Binance, OKX) do not interact directly with smart contracts. They only need standard ERC20 interfaces (`transfer`, `approve`, `transferFrom`). Your Gamma-ERC20 fully supports this — **no additional contract modifications needed**.

Key CEX integration considerations:

| Item | Description |
|---|---|
| **Deposit Listening** | CEX backend listens to `Transfer(from, to, value)` events; `from` is user address, `to` is exchange hot wallet |
| **Withdrawal Operation** | CEX backend calls `transfer(userAddress, amount)` or `transferFrom` |
| **Precision Confirmation** | BNES enforces 18 decimals; CEX system must set `decimals = 18`, cannot use other values |
| **Blacklist Functionality** | If needed, CEX can request you to lock specific addresses at contract layer using `setBlacklist()` |
| **Gas Fee** | BNES uses fixed low gas price; CEX backend can hard-set `gasPrice = 500000000` (0.5 Gwei) |

**Checklist for confirming token meets CEX listing standards**:
```
✅ decimals() == 18
✅ name() returns correct token name
✅ symbol() returns correct token symbol
✅ totalSupply() != 0
✅ Transfer event follows standard ERC20 format
✅ approve / transferFrom behaves as expected
✅ No reentrancy vulnerabilities (this template already protected)
✅ Contract passed Sourcify open-source verification
```

---

#### 🔄 Integration Scenario C: DEX Decentralized Exchange (Uniswap Compatible Pools)

BNES's Uniswap V2/V3 compatible DEX integration is identical to Ethereum, but precision requirements for physical conservation must be observed.

**✅ Production Pattern: Standard process to establish liquidity pool on DEX**:
```solidity
// The following JavaScript/TypeScript script (not Solidity)
// Assuming use of BNS-DEX (BNES chain's Uniswap V2 fork)

// Step 1: Approve DEX Router for your token
await myToken.approve(BNS_DEX_ROUTER_ADDRESS, ethers.MaxUint256);

// Step 2: Add liquidity (addLiquidity)
// Note: tokenAmount must be a wei value with full 18 decimals
const tokenAmount = ethers.parseUnits('100000', 18);  // 100,000 tokens
const bnsCoinAmount = ethers.parseEther('10');         // 10 BNS native token

await dexRouter.addLiquidityETH(
    myToken.address,
    tokenAmount,
    tokenAmount * 95n / 100n,  // allow 5% slippage
    bnsCoinAmount * 95n / 100n,
    ownerAddress,
    Date.now() + 3600          // 1 hour Deadline
);
```

**⚠️ BNES-specific DEX Transfer Tax Warning**:
```
If your token has "Transfer Tax (Fee on Transfer)",
when adding liquidity, MUST inform DEX to use supportingFeeOnTransfer version:

✅ Correct: addLiquidityETH(...) → no-tax tokens
✅ Correct: addLiquidityETHSupportingFeeOnTransferTokens(...) → tax-bearing tokens

❌ Wrong: using addLiquidityETH for tax-bearing token → mismatched liquidity quantity, transaction reverts
```

---

#### 🌐 Integration Scenario D: Cross-chain DeFi (BNES ↔ Ethereum/BSC, etc.)

Cross-chain DeFi (like cross-chain lending, cross-chain yield farming) requires full ZK Bridge architecture. The flow is:

```
┌─────────────────────────────────────────────────────────────┐
│                 Cross-chain DeFi Architecture Flow            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  BNES Mainnet                        Target Chain (Ethereum / BSC)   │
│  ─────────────────                ────────────────────────          │
│  User calls bridgeBurn()  ────────→ Relayer listens BridgeBurned    │
│         ↓                                  ↓                      │
│  Token burned on BNES     Halo2 ZK generates      Target chain unlock equivalent assets   │
│  projectFlux sync ←─ zkWitness ─────────> DeFi protocol receives assets   │
│  physics field state                        DeFi operations (lending/staking)       │
│                                            ↓                      │
│  bridgeMint() remint ←─ Relayer initiates ── Target chain burn wrapped assets    │
│  verifyPhysicalWitness ZK validation                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**✅ Production Pattern: Cross-chain DeFi integration contract extension template**:
```solidity
// Cross-chain DeFi router interface: allow external DeFi protocols to mint via bridge and operate immediately
interface ICrossChainDeFi {
    function depositAndStake(address token, uint256 amount) external;
}

// Mint then perform DeFi operations atomically (atomic cross-chain DeFi)
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
    _mint(address(this), amount);        // first mint to contract itself
    _approve(address(this), defiProtocol, amount);
    ICrossChainDeFi(defiProtocol).depositAndStake(address(this), amount); // atomically enter DeFi
    emit BridgeMinted(to, amount, srcTxHash);
}
```

---

## 🛡️ IV. Known Vulnerability Defenses & Security Summary (Security & Vulnerabilities)

When deploying and extending the Gamma-ERC20 template, besides BNES-specific physical and quantum protections, traditional EVM smart contract vulnerabilities must also be considered. Below are this template's defenses against known attacks, plus developer notes when extending functionality:

### 1. Reentrancy Attack
* **Vulnerability Description**: Attacker repeatedly calls a contract (e.g., withdrawal function) via Fallback or Receive functions before contract state updates, maliciously draining assets.
* **This Template Defense Status: Immune / Watch When Extending**.
  * **Transfer & Physics Mapping**: This template follows the "Checks-Effects-Interactions" security pattern. In `_update`, lower-level `super._update` first deducts balance and updates ledger state, then calls external interface `projectFlux`, blocking reentrancy conditions.
  * **Extension Development Note**: If you add **ETH/BNES native token withdrawal** functionality later, or must call untrusted external contracts, be sure to import OpenZeppelin's `ReentrancyGuard` and add the `nonReentrant` modifier to that function.

### 2. Replay Attack
* **Vulnerability Description**: Attacker intercepts a valid signature/transaction and resends it on another chain or same contract, causing double deductions or malicious duplicate minting.
* **This Template Defense Status: Fully Immune**.
  * **On-chain replay prevention (ERC20Permit)**: This template inherits `ERC20Permit`, using built-in `Nonces` increment mechanism to ensure each offline authorization signature (EIP-2612) can only be used once, expiring after use.
  * **Cross-chain replay prevention (ZK binding)**: The `bridgeMint` function relies on lower-level `verifyPhysicalWitness`. According to BNES specs, Halo2 ZK proofs will write both `stateRoot` and current `txHash` into proof's public inputs. This guarantees each ZK proof can only be valid once under a "specific state" and "specific transaction", preventing attackers from replaying old ZK credentials for minting duplicates.

### 3. Flash Loan Attack & Oracle Manipulation
* **Vulnerability Description**: Within one transaction, attacker borrows massive funds via flash loan to crash or pump specific token prices, misleading price oracles depending on AMM pool prices (like traditional Uniswap V2 oracle), then profits by repaying.
* **This Template Defense Status: Physics Engine Dimensional Strike (0-Drift)**.
  * On traditional Ethereum, defending against such arbitrage is extremely difficult. But on BNES, `projectFlux` strictly monitors absolute flux at 18-decimal precision. If attacker attempts flash loan-driven complex DEX routing producing any decimal truncation arbitrage (e.g., leveraging division rounding's 1 wei error to free-ride interest), BNES nodes will detect EVM total balance vs physics field inconsistency at transaction settlement, directly triggering **RF-1 Physical Invariance Anomaly** forcing entire flashloan rollback. This makes precision-error-based flashloan arbitrage impossible on BNES.

### 4. Integer Overflow / Underflow
* **Vulnerability Description**: Numerical operations exceed `uint256` upper bound or go below 0, causing value inversion (e.g., 0 - 1 becomes huge positive).
* **This Template Defense Status: Fully Immune**.
  * This template specifies Solidity `^0.8.27` compiler. Since Solidity 0.8.0, compiler-level overflow/underflow safety checks (SafeMath mechanism) are built-in; once an operation exceeds bounds, transaction automatically reverts without needing extra SafeMath library.

### 5. Privilege Escalation / Compromise
* **Vulnerability Description**: Contract admin's private key leaks, leading to malicious upgrades/pauses or user funds frozen by blacklist arbitrarily.
* **This Template Defense Status: Anti-quantum level protection (PQC Trust Root)**.
  * Traditional EVM chains cannot resist future quantum computers breaking ECDSA private keys. All privileged operations in this template (e.g., `setBlacklist`) are protected by `onlyQuantumSafe`. As long as lower-level BNES node's `isCanonicalAuthenticated(tx.origin)` verification fails, even if hackers steal valid traditional admin key and send transactions, they will be intercepted — no privilege can be exercised.

---

> ⚠️ **Developer Critical Warning**:
> When extending business logic in this contract, **do not mix privileged functions without `tx.origin` PQC verification**. Once you add any custom `onlyOwner` or `onlyRole` function (e.g., extra minting, changing bridge address), be sure to synchronously add the `onlyQuantumSafe` modifier. Missing one breaks security closure, making it a quantum attack entry point.

---

## 🚀 V. Deployment & Contract Open-source Verification

After deploying your Gamma-ERC20 contract on BearNetworkChain (BNES) mainnet or testnet, to enable BNScan blockchain explorer and ecosystem users to trust and review your contract source code, we strongly recommend immediately performing open-source verification.

We natively support seamless open-source verification via **Remix IDE** combined with **Sourcify**. Follow these steps:

1. **Install Verification Plugin**: In Remix IDE left sidebar plugin manager, search and enable the **Contract Verification** plugin.
2. **Fill Chain ID**: Enter Contract Verification interface; in network settings' **ChainID** field, accurately input BNES's chain ID: `641230`.
3. **Enter Contract Information**: Fill your recently deployed smart contract address, confirm compilation version and other details.
4. **Select Sourcify Verification**: In verification target options, definitely check **Verify on: Sourcify**. BNES network has deeply integrated decentralized Sourcify open-source verification mechanism.
5. **Submit Verification**: Click verify button; upon successful verification, your contract source code and ABI will immediately sync to BNES ecosystem and be recognized by all nodes and BNScan explorer.

---

## 📜 VI. Full Ready-to-Deploy Source Code Template

Below is complete source code ready to copy-paste directly into Remix for deployment. To maintain BNES physics field's utmost security alignment, **the vast majority of core logic has been hardlocked immutably**.

### ✏️ Users Do Not Need to Modify Source Code — Just Fill in Deployment Tool Parameters:
This template elevates all variable parameters to constructor input fields; the Solidity source itself requires no modifications at all — simply copy-paste.

When deploying, fill these 6 parameters in order:
1. **`name_`**: Token name (e.g., `Bear Network Chain`)
2. **`symbol_`**: Token symbol (e.g., `BRNKC`)
3. **`tokenBridge_`**: Bridge contract address (**can pass `address(0)`**; recommended for community version deployment: 0x0000000000000000000000000000000000000000)
4. **`initialOwner`**: Initial admin address
5. **`recipient`**: Initial token recipient address
6. **`initialSupply`**: Initial issuance amount (industry native standard; caller is responsible for precision conversion — see对照表 below)

### 📊 `initialSupply` Pass Methods Across Different Deployment Tools对照 Table:

> This contract adopts EVM industry native standard: directly uses the raw input value (`uint256`) without any internal precision multiplication. Only this ensures consistent behavior across all deployment tools (Remix / Hardhat / Foundry / scripts), avoiding double-multiplication disasters when "tools have already converted".

| Deployment Tool | `initialSupply` Pass Method | Example for 100,000 Tokens |
|---|---|---|
| **Remix IDE** | Manually enter full precision large number in input field | `100000000000000000000000` |
| **Hardhat (ethers.js v6)** | `ethers.parseUnits('100000', 18)` | Automatically calculates correct large number |
| **Hardhat (ethers.js v5)** | `ethers.utils.parseUnits('100000', 18)` | Automatically calculates correct large number |
| **Foundry script** | `100_000 * 10**18` or `100_000e18` | Automatically calculates correct large number |
| **Generic JS Script** | `BigInt('100000') * BigInt(10**18)` | Automatically calculates correct large number |

> ⚠️ **Remix Newbie Note**: In Remix's `initialSupply` field, copy the format below and replace `100000` with your desired issuance amount then manually calculate 18 decimals (fastest way is to append 18 zeros after your number).
> For example issuing **1,000,000** tokens → input `1000000000000000000000000` (i.e., 1,000,000 followed by 18 zeros).

### Complete Source Code (Fully Ready-to-Deploy — Copy and Paste Directly)

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
    
    address public constant BNES_CORE = 0x0000000000000000000000000000000000000088;
    
    address public tokenBridge;
    mapping(address => bool) private _blacklist;

    error Unauthorized();
    error QuantumVulnerabilityDetected();
    error InvalidAddress();
    error InvalidZKProof();
    error BridgeDisabled();

    event FluxProjected(address indexed from, address indexed to, uint256 value);
    event BlacklistUpdated(address indexed account, bool status);
    event TokenBridgeUpdated(address indexed newBridge);

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
        if (initialOwner == address(0) || recipient == address(0)) revert InvalidAddress();
        
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
        if (tokenBridge == address(0)) revert BridgeDisabled();
        if (msg.sender != tokenBridge) revert Unauthorized();
        if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
            revert InvalidZKProof();
        }
        _mint(to, amount);
    }

    function setTokenBridge(address newBridge) external onlyOwner onlyQuantumSafe {
        tokenBridge = newBridge;
        emit TokenBridgeUpdated(newBridge);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1363) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
```

---
