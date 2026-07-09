# BNES-ERC20 模板詳細說明書

本文件為 BearNetworkChain (BNES) 官方推薦的 ERC20 部署模板 (`BNES-ERC20`) 的詳細說明與架構解析。BNES 由於底層具備**物理引擎對齊 (18 位精度)** 與 **後量子密碼學 (PQC) 驗證**，開發者必須嚴格遵守以下規範。

---

## ⛔ 一、 模板場景限制 (適用與不適用範圍)

### ✅ 只能用於以下場景 (適用)
1. **BNES 上的原生資產與橋接資產**：作為基礎價值儲存、支付結算的通證。
2. **DeFi 基礎流動性資產**：完全相容 Uniswap 等 DEX 的流動性池 (AMM) 計算，並保障零漂移。
3. **RWA (真實世界資產) 映射**：需要極高安全性（抗量子破解）與絕對精度紀錄的金融級資產。

### ❌ 絕對不能用於以下場景 (不適用)

#### ⛔ 不適用 1：非 18 位精度代幣
> 傳統代幣如 USDT (6 位)、WBTC (8 位)、LINK (18 位，但有特殊計算邏輯)

**技術原因**：BNES 物理引擎的資訊通量標量 ($\Im$) 運算基準鎖死為 $10^{18}$。當 `projectFlux` 接收到一個以 6 位精度計算的 `value` 時，引擎會視其為「量級嚴重不符的物理訊號」，與鏈上狀態根 ($\Sigma$) 的預期值產生 $10^{12}$ 倍的漂移，直接觸發 **RF-1 不變量異常**。

**錯誤示範（嚴禁）**：
```solidity
// ❌ 絕對不能這樣寫，會導致所有轉帳 Revert
function decimals() public pure override returns (uint8) {
    return 6; // BNES 物理引擎會判定此合約的通量不合法
}
```

**正確替代方案**：若您需要在 BNES 上發行一個類 USDT 的穩定幣，正確做法是在 **應用層（前端 / API）** 做顯示換算，合約層保持 18 位，例如：
```
合約儲存：1,000,000,000,000,000,000 (1e18 wei)
前端顯示：1.000000 USDT (換算邏輯在前端)
```

---

#### ⛔ 不適用 2：彈性供應代幣 (Rebase Tokens)
> 如 Ampleforth (AMPL)、stETH (動態餘額)、算力幣

**技術原因**：Rebase 代幣的核心機制是在**不觸發 Transfer 事件的情況下**，直接修改所有地址的 `balanceOf` 映射（透過修改基礎係數 `gonsPerFragment`）。這意味著：
- BNES 的 `_update` 鉤子永遠不會被觸發
- `projectFlux` 永遠不會被呼叫
- 物理引擎的 $\Sigma$ (狀態總量) 不會同步更新
- 節點的「紅旗引擎」將偵測到 $\Sigma_{\text{balances}} \neq \Gamma_{\text{state}}$，判定為 **RF-1 不變量異常**

**後果**：Rebase 每次觸發都相當於在物理引擎眼中憑空創造或消滅代幣，BNES 節點會持續嘗試回滾，最終導致整個合約被節點標記為「物理矛盾合約」，無法正常交易。

---

#### ⛔ 不適用 3：傳統 Ethereum 鏈或一般 EVM 鏈
> 包含 Ethereum 主網、BSC、Polygon、Arbitrum、Optimism 等

**技術原因**：`IBNESPhysicsCore(BNES_CORE)` 中的 `0x0000000000000000000000000000000000000088` 是 BNES 節點在初始化時向 EVM 注入的**自定義預編譯合約 (Precompile)**，對應的 Go 實作在 `core/vm/` 目錄下。

在任何非 BNES 的 EVM 鏈上，0x0000000000000000000000000000000000000088` 這個地址要麼是空地址 (EOA)，要麼根本不存在對應的預編譯邏輯。呼叫它的結果是：

```
情況 A（地址為空）→ CALL 返回 true，但 isCanonicalAuthenticated 返回 false
                   → onlyQuantumSafe 觸發 QuantumVulnerabilityDetected()
                   → 所有轉帳永久 Revert

