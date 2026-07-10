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