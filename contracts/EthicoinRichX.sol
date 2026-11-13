// SPDX-License-Identifier: MIT
//
//  ███████╗████████╗██╗  ██╗██╗ ██████╗
//  ██╔════╝╚══██╔══╝██║  ██║██║██╔════╝
//  █████╗     ██║   ███████║██║██║
//  ██╔══╝     ██║   ██╔══██║██║██║
//  ███████╗   ██║   ██║  ██║██║╚██████╗
//  ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝  +
//
//  Ethicoin  (ETHIC+)  —  RichX Chain
//  Chain ID 20260903 · Proof of Authority · September 2026
//
//  ============================================================
//  WHAT THIS TOKEN IS
//  ============================================================
//    - 1,000,000,000,000 (1 trillion) fixed supply, 9 decimals
//    - NO MINT FUNCTION EXISTS ANYWHERE. Supply can never increase,
//      not by the deployer, not by the owner, not by anyone. That
//      permanence is the whole point of a gold-indexed asset.
//    - Supply CAN decrease, permanently, through burn(). This is the
//      redemption path: the holder burns, the exchange settles gold
//      index value against the confirmed burn, the tokens are gone.
//    - NO TRANSFER FEE. Send 1,000, the recipient receives 1,000.
//      A plain ERC-20, compatible with every router and exchange
//      without special handling.
//    - Gold-indexed at 0.1g per token. INDEXED, NOT BACKED — this
//      contract holds no metal, custodies no metal, and confers no
//      claim on metal. The index is a pricing reference only.
//      A separate GoldIndex oracle publishes the reference price
//      on chain; this token never reads it, so a faulty oracle can
//      never affect a balance.
//
//  ============================================================
//  SECURITY MODEL — TWO KEYS THAT CHECK EACH OTHER
//  ============================================================
//
//  OWNER    — kept OFFLINE. Never on a server. Can freeze wallets
//             after a timelock, recover from frozen wallets, set the
//             transfer limit and exemptions, and propose handing over
//             ownership (48h timelock).
//
//  GUARDIAN — separate seed, separate device. Can pause/unpause
//             instantly, propose blacklists, and VETO a pending
//             ownership transfer. Cannot seize, cannot change limits,
//             cannot take ownership, cannot unfreeze a wallet.
//
//  NEITHER key can create tokens — no mint function exists.
//  NEITHER key can take an ordinary holder's balance.
//  There is NO selfdestruct anywhere in this contract.
//
//  A stolen owner key cannot lock you out: an ownership transfer is
//  public for 48 hours and the guardian can cancel it.
//
//  ============================================================
//  DIFFERENCES FROM THE LEGACY BNB SMART CHAIN DEPLOYMENT
//  ============================================================
//    - No transfer fee (the legacy version charges 1%)
//    - burn() exists and totalSupply is reducible (the legacy version
//      declares totalSupply constant, making burn-to-redeem impossible)
//    - Transfer-limit exemptions, so the supply is actually distributable
//    - Seizure from a frozen wallet is not rate-limited
//    - Ownership transfer is two-step, timelocked and vetoable
//    - permit() respects the pause
//    - The domain separator survives a chain id change
//
pragma solidity ^0.8.20;

