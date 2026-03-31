// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ORE Token
 * @notice ERC-20 token mintable only by the ChainMiner game contract.
 */
contract ORE {
    string public constant name     = "ORE";
    string public constant symbol   = "ORE";
    uint8  public constant decimals = 0; // whole units only — 1 click = 1 ORE

    address public owner;       // deployer — used to set the minter once
    address public minter;      // ChainMiner contract

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner_, address indexed spender, uint256 value);
    event MinterSet(address indexed minter_);

    modifier onlyOwner()  { require(msg.sender == owner,  "not owner");  _; }
    modifier onlyMinter() { require(msg.sender == minter, "not minter"); _; }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Called once after ChainMiner is deployed.
    function setMinter(address minter_) external onlyOwner {
        require(minter == address(0), "minter already set");
        minter = minter_;
        emit MinterSet(minter_);
    }

    /// @notice Mint ORE — only callable by the game contract.
    function mint(address to, uint256 amount) external onlyMinter {
        totalSupply        += amount;
        balanceOf[to]      += amount;
        emit Transfer(address(0), to, amount);
    }

    // ── Standard ERC-20 ──────────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance exceeded");
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