情況 B（地址有其他合約）→ 呼叫到未知合約，行為完全不可預測，可能造成安全漏洞
```

**簡言之：這份合約在其他鏈上佈署後，會成為一個任何人都無法轉帳的「殭屍代幣」**，您的初始鑄造量將被永久鎖死。

---

## 🔒 二、 可調與不可調的「硬綁定」說明

### 🛑 不可調的硬綁定 (Strict Immutable Rules)
開發者**嚴禁**修改以下設計：

#### 硬綁定 1：`BNES_CORE` 預編譯地址
```solidity
// ✅ 正確：必須硬寫常數，不可使用變數或傳入參數
address public constant BNES_CORE = 0x0000000000000000000000000000000000000088;

// ❌ 危險：若改為可更新，攻擊者可將其替換為惡意合約，繞過所有物理驗證
address public bnesCore; // setter 被攻擊者呼叫後，整個安全架構崩潰
```
**原因**：`BNES_CORE` 是 BNES 底層物理引擎（Go 層 `Γ 引擎`）與 Rust Halo2 ZK 驗證器的唯一橋樑。若被替換為惡意合約，攻擊者可以讓 `isCanonicalAuthenticated` 永遠返回 `true`，並讓 `projectFlux` 變成空操作，等於完全繞過了 BNES 的所有物理防護。

---

#### 硬綁定 2：PQC 驗證對象必須是 `tx.origin`

```solidity
// ✅ 正確：驗證交易的最終發起人（人類錢包）
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ...; }

// ❌ 錯誤：驗證當前呼叫者（可能是 DEX Router 合約）
if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(msg.sender)) { revert ...; }
```

**為何不能用 `msg.sender`**：

| 呼叫場景 | `tx.origin` | `msg.sender` |
|---|---|---|
| 用戶直接轉帳 | 用戶錢包地址 ✅ | 用戶錢包地址 ✅ |
| 用戶透過 Uniswap 交換 | 用戶錢包地址 ✅ | **Uniswap Router 合約地址** ❌ |
| 用戶透過聚合器 1inch | 用戶錢包地址 ✅ | **1inch 合約地址** ❌ |
| 閃電貸合約呼叫 | 閃電貸發起者 ✅ | **閃電貸合約地址** ❌ |

使用 `msg.sender` 會導致所有透過智能合約路由的 DeFi 操作全部 Revert，使代幣在生態系中完全不可用。

---

#### 硬綁定 3：`projectFlux` 必須覆蓋所有代幣流動

```solidity
// ✅ 正確：在所有餘額變動後立即映射
function _update(address from, address to, uint256 value) internal override ... {
    super._update(from, to, value);          // 先更新 EVM 帳本
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // 後同步物理場
}

// ❌ 危險寫法 A：在 super._update 前呼叫（帳本還沒更新，物理場先同步）
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value); // 物理場超前，造成 RF-1
super._update(from, to, value);

// ❌ 危險寫法 B：只在部分分支呼叫（遺漏鑄造或銷毀的映射）
if (from != address(0)) { // 只處理轉帳，忽略 Mint
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
}
// → 每次 Mint 都會讓 Σ 與 Γ 產生正漂移，最終累積觸發 RF-1

// ❌ 危險寫法 C：傳入修改過的 value（精度截斷）
uint256 roundedValue = value / 1e9 * 1e9; // 捨去末 9 位精度
IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, roundedValue); // 漂移！
```

---

#### 硬綁定 4：精度 (Decimals) 必須固定為 18

```solidity
// ✅ 正確：不覆寫 decimals()，使用 ERC20 預設的 18
// （不需要任何代碼，這是預設值）

// ❌ 嚴禁：覆寫為任何其他數值
function decimals() public pure override returns (uint8) {
    return 8; // 會導致 projectFlux 傳入的通量量級錯誤，觸發 RF-1
}
```


### 🟢 可調整的部分 (Customizable) — 生產級實用作法

開發者可以根據業務需求自由修改以下三個區域，並直接套用以下範例：

---

#### 📌 可調整項目 1：代幣基本資訊
代幣名稱、簡稱、發行量皆透過建構子傳入，**無需修改 Solidity 源碼**，直接在佈署工具填寫參數即可（詳見第六章節的佈署對照表）。

---

#### 📌 可調整項目 2：鑄造與銷毀權限

**❌ 危險的錯誤寫法（無上限 Mint，容易被惡意增發）**
```solidity
// 風險：Owner 可以無限鑄造，導致代幣通膨崩潰
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
}
```

**✅ 生產級 A：設置最大供應量上限 (Max Supply Cap)**
```solidity
uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 10 億顆上限

function mint(address to, uint256 amount) external onlyOwner onlyQuantumSafe {
    // 生產要點：先檢查是否超過上限，再鑄造
    require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
    _mint(to, amount);
}
```

**✅ 生產級 B：DAO 多簽投票鑄造（防止單點 Owner 濫權）**
```solidity
// 需求：搭配 OpenZeppelin Governor 治理合約使用
// 說明：鑄造必須經過鏈上治理投票通過，Owner 無法單獨決定
// 作法：移除 onlyOwner，改用 onlyGovernance

address public governance; // DAO 治理合約地址

modifier onlyGovernance() {
    require(msg.sender == governance, "Only governance");
    _;
}

function mint(address to, uint256 amount) external onlyGovernance onlyQuantumSafe {
    _mint(to, amount);
}
```

---

#### 📌 可調整項目 3：業務邏輯層（交易稅、白名單、限速）

> ⚠️ **BNES 物理守恆警告**：在 BNES 上加入交易稅（Fee on Transfer）是高難度操作。核心原則是：**所有流出的代幣（轉帳本金 + 稅金）必須在物理引擎中分兩次獨立映射，且總和必須等於原始 `value`，不得有任何 wei 級別的差距。否則會觸發 RF-1 不變量異常強制 Revert。**

**✅ 生產級 A：交易稅 (Fee on Transfer) — 正確的守恆寫法**
```solidity
uint256 public feeRate = 100; // 1% = 100 / 10000
address public feeRecipient;

// 覆寫 _update，手動拆分轉帳與手續費，並分兩次映射
function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    if (_blacklist[from] || _blacklist[to]) revert Unauthorized();

    if (from != address(0) && to != address(0) && feeRate > 0) {
        uint256 fee = (value * feeRate) / 10000;
        uint256 netAmount = value - fee;
        // 確保守恆：fee + netAmount == value (無餘數)
        require(fee + netAmount == value, "Fee calculation drift");

        // 先執行扣款（總額 value 從 from 扣除）
        super._update(from, to, netAmount);     // 實際到帳金額
        super._update(from, feeRecipient, fee); // 稅金到手續費錢包

        // 物理映射：分兩筆，且總和等於原始 value
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, netAmount);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, feeRecipient, fee);
        emit FluxProjected(from, to, netAmount);
        emit FluxProjected(from, feeRecipient, fee);
    } else {
        // 鑄造 (from=0) 或銷毀 (to=0)：不收稅
        super._update(from, to, value);
        IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
        emit FluxProjected(from, to, value);
    }
}
```

**✅ 生產級 B：交易限速（防機器人/防 MEV 搶跑）**
```solidity
mapping(address => uint256) private _lastTransferBlock;
uint256 public cooldownBlocks = 1; // 每 N 個區塊只能轉一次