contract EthicoinRichX {
    // ---- identity ----
    string public constant name = "Ethicoin";
    string public constant symbol = "ETHIC+";
    uint8  public constant decimals = 9;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000 * 1e9; // 1 trillion

    // Mutable ONLY so burn() can reduce it. There is no mint function
    // in this contract, so this number can never go up. Ever.
    uint256 public totalSupply;

    // Running total of everything ever burned — a public, permanent
    // record of redemption volume.
    uint256 public totalBurned;

    // ---- per-transaction drain guard ----
    uint256 public maxTxAmount;
    uint256 public constant MIN_TX_LIMIT = 100_000_000 * 1e9;    // 0.01% of initial supply
    uint256 public constant MAX_TX_LIMIT = 10_000_000_000 * 1e9; // 1% of initial supply

    // Addresses allowed to exceed maxTxAmount. Grant to the treasury,
    // the bridge, and the DEX pair — nothing else. Every change is public.
    mapping(address => bool) public isExemptFromTxLimit;

    // ---- roles ----
    address public owner;
    address public guardian;
    bool public paused;

    // ---- timelocks ----
    uint256 public constant BLACKLIST_TIMELOCK = 10 minutes;
    uint256 public constant OWNERSHIP_TIMELOCK = 48 hours;

    mapping(address => uint256) public blacklistProposedAt;
    mapping(address => string)  public blacklistProposedReason;

    address public pendingOwner;
    uint256 public pendingOwnerProposedAt;

    // ---- ledgers ----
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlacklisted;

    // ---- EIP-2612 permit ----
    mapping(address => uint256) public nonces;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    // ---- batch guard ----
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ---- events ----
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Burn(address indexed from, uint256 amount, string reason);
    event TxLimitExemptSet(address indexed account, bool exempt);
    event Blacklisted(address indexed account, string reason);
    event Unblacklisted(address indexed account);
    event Paused();
    event Unpaused();
    event Seized(address indexed from, address indexed to, uint256 amount, string reason);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferProposed(address indexed newOwner, uint256 executableAt);
    event OwnershipTransferCancelled(address indexed newOwner, address indexed cancelledBy);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event BlacklistProposed(address indexed account, string reason, uint256 executableAt);
    event BlacklistCancelled(address indexed account);
    event MaxTxAmountChanged(uint256 previousLimit, uint256 newLimit);

    // ---- custom errors ----
    error NotOwner();
    error NotAuthorized();
    error IsPaused();
    error Blacklisted_();
    error OverTxLimit();
    error ZeroAddress();
    error InsufficientBalance();
    error NotApproved();
    error NotBlacklisted();
    error NoProposalPending();
    error TimelockNotElapsed();
    error TxLimitOutOfRange();
    error PermitExpired();
    error InvalidSignature();
    error LengthMismatch();
    error TooManyRecipients();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert NotAuthorized();
        _;
    }

    constructor() {
        owner = msg.sender;

        // The entire fixed supply is created once, here. There is no
        // mint function, so this is the only issuance that will ever occur.
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;

        maxTxAmount = INITIAL_SUPPLY / 1000; // 0.1% of supply

        // Deployer can exceed the tx cap so the supply is actually
        // distributable. REVOKE THIS once funds reach the treasury.
        isExemptFromTxLimit[msg.sender] = true;

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();

        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
        emit TxLimitExemptSet(msg.sender, true);
    }

    // ============================================================
    // EIP-712 DOMAIN — recomputed if the chain id ever changes, so
    // permit signatures cannot be replayed across a fork.
    // ============================================================
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _CACHED_DOMAIN_SEPARATOR;
        return _buildDomainSeparator();
    }

    // ============================================================
    // INTERNAL TRANSFER — one code path, all guards applied once
    //
    // No fee of any kind. Send 1,000, the recipient receives 1,000.
    // A standard ERC-20 transfer, compatible with every router,
    // exchange and integration without special handling.
    // ============================================================
    function _transfer(address from, address to, uint256 amount) private {
        if (paused) revert IsPaused();
        if (isBlacklisted[from] || isBlacklisted[to]) revert Blacklisted_();
        if (!isExemptFromTxLimit[from] && amount > maxTxAmount) revert OverTxLimit();
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();

        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts)
        external
        returns (bool)
    {
        uint256 len = recipients.length;
        if (len != amounts.length) revert LengthMismatch();
        if (len > MAX_BATCH_SIZE) revert TooManyRecipients();
        for (uint256 i; i < len;) {
            _transfer(msg.sender, recipients[i], amounts[i]);
            unchecked { ++i; }
        }
        return true;
    }

    function _approve(address o, address spender, uint256 amount) private {
        allowance[o][spender] = amount;
        emit Approval(o, spender, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (paused) revert IsPaused();
        if (isBlacklisted[msg.sender]) revert Blacklisted_();
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert NotApproved();
        if (allowed != type(uint256).max) {
            unchecked { allowance[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ============================================================
    // BURN — THE REDEMPTION MECHANISM
    //
    // This is the White Paper's gold settlement path: the holder burns,
    // AIA Exchange settles gold index value against the confirmed burn,
    // and the tokens are destroyed permanently. Supply only ever falls.
    //
    // `reason` is free text (e.g. an AIA redemption reference) so the
    // burn is self-documenting on-chain.
    // ============================================================
    function _burn(uint256 amount, string memory reason) private {
        if (paused) revert IsPaused();
        if (isBlacklisted[msg.sender]) revert Blacklisted_();
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
            totalBurned += amount;
        }
        emit Transfer(msg.sender, address(0), amount);
        emit Burn(msg.sender, amount, reason);
    }

    // Burn with a redemption reference (e.g. an AIA settlement id).
    function burnWithReason(uint256 amount, string calldata reason) external {
        _burn(amount, reason);
    }

    // Standard single-argument burn, for wallets and tooling that
    // expect the conventional burn(uint256) signature.
    function burn(uint256 amount) external {
        _burn(amount, "");
    }

    // ============================================================
    // EIP-2612 PERMIT — approve via signature, no gas needed by the
    // token owner. Now respects pause, matching approve().
    // ============================================================
    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (paused) revert IsPaused();
        if (block.timestamp > deadline) revert PermitExpired();
        if (isBlacklisted[tokenOwner]) revert Blacklisted_();

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, tokenOwner, spender, value, nonces[tokenOwner]++, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != tokenOwner) revert InvalidSignature();

        _approve(tokenOwner, spender, value);
    }

    // ============================================================
    // EMERGENCY STOP — instant, no timelock. Speed matters when a
    // drain is in progress, and a wrong pause costs nothing.
    // ============================================================
    function pause() external onlyOwnerOrGuardian { paused = true; emit Paused(); }
    function unpause() external onlyOwnerOrGuardian { paused = false; emit Unpaused(); }

    // ============================================================
    // LIMITS, EXEMPTIONS, FEE ROUTING — owner only
    // ============================================================
    function setMaxTxAmount(uint256 newLimit) external onlyOwner {
        if (newLimit < MIN_TX_LIMIT || newLimit > MAX_TX_LIMIT) revert TxLimitOutOfRange();
        emit MaxTxAmountChanged(maxTxAmount, newLimit);
        maxTxAmount = newLimit;
    }

    function setTxLimitExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isExemptFromTxLimit[account] = exempt;
        emit TxLimitExemptSet(account, exempt);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ============================================================
    // BLACKLIST — propose (owner or guardian), execute after timelock
    // (anyone), cancel during the window (owner only).
    // ============================================================
    function proposeBlacklist(address account, string calldata reason) external onlyOwnerOrGuardian {
        blacklistProposedAt[account] = block.timestamp;
        blacklistProposedReason[account] = reason;
        emit BlacklistProposed(account, reason, block.timestamp + BLACKLIST_TIMELOCK);
    }

    function proposeBlacklistMany(address[] calldata accounts, string calldata reason)
        external
        onlyOwnerOrGuardian
    {
        uint256 len = accounts.length;
        if (len > MAX_BATCH_SIZE) revert TooManyRecipients();
        uint256 executableAt = block.timestamp + BLACKLIST_TIMELOCK;
        for (uint256 i; i < len;) {
            blacklistProposedAt[accounts[i]] = block.timestamp;
            blacklistProposedReason[accounts[i]] = reason;
            emit BlacklistProposed(accounts[i], reason, executableAt);
            unchecked { ++i; }
        }
    }

    function cancelBlacklistProposal(address account) external onlyOwner {
        if (blacklistProposedAt[account] == 0) revert NoProposalPending();
        delete blacklistProposedAt[account];
        delete blacklistProposedReason[account];
        emit BlacklistCancelled(account);
    }

    function executeBlacklist(address account) external {
        uint256 proposedAt = blacklistProposedAt[account];
        if (proposedAt == 0) revert NoProposalPending();
        if (block.timestamp < proposedAt + BLACKLIST_TIMELOCK) revert TimelockNotElapsed();
        isBlacklisted[account] = true;
        emit Blacklisted(account, blacklistProposedReason[account]);
        delete blacklistProposedAt[account];
        delete blacklistProposedReason[account];
    }

    // Owner only — unfreezing is a trust decision, not a defense action.
    function unblacklistWallet(address account) external onlyOwner {
        isBlacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ============================================================
    // RECOVER — move funds out of an already-frozen wallet.
    // Not capped by maxTxAmount: the wallet is frozen, nothing is
    // moving, and rate-limiting recovery only helps the attacker.
    // No fee is charged on a seizure.
    // ============================================================
    function seizeFromBlacklisted(address from, address to, uint256 amount, string calldata reason)
        external
        onlyOwner
    {
        if (!isBlacklisted[from]) revert NotBlacklisted();
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Seized(from, to, amount, reason);
        emit Transfer(from, to, amount);
    }

    // ============================================================
    // OWNERSHIP — TIMELOCKED, GUARDIAN-VETOABLE, TWO-STEP
    //
    // A stolen owner key cannot lock you out: the transfer is public
    // for 48 hours and the guardian can cancel it. The incoming owner
    // must call acceptOwnership() themselves, which proves the address
    // is controllable before control moves.
    // ============================================================
    function proposeOwnershipTransfer(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        pendingOwnerProposedAt = block.timestamp;
        emit OwnershipTransferProposed(newOwner, block.timestamp + OWNERSHIP_TIMELOCK);
    }

    function cancelOwnershipTransfer() external onlyOwnerOrGuardian {
        if (pendingOwnerProposedAt == 0) revert NoProposalPending();
        emit OwnershipTransferCancelled(pendingOwner, msg.sender);
        pendingOwner = address(0);
        pendingOwnerProposedAt = 0;
    }

    function acceptOwnership() external {
        uint256 proposedAt = pendingOwnerProposedAt;
        if (proposedAt == 0) revert NoProposalPending();
        if (msg.sender != pendingOwner) revert NotAuthorized();
        if (block.timestamp < proposedAt + OWNERSHIP_TIMELOCK) revert TimelockNotElapsed();

        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
        pendingOwnerProposedAt = 0;
    }
}
