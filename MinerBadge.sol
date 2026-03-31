// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IChainMiner {
    function miners(address player) external view returns (uint256 totalMined, uint256 clicks, uint8 tool);
    function isOnLeaderboard(address player) external view returns (bool);
}

/**
 * @title MinerBadge
 * @notice ERC-721 NFT awarded to Chain Miner players based on ORE milestones.
 *
 * Tiers (based on totalMined at time of claim):
 *   LEGENDARY — top-10 leaderboard wallet AND totalMined >= 4,900
 *   RARE      — totalMined >= 4,900 (not on leaderboard top-10)
 *   COMMON    — totalMined >= 400   (reached Excavator)
 *
 * Rules:
 *   - One NFT per wallet, ever.
 *   - Tier is locked at claim time (can't re-claim for a higher tier).
 *   - No burn required — reaching the milestone is sufficient.
 *   - Transferable (standard ERC-721).
 */
contract MinerBadge {

    // ── ERC-721 basics ────────────────────────────────────────────────────────

    string public constant name   = "Chain Miner Badge";
    string public constant symbol = "BADGE";

    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner_, address indexed operator, bool approved);

    // ── Tiers ─────────────────────────────────────────────────────────────────

    enum Tier { Common, Rare, Legendary }

    // Thresholds (mirrors ChainMiner)
    uint256 public constant COMMON_THRESHOLD    =   400; // reached Excavator
    uint256 public constant RARE_THRESHOLD      = 4_900; // fully maxed
    // Legendary = RARE_THRESHOLD + top-10 leaderboard

    // ── State ─────────────────────────────────────────────────────────────────

    IChainMiner public immutable game;
    address      public immutable owner;

    mapping(address => bool)    public hasClaimed;   // one claim per wallet
    mapping(uint256 => Tier)    public tierOf;       // tokenId → tier
    mapping(address => uint256) public tokenOfOwner; // wallet → tokenId (0 = none)

    // Per-tier counts
    uint256 public legendaryCount;
    uint256 public rareCount;
    uint256 public commonCount;

    event BadgeClaimed(address indexed player, uint256 tokenId, Tier tier);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address game_) {
        game  = IChainMiner(game_);
        owner = msg.sender;
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    /// @notice Claim your badge. Reverts if ineligible or already claimed.
    function claim() external {
        require(!hasClaimed[msg.sender], "Already claimed");

        (uint256 totalMined, , ) = game.miners(msg.sender);

        require(totalMined >= COMMON_THRESHOLD, "Not eligible: mine at least 400 ORE");

        // Determine tier
        Tier tier;
        if (totalMined >= RARE_THRESHOLD && game.isOnLeaderboard(msg.sender)) {
            tier = Tier.Legendary;
        } else if (totalMined >= RARE_THRESHOLD) {
            tier = Tier.Rare;
        } else {
            tier = Tier.Common;
        }

        // Mint
        uint256 tokenId = _nextTokenId++;
        _ownerOf[tokenId]      = msg.sender;
        _balanceOf[msg.sender] += 1;
        hasClaimed[msg.sender]  = true;
        tokenOfOwner[msg.sender] = tokenId;
        tierOf[tokenId]         = tier;

        // Tally
        if (tier == Tier.Legendary) legendaryCount++;
        else if (tier == Tier.Rare) rareCount++;
        else                        commonCount++;

        emit Transfer(address(0), msg.sender, tokenId);
        emit BadgeClaimed(msg.sender, tokenId, tier);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// @notice Check eligibility and projected tier for any address.
    function eligibility(address player) external view
        returns (bool eligible, Tier projectedTier, uint256 totalMined)
    {
        (totalMined, , ) = game.miners(player);
        if (totalMined < COMMON_THRESHOLD) return (false, Tier.Common, totalMined);

        eligible = true;
        if (totalMined >= RARE_THRESHOLD && game.isOnLeaderboard(player)) {
            projectedTier = Tier.Legendary;
        } else if (totalMined >= RARE_THRESHOLD) {
            projectedTier = Tier.Rare;
        } else {
            projectedTier = Tier.Common;
        }
    }

    /// @notice Returns a plain-text tokenURI (no IPFS needed for v1).
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        Tier t = tierOf[tokenId];
        string memory tierName  = t == Tier.Legendary ? "Legendary" : t == Tier.Rare ? "Rare" : "Common";
        string memory tierEmoji = t == Tier.Legendary ? unicode"⭐" : t == Tier.Rare ? unicode"💎" : unicode"⛏";

        // Split into two encodePacked calls to stay within the 16-slot stack limit.
        string memory svg = string(abi.encodePacked(
            'data:image/svg+xml;utf8,<svg xmlns=\\"http://www.w3.org/2000/svg\\" viewBox=\\"0 0 200 200\\">',
            '<rect width=\\"200\\" height=\\"200\\" fill=\\"', _bgColor(t), '\\"/>',
            '<text x=\\"100\\" y=\\"90\\" font-size=\\"60\\" text-anchor=\\"middle\\" dominant-baseline=\\"middle\\">', tierEmoji, '</text>',
            '<text x=\\"100\\" y=\\"150\\" font-size=\\"14\\" fill=\\"white\\" text-anchor=\\"middle\\" font-family=\\"monospace\\">', tierName, '</text>',
            '</svg>'
        ));

        return string(abi.encodePacked(
            'data:application/json;utf8,{"name":"Chain Miner Badge #', _toString(tokenId),
            '","description":"Awarded to Chain Miner players for reaching ORE milestones.",',
            '"attributes":[{"trait_type":"Tier","value":"', tierName,
            '"},{"trait_type":"Token ID","value":"', _toString(tokenId), '"}],',
            '"image":"', svg, '"}'
        ));
    }

    function _bgColor(Tier t) internal pure returns (string memory) {
        if (t == Tier.Legendary) return "#4a1a6b"; // deep purple
        if (t == Tier.Rare)      return "#0a3a5c"; // deep blue
        return "#1a2a1a";                           // dark green
    }

    // ── ERC-721 standard ──────────────────────────────────────────────────────

    function balanceOf(address owner_) external view returns (uint256) {
        require(owner_ != address(0), "Zero address");
        return _balanceOf[owner_];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "Token does not exist");
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        address o = _ownerOf[tokenId];
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "Not authorized");
        _approvals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "Token does not exist");
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_ownerOf[tokenId] == from,                               "Wrong owner");
        require(to != address(0),                                         "Zero address");
        require(
            msg.sender == from ||
            _approvals[tokenId] == msg.sender ||
            _operatorApprovals[from][msg.sender],                         "Not authorized"
        );
        _ownerOf[tokenId]   = to;
        _balanceOf[from]   -= 1;
        _balanceOf[to]     += 1;
        delete _approvals[tokenId];
        if (tokenOfOwner[from] == tokenId) delete tokenOfOwner[from];
        tokenOfOwner[to] = tokenId;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external {
        transferFrom(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f || // ERC-721Metadata
            interfaceId == 0x01ffc9a7;   // ERC-165
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