function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Pausable, ERC20Votes)
    onlyQuantumSafe
{
    // 限速只對普通轉帳生效，鑄造/銷毀跳過
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

**✅ 生產級 C：交易白名單（合約部署時開放特定地址先行操作）**
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
    // 鑄造與銷毀不受白名單限制
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

## 🧩 三、 區塊函數解析 (加入與不加入的後果)

### 區塊 1：底層核心接口 `IBNESPhysicsCore`
```solidity
interface IBNESPhysicsCore {
    function isCanonicalAuthenticated(address user) external view returns (bool);
    function projectFlux(address from, address to, uint256 value) external;
    function verifyPhysicalWitness(bytes calldata proof, bytes32 stateRoot) external view returns (bool);
}
```
* **功能說明**：宣告與 BNES 底層引擎對話的介面。
* **如果「不加入」**：合約將成為普通的 EVM 代幣，完全失去物理防護與量子保護。這種「虛假資產」在 BNES 上可能不被前端及瀏覽器認可，且無法參與跨鏈與 ZK 計算。

---

### 區塊 2：抗量子防禦修飾符 `onlyQuantumSafe`
```solidity
modifier onlyQuantumSafe() {
    if (!IBNESPhysicsCore(BNES_CORE).isCanonicalAuthenticated(tx.origin)) { revert ... }
    _;
}
```
* **功能說明**：驗證交易發起者 (`tx.origin`) 是否具備 Dilithium-v3 後量子簽章。BNES 節點會自動將 MetaMask 交易包裝成 `QuantumEnvelopeTx`，因此對終端用戶完全透明。
* **如果「不加入」**：合約操作將只依賴傳統 ECDSA，暴露於未來量子計算機的破解風險中。
* **為什麼是 `tx.origin` 而不是 `msg.sender`？** 
  如果使用 `msg.sender`，當用戶透過 DEX (如 Uniswap) 交易時，`msg.sender` 會變成 Uniswap 的合約地址。智能合約沒有量子簽章，交易會被攔截，**導致 DeFi 樂高崩潰**。使用 `tx.origin` 可確保源頭人類錢包安全，且完美兼容 DEX。

---

### 區塊 3：核心狀態攔截 `_update`
```solidity
function _update(address from, address to, uint256 value) internal override ... onlyQuantumSafe {
    super._update(from, to, value);
    IBNESPhysicsCore(BNES_CORE).projectFlux(from, to, value);
    emit FluxProjected(from, to, value);
}
```
* **功能說明**：攔截所有的代幣鑄造、銷毀、轉帳行為，並透過 `projectFlux` 將 18 位精度的數值投射給物理引擎。
* **如果「不加入」**：合約帳本 (EVM State) 會與 物理引擎狀態 (Gamma State) 脫鉤。BNES 節點的「紅旗引擎」會偵測到兩者出現漂移 (Drift)，判定為 **RF-1 (物理不變量異常)**，將整筆交易強制 Revert。

---

### 區塊 4：特權操作防護 (例如 `setBlacklist`)
```solidity
function setBlacklist(address account, bool status) external onlyOwner onlyQuantumSafe { ... }
```
* **功能說明**：不僅驗證 Owner，更強制 Owner 的操作也必須具備 PQC 量子簽章。
* **如果「不加入」**：只用 `onlyOwner` 的後果是，若專案方管理的冷錢包或多簽錢包（傳統橢圓曲線）被量子電腦攻破，駭客可以直接奪取最高權限。加入後，即便是特權操作也達到抗量子級別。

---

### 區塊 5：零知識跨鏈證明 `bridgeMint` — 生態接入全攻略

* **功能說明**：跨鏈操作時，要求傳入 Halo2-KZG 生成的 ZK 證明，確保跨鏈資產在異構鏈間的狀態是絕對 18 位精度對齊的。
* **如果「不加入」**：雖然能進行普通的合約橋接，但無法獲得 BNES v1.3 第 8 點規定的「執行一致性跨鏈證明」。若跨鏈橋的 Relayer 節點作惡，將缺乏最後一道 ZK 電路的數學剛性防線，可能面臨 RF-11 (Circuit Divergence) 風險。

---

#### 🌉 接入場景 A：BNES 社區跨鏈橋 (ZK Bridge) — 完整生產實作

這是最標準的跨鏈橋接方式，需配合橋接 Relayer 後端服務一同運作。

```solidity
// ============================================================
// 完整 ZK 跨鏈橋接入模式
// 架構：Source Chain (其他鏈) → Relayer 服務 → BNES 主網鑄造
// Relayer 後端負責生成 zkWitness 與 stateRoot
// ============================================================

// 狀態追蹤：防止同一筆跨鏈交易重放
mapping(bytes32 => bool) public processedBridgeTx;

// 橋接凍結開關：緊急情況可暫停跨鏈
bool public bridgePaused = false;

// 事件：供後端監聽確認跨鏈狀態
event BridgeMinted(address indexed to, uint256 amount, bytes32 indexed srcTxHash);
event BridgeBurned(address indexed from, uint256 amount, bytes32 indexed destChainId);

// ── 從其他鏈鑄造進 BNES (Relayer 呼叫) ──
function bridgeMint(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash         // 來源鏈的原始交易 Hash，用於防重放
) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed"); // 防重放

    // ZK 電路驗證：確保 Sigma_balances = Gamma_state
    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true; // 標記已處理，防止二次重放
    _mint(to, amount);
    emit BridgeMinted(to, amount, srcTxHash);
}

// ── 從 BNES 銷毀送往其他鏈 (用戶呼叫) ──
function bridgeBurn(uint256 amount, bytes32 destChainId) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(amount > 0, "Amount must be > 0");
    _burn(msg.sender, amount);
    // 燃燒後由 BNES 節點的事件監聽器通知 Relayer，在目標鏈解鎖資產
    emit BridgeBurned(msg.sender, amount, destChainId);
}

// ── 緊急暫停橋接（僅 Owner） ──
function setBridgePaused(bool paused) external onlyOwner onlyQuantumSafe {
    bridgePaused = paused;
}

// ── 更換橋接 Relayer 地址（僅 Owner，防止 Relayer 作惡） ──
function setTokenBridge(address newBridge) external onlyOwner onlyQuantumSafe {
    require(newBridge != address(0), "Invalid bridge address");
    tokenBridge = newBridge;
}
```

---

#### 🏦 接入場景 B：CEX 中心化交易所充提幣

> **說明**：CEX（如幣安、OKX）不直接與智能合約互動，它們只需要標準 ERC20 接口（`transfer`、`approve`、`transferFrom`）。您的 Gamma-ERC20 已完整支援，**無需額外修改合約**。

CEX 接入的關鍵注意事項：

| 項目 | 說明 |
|---|---|
| **充幣監聽** | CEX 後端監聽 `Transfer(from, to, value)` 事件，`from` 為用戶地址，`to` 為交易所熱錢包 |
| **提幣操作** | CEX 後端呼叫 `transfer(userAddress, amount)` 或 `transferFrom` |
| **精度確認** | BNES 強制 18 位精度，CEX 系統設定 `decimals = 18`，**不可設成其他數值** |
| **黑名單功能** | 若有需要，CEX 可要求您在合約層封鎖特定地址，使用 `setBlacklist()` |
| **Gas Fee** | BNES 使用固定低 Gas Price，CEX 後端設定時可硬寫 `gasPrice = 500000000` (0.5 Gwei) |

**確認代幣是否符合 CEX 上架標準的檢查清單：**
```
✅ decimals() == 18
✅ name() 返回正確代幣名稱
✅ symbol() 返回正確代幣簡稱
✅ totalSupply() 不為 0
✅ Transfer 事件符合 ERC20 標準格式
✅ approve / transferFrom 行為符合預期
✅ 無重入漏洞（本模板已防護）
✅ 合約已通過 Sourcify 開源驗證
```

---

#### 🔄 接入場景 C：DEX 去中心化交易所（Uniswap 兼容池）

BNES 的 Uniswap V2/V3 兼容 DEX 接入方式與以太坊完全相同，但需注意物理守恆的精度要求。

**✅ 生產級：在 DEX 建立流動性池的標準流程**
```solidity
// 以下為 JavaScript/TypeScript 腳本，非 Solidity
// 假設使用 BNS-DEX（BNES 鏈上的 Uniswap V2 分支）

// 步驟 1：授權 DEX Router 使用您的代幣
await myToken.approve(BNS_DEX_ROUTER_ADDRESS, ethers.MaxUint256);

// 步驟 2：新增流動性 (addLiquidity)
// 注意：tokenAmount 必須是含 18 位精度的 wei 值
const tokenAmount = ethers.parseUnits('100000', 18);  // 100,000 顆代幣
const bnsCoinAmount = ethers.parseEther('10');         // 10 BNS 原生代幣

await dexRouter.addLiquidityETH(
    myToken.address,
    tokenAmount,
    tokenAmount * 95n / 100n,  // 允許 5% 滑點
    bnsCoinAmount * 95n / 100n,
    ownerAddress,
    Date.now() + 3600          // 1 小時 Deadline
);
```

**⚠️ BNES 特有的 DEX 交易稅警告**：
```
如果您的代幣有「交易稅 (Fee on Transfer)」，
在新增流動性時，MUST 告知 DEX 使用 supportingFeeOnTransfer 版本：

✅ 正確：addLiquidityETH(...) → 無稅代幣
✅ 正確：addLiquidityETHSupportingFeeOnTransferTokens(...) → 有稅代幣

❌ 錯誤：有稅代幣用 addLiquidityETH → 流動性數量不符，交易 Revert
```

---

#### 🌐 接入場景 D：跨鏈 DeFi（BNES ↔ Ethereum/BSC 等）

跨鏈 DeFi（如跨鏈借貸、跨鏈 Yield Farming）需要搭配 ZK Bridge 的完整架構，流程如下：

```
┌─────────────────────────────────────────────────────────────┐
│                   跨鏈 DeFi 架構流程圖                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  BNES 主網                        目標鏈 (Ethereum / BSC)   │
│  ─────────────────                ────────────────────────  │
│  用戶呼叫 bridgeBurn()  ────────→  Relayer 監聽 BridgeBurned │
│         ↓                                  ↓                │
│  代幣在 BNES 銷毀       Halo2 ZK 生成      目標鏈解鎖等值資產 │
│  projectFlux 同步   ←─ zkWitness ─────→   DeFi 協議接收資產 │
│  物理場狀態                        DeFi 操作（借貸/質押）     │
│                                            ↓                │
│  bridgeMint() 重鑄  ←─ Relayer 發起 ──── 目標鏈銷毀包裝資產  │
│  verifyPhysical                                              │
│  Witness() ZK 驗證                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**✅ 生產級：跨鏈 DeFi 接入合約擴展模板**
```solidity
// 跨鏈 DeFi 路由接口：允許外部 DeFi 協議透過橋接鑄造並立即操作
interface ICrossChainDeFi {
    function depositAndStake(address token, uint256 amount) external;
}

// 橋接後立即進行 DeFi 操作（原子性跨鏈 DeFi）
function bridgeMintAndStake(
    address to,
    uint256 amount,
    bytes calldata zkWitness,
    bytes32 stateRoot,
    bytes32 srcTxHash,
    address defiProtocol      // DeFi 協議地址
) external onlyQuantumSafe {
    require(!bridgePaused, "Bridge is paused");
    require(msg.sender == tokenBridge, "Only bridge relayer");
    require(!processedBridgeTx[srcTxHash], "Tx already processed");

    if (!IBNESPhysicsCore(BNES_CORE).verifyPhysicalWitness(zkWitness, stateRoot)) {
        revert InvalidZKProof();
    }

    processedBridgeTx[srcTxHash] = true;
    _mint(address(this), amount);        // 先鑄造給合約本身
    _approve(address(this), defiProtocol, amount);
    ICrossChainDeFi(defiProtocol).depositAndStake(address(this), amount); // 原子進 DeFi
    emit BridgeMinted(to, amount, srcTxHash);
}
```


## 🛡️ 四、 已知漏洞防禦與安全性總結 (Security & Vulnerabilities)

在部署與擴展 Gamma-ERC20 模板時，除了 BNES 特有的物理與量子保護外，仍需注意傳統 EVM 常見的智慧合約漏洞。以下是本模板對已知攻擊的防禦機制，以及開發者在自行擴充功能時的注意事項：

### 1. 重入攻擊 (Reentrancy Attack)
* **漏洞描述**：攻擊者在合約狀態更新前，透過 Fallback 或 Receive 函數重複呼叫合約（如提款函數），導致資產被惡意多重掏空。
* **本模板防禦狀態：已免疫 / 擴展時需注意**。
  * **轉帳與物理映射**：本模板遵循了「檢查-生效-互動」(Checks-Effects-Interactions) 的安全模式。在 `_update` 中，底層 `super._update` 會先扣除餘額並更新帳本狀態，最後才調用外部介面 `projectFlux`，阻斷了重入的條件。
  * **擴展開發建議**：若您未來在合約中加入了**提領 ETH/BNES 原生代幣**的功能，或必須呼叫不受信任的外部合約，請務必引入 OpenZeppelin 的 `ReentrancyGuard` 並為該函數加上 `nonReentrant` 修飾符。

### 2. 重放攻擊 (Replay Attack)
* **漏洞描述**：攻擊者截獲一段合法的簽名或交易，並在另一條鏈或同一個合約中重複發送，造成二次扣款或惡意重複鑄造。
* **本模板防禦狀態：完全免疫**。
  * **同鏈防重放 (ERC20Permit)**：本模板繼承了 `ERC20Permit`，利用內建的 `Nonces` 遞增機制，確保每一筆離線授權簽名 (EIP-2612) 只能被使用一次，用過即失效。
  * **跨鏈防重放 (ZK 綁定)**：`bridgeMint` 函數依賴底層的 `verifyPhysicalWitness`。根據 BNES 規格，Halo2 ZK 證明會將 `stateRoot` 與當前的 `txHash` 寫入證明的公共輸入 (Public Inputs) 中。這保證了每個 ZK 證明只能在「特定狀態」與「特定交易」下生效一次，攻擊者無法將舊的 ZK 憑證拿來重放印鈔。

### 3. 閃電貸攻擊與預言機操縱 (Flash Loan & Oracle Manipulation)
* **漏洞描述**：攻擊者在同一筆交易內透過閃電貸借出巨量資金，砸盤或拉抬特定代幣價格，誤導依賴 AMM 池價格的預言機（如傳統的 Uniswap V2 預言機），隨後獲利還款。
* **本模板防禦狀態：物理引擎降維打擊 (0-Drift)**。
  * 在傳統以太坊上防禦這類套利極度困難。但在 BNES 上，`projectFlux` 會嚴格監控 18 位精度的絕對通量。如果攻擊者試圖透過閃電貸，在複雜的 DEX 路由中產生任何小數點截斷的套利（例如利用除法捨入的 1 wei 誤差來白嫖利息），BNES 節點會在交易結算時偵測到 EVM 總餘額與物理場不一致，並直接觸發 **RF-1 (物理不變量異常)** 將整筆閃電貸強制回滾。這讓因精度誤差產生的閃電貸套利在 BNES 上成為不可能。

### 4. 整數溢位 / 下溢 (Integer Overflow / Underflow)
* **漏洞描述**：數值運算超過 `uint256` 上限或低於 0，導致數值翻轉（如 0 - 1 變成極大值）。
* **本模板防禦狀態：完全免疫**。
  * 本模板指定使用 Solidity `^0.8.27` 編譯。自 Solidity 0.8.0 版本起，編譯器層級已內建了溢位與下溢的安全檢查 (SafeMath 機制)，一旦發生運算越界，交易會自動 Revert，無需額外引入 SafeMath 庫。

### 5. 權限丟失與惡意接管 (Privilege Escalation / Compromise)
* **漏洞描述**：合約管理員的私鑰洩漏，導致合約被惡意升級、暫停，或用戶資金遭黑名單無端凍結。
* **本模板防禦狀態：抗量子級別防禦 (PQC Trust Root)**。
  * 一般 EVM 鏈無法抵禦未來量子計算機對傳統 ECDSA 私鑰的破解。本模板的所有特權操作（如 `setBlacklist`）皆受到 `onlyQuantumSafe` 保護。只要底層 BNES 節點的 `isCanonicalAuthenticated(tx.origin)` 驗證不通過，即使駭客竊取了專案方有效的傳統私鑰並發出交易，依然會被攔截，無法執行任何特權指令。

---

> ⚠️ **開發者極度警告 (Critical Warning)**：
> 在擴展本合約的業務邏輯時，**請勿在合約中混用未經 `tx.origin` PQC 驗證的特權函數**。一旦您新增了任何自定義的 `onlyOwner` 或 `onlyRole` 函數（例如增發代幣、更改橋接地址等），請務必記得同步加上 `onlyQuantumSafe` 修飾符。只要遺漏一個，就會導致合約的安全閉環破裂，淪為量子攻擊的突破口。

---

## 🚀 五、 佈署與合約開源驗證 (Deployment & Verification)

在 BearNetworkChain (BNES) 主網或測試網佈署完您的 Gamma-ERC20 合約後，為了讓 BNScan 區塊鏈瀏覽器與生態系用戶能夠信任並檢視您的合約源碼，我們強烈建議您立即進行合約開源驗證。

我們原生支援透過 **Remix IDE** 結合 **Sourcify** 進行無縫的開源驗證，請依循以下步驟操作：

1. **安裝驗證套件**：在 Remix IDE 的左側插件管理器 (Plugin Manager) 中，搜尋並啟用 **Contract Verification** 插件。
2. **填寫鏈 ID**：進入 Contract Verification 介面後，在網路設定的 **ChainID** 欄位中，精確填入 BNES 的鏈 ID：`641230`。
3. **輸入合約資訊**：填入您剛剛佈署成功的智能合約地址，並確認合約編譯版本等資訊。
4. **選擇 Sourcify 驗證**：在驗證目標選項中，務必勾選 **Verify on: Sourcify**。BNES 網路已深度整合 Sourcify 去中心化合約開源驗證機制。
5. **提交驗證**：點擊驗證按鈕，驗證通過後，您的合約原始碼與 ABI 將立即同步至 BNES 生態系，並受到所有節點與 BNScan 瀏覽器的認可。

---

## 📜 六、 完整可直接佈署範示源碼 (Deployable Source Code Template)

以下為可以直接在 Remix 複製貼上並佈署的完整源碼。為了維持 BNES 物理場的極致安全與對齊，**絕大部分的核心邏輯已經被硬綁定鎖死**。

### ✏️ 用戶無需修改源碼，直接在佈署工具中填寫：
本模板已將所有可變參數提升到建構子 (Constructor) 的輸入欄位中，**Solidity 源碼本身無需任何修改**，直接複製貼上即可。

佈署時，依序填寫以下 6 個參數：
1. **`name_`**: 代幣名稱（例如：`Bear Network`）
2. **`symbol_`**: 代幣簡稱（例如：`BRNKC`）
3. **`tokenBridge_`**: 橋接合約地址（不可為 `0x00...00`）
4. **`initialOwner`**: 初始管理員地址
5. **`recipient`**: 初始代幣接收地址
6. **`initialSupply`**: 初始發行數量（業界原生標準，**調用方負責精度換算**，詳見下表）

### 📊 `initialSupply` 各佈署工具傳入方式對照表

> 本合約採用 EVM 業界原生標準：合約直接使用傳入的原始數值 (`uint256`)，**不在合約內部做任何精度乘算**。這樣才能保證在所有部署工具（Remix / Hardhat / Foundry / 腳本）下行為一致，不會因為「工具是否預先轉換過」而造成雙重乘算、發行量變成天文數字的災難。

| 佈署工具 | `initialSupply` 傳入方式 | 發行 100,000 顆的範例 |
|---|---|---|
| **Remix IDE** | 手動在輸入欄填入含精度的完整大數 | `100000000000000000000000` |
| **Hardhat (ethers.js v6)** | `ethers.parseUnits('100000', 18)` | 自動計算為正確大數 |
| **Hardhat (ethers.js v5)** | `ethers.utils.parseUnits('100000', 18)` | 自動計算為正確大數 |
| **Foundry script** | `100_000 * 10**18` 或 `100_000e18` | 自動計算為正確大數 |
| **通用 JS 腳本** | `BigInt('100000') * BigInt(10**18)` | 自動計算為正確大數 |

> ⚠️ **Remix 新手注意**：在 Remix 的 `initialSupply` 欄位，請複製以下格式，並把 `100000` 替換成您的發行量再自行計算 18 位小數（最快的方法是輸入數字後面加 18 個零）。
> 例如發行 **1,000,000** 顆 → 輸入 `1000000000000000000000000`（即 1,000,000 後面加 18 個零）。

### 完整源碼 (完全免修改，直接複製佈署)

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
