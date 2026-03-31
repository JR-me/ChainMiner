// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IORE {
    function mint(address to, uint256 amount) external;
}

/**
 * @title ChainMiner
 * @notice On-chain idle clicker game.
 *
 * Players click to mine ORE tokens.
 * Upgrades (Pickaxe, Drill, Excavator) multiply yield per click.
 * A global leaderboard tracks all-time ORE mined per address.
 *
 * Upgrade thresholds (total ORE mined):
 *   Level 1 Pickaxe  → free (default)
 *   Level 2 Drill    → 100 ORE mined total
 *   Level 3 Excavator→ 400 ORE mined total
 *
 * Yield per click:
 *   Pickaxe   → 1 ORE
 *   Drill     → 3 ORE
 *   Excavator → 9 ORE
 *
 * Caps:
 *   Max ORE mintable globally → 504,700
 *   Max ORE per user          → 4,900
 */
contract ChainMiner {

    // ── Types ────────────────────────────────────────────────────────────────

    enum Tool { Pickaxe, Drill, Excavator }

    struct Miner {
        uint256 totalMined;   // all-time ORE mined by this address
        uint256 clicks;       // total click transactions
        Tool    tool;         // current upgrade level
    }

    // ── State ────────────────────────────────────────────────────────────────

    IORE    public immutable ore;
    address public immutable owner;

    mapping(address => Miner) public miners;

    // Leaderboard: top-N tracked on-chain (simple approach: store sorted list)
    address[] public leaderboard;          // up to MAX_LB entries, sorted desc
    uint256   public constant MAX_LB = 10;

    // Global and per-user ORE caps
    uint256 public constant MAX_ORE_GLOBAL  = 504_700;
    uint256 public constant MAX_ORE_PER_USER =  4_900;

    // Total ORE minted globally
    uint256 public totalMinted;

    // Upgrade thresholds (total ORE mined by player required)
    uint256 public constant DRILL_THRESHOLD     = 100;
    uint256 public constant EXCAVATOR_THRESHOLD = 400;

    // Yield per click per tool
    uint256 public constant PICKAXE_YIELD   = 1;
    uint256 public constant DRILL_YIELD     = 3;
    uint256 public constant EXCAVATOR_YIELD = 9;

    // ── Events ───────────────────────────────────────────────────────────────

    event Clicked(address indexed player, uint256 oreEarned, uint256 totalMined, Tool tool);
    event Upgraded(address indexed player, Tool newTool);
    event LeaderboardUpdated(address indexed player, uint256 totalMined);

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address ore_) {
        ore   = IORE(ore_);
        owner = msg.sender;
    }

    // ── Core gameplay ────────────────────────────────────────────────────────

    /// @notice Mine ORE. Each call = one click = one transaction.
    function click() external {
        Miner storage m = miners[msg.sender];

        require(totalMinted < MAX_ORE_GLOBAL,       "Global ORE supply exhausted");
        require(m.totalMined < MAX_ORE_PER_USER,    "User ORE cap reached");

        // Auto-upgrade if eligible
        _checkUpgrade(m);

        // Yield based on tool — clamp to whichever cap is hit first
        uint256 yield = _yield(m.tool);
        uint256 globalRemaining = MAX_ORE_GLOBAL  - totalMinted;
        uint256 userRemaining   = MAX_ORE_PER_USER - m.totalMined;
        uint256 effectiveYield  = _min(yield, _min(globalRemaining, userRemaining));

        // Update state
        m.totalMined += effectiveYield;
        totalMinted  += effectiveYield;
        m.clicks     += 1;

        // Mint ORE to player
        ore.mint(msg.sender, effectiveYield);

        // Update leaderboard
        _updateLeaderboard(msg.sender, m.totalMined);

        emit Clicked(msg.sender, effectiveYield, m.totalMined, m.tool);
    }

    /// @notice Manually trigger upgrade check (in case player wants the event).
    function upgrade() external {
        Miner storage m = miners[msg.sender];
        Tool before = m.tool;
        _checkUpgrade(m);
        require(m.tool != before, "no upgrade available yet");
        emit Upgraded(msg.sender, m.tool);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Returns the full top-10 leaderboard.
    function getLeaderboard() external view returns (address[] memory addrs, uint256[] memory totals) {
        uint256 len = leaderboard.length;
        addrs  = new address[](len);
        totals = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            addrs[i]  = leaderboard[i];
            totals[i] = miners[leaderboard[i]].totalMined;
        }
    }

    /// @notice Returns a player's stats.
    function getStats(address player) external view
        returns (uint256 totalMined, uint256 clicks, Tool tool, uint256 yieldPerClick)
    {
        Miner storage m = miners[player];
        return (m.totalMined, m.clicks, m.tool, _yield(m.tool));
    }

    /// @notice ORE needed for next upgrade (0 if maxed out).
    function oreToNextUpgrade(address player) external view returns (uint256) {
        Miner storage m = miners[player];
        if (m.tool == Tool.Pickaxe)  return DRILL_THRESHOLD     > m.totalMined ? DRILL_THRESHOLD     - m.totalMined : 0;
        if (m.tool == Tool.Drill)    return EXCAVATOR_THRESHOLD > m.totalMined ? EXCAVATOR_THRESHOLD - m.totalMined : 0;
        return 0; // already maxed
    }

    /// @notice Remaining ORE that can be mined globally.
    function globalSupplyRemaining() external view returns (uint256) {
        return MAX_ORE_GLOBAL - totalMinted;
    }

    /// @notice Returns true if the player is in the top-10 leaderboard.
    function isOnLeaderboard(address player) external view returns (bool) {
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == player) return true;
        }
        return false;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _yield(Tool t) internal pure returns (uint256) {
        if (t == Tool.Pickaxe) return PICKAXE_YIELD;
        if (t == Tool.Drill)   return DRILL_YIELD;
        return EXCAVATOR_YIELD;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _checkUpgrade(Miner storage m) internal {
        if (m.tool == Tool.Pickaxe && m.totalMined >= DRILL_THRESHOLD) {
            m.tool = Tool.Drill;
            emit Upgraded(msg.sender, Tool.Drill);
        } else if (m.tool == Tool.Drill && m.totalMined >= EXCAVATOR_THRESHOLD) {
            m.tool = Tool.Excavator;
            emit Upgraded(msg.sender, Tool.Excavator);
        }
    }

    function _updateLeaderboard(address player, uint256 total) internal {
        // Check if already on leaderboard
        int256 existingIdx = -1;
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == player) { existingIdx = int256(i); break; }
        }

        if (existingIdx >= 0) {
            // Bubble up if needed
            uint256 idx = uint256(existingIdx);
            while (idx > 0 && miners[leaderboard[idx - 1]].totalMined < total) {
                (leaderboard[idx], leaderboard[idx - 1]) = (leaderboard[idx - 1], leaderboard[idx]);
                idx--;
            }
        } else {
            // Try to enter leaderboard
            if (leaderboard.length < MAX_LB) {
                leaderboard.push(player);
            } else if (total > miners[leaderboard[leaderboard.length - 1]].totalMined) {
                leaderboard[leaderboard.length - 1] = player;
            } else {
                return; // didn't make the cut
            }
            // Sort the new entry into position
            uint256 idx = leaderboard.length - 1;
            while (idx > 0 && miners[leaderboard[idx - 1]].totalMined < total) {
                (leaderboard[idx], leaderboard[idx - 1]) = (leaderboard[idx - 1], leaderboard[idx]);
                idx--;
            }
        }

        emit LeaderboardUpdated(player, total);
    }
}
