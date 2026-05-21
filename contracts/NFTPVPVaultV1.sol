// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {ApproveAction, FieldDescriptor, VaultMethodSchema, VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {PvpEntryNFT} from "./PvpEntryNFT.sol";

interface IPancakeLikeRouter {
    function WETH() external view returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract NFTPVPVaultV1 is VaultBaseV2, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant NFT_PRICE = 100_000 ether;
    uint256 public constant MAX_BET_AMOUNT = 10_000_000 ether;
    uint256 private constant MAGNITUDE = 1e36;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    PvpEntryNFT public immutable entryNft;
    IPancakeLikeRouter public router;
    address public guardianOverride;

    uint256 public tokenPriceBnbPerToken;
    uint256 public revealTimeout = 1 days;
    uint256 public nextMatchId = 1;

    uint256 public nftMintTokenBuffer;
    uint256 public lossMintTokenBuffer;
    uint256 public pvpLossTokenBuffer;
    uint256 public totalBurnedToken;

    uint256 public nftReservedBnb;
    uint256 public lossReservedBnb;
    uint256 public nftUndistributedBnb;
    uint256 public lossUndistributedBnb;

    uint256 public accNftBnbPerShare;
    uint256 public accLossBnbPerQuota;
    uint256 public totalLossQuota;

    struct Tier {
        uint256 betAmount;
        bool enabled;
    }

    struct QueueEntry {
        address player;
        uint256 nftId;
        uint256 betAmount;
        bytes32 seedCommitment;
    }

    struct MatchInfo {
        address playerA;
        address playerB;
        uint256 nftA;
        uint256 nftB;
        uint256 betAmount;
        uint256 createdAt;
        bytes32 commitA;
        bytes32 commitB;
        bytes32 seedA;
        bytes32 seedB;
        bool revealedA;
        bool revealedB;
        bool settled;
    }

    struct Stats {
        address tokenAddress;
        address nftAddress;
        uint256 totalMinted;
        uint256 liveNftSupply;
        uint256 nftMintTokenBuffer;
        uint256 lossMintTokenBuffer;
        uint256 pvpLossTokenBuffer;
        uint256 nftReservedBnb;
        uint256 lossReservedBnb;
        uint256 nftUndistributedBnb;
        uint256 lossUndistributedBnb;
        uint256 totalLossQuota;
        uint256 totalBurnedToken;
    }

    struct MyInfo {
        uint256 nftBalance;
        uint256 pendingNftBnb;
        uint256 pendingLossBnb;
        uint256 lossQuota;
        uint256 lossClaimed;
    }

    mapping(uint256 => Tier) public tiers;
    mapping(uint256 => QueueEntry) public queueOfTier;
    mapping(uint256 => MatchInfo) public matches;
    mapping(uint256 => bool) public nftInActiveGame;
    mapping(address => bool) public playerInActiveGame;

    mapping(address => uint256) private _nftRewardDebt;
    mapping(address => uint256) private _nftCredit;
    mapping(address => uint256) public claimedNftDividends;

    mapping(address => uint256) public lossQuotaOf;
    mapping(address => uint256) private _lossRewardDebt;
    mapping(address => uint256) private _lossCredit;
    mapping(address => uint256) public claimedLossDividends;

    bool private _converting;

    event NftMinted(address indexed user, uint256 quantity, uint256 requestedTokenAmount, uint256 actualReceived);
    event QueueEntered(uint256 indexed tierId, address indexed user, uint256 nftId, uint256 betAmount);
    event QueueLeft(uint256 indexed tierId, address indexed user, uint256 nftId, uint256 betAmount);
    event MatchRequested(uint256 indexed matchId, uint256 indexed tierId, address indexed playerA, address playerB);
    event SeedRevealed(uint256 indexed matchId, address indexed player);
    event RevealTimeoutWin(uint256 indexed matchId, address indexed winner, address indexed loser);
    event MatchSettled(uint256 indexed matchId, address indexed winner, address indexed loser, uint256 betAmount);
    event MatchCancelled(uint256 indexed matchId, address indexed playerA, address indexed playerB, uint256 betAmount);
    event MintBuffersConverted(uint256 nftTokens, uint256 lossTokens, uint256 nftBnb, uint256 lossBnb);
    event NftDividendsClaimed(address indexed user, uint256 amount);
    event LossDividendsClaimed(address indexed user, uint256 amount);
    event BnbReceived(address indexed sender, uint256 amount, uint256 nftAmount, uint256 lossAmount);
    event RescueExcessBNB(address indexed to, uint256 amount);
    event TierUpdated(uint256 indexed tierId, uint256 betAmount, bool enabled);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event GuardianOverrideUpdated(address indexed oldGuardian, address indexed newGuardian);
    event TokenPriceBnbPerTokenUpdated(uint256 oldPrice, uint256 newPrice);
    event RevealTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    error ZeroAddress();
    error NotOwnerOrGuardian();
    error InvalidTokenAmount();
    error MaxSupplyExceeded();
    error InvalidTier();
    error InvalidBetAmount();
    error QueueOccupied();
    error NftAlreadyActive();
    error PlayerAlreadyActive();
    error NoQueuedEntry();
    error NotQueuedPlayer();
    error NotNftOwner();
    error NotNftContract();
    error MatchAlreadySettled();
    error InvalidCommitment();
    error InvalidReveal();
    error RevealPeriodActive();
    error NoRevealToForfeit();
    error NoRewards();
    error NativeTransferFailed();
    error InsufficientExcessBNB();
    error SlippageExceeded();
    error DeadlineExpired();
    error InvalidPrice();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && !_isGuardian(msg.sender)) revert NotOwnerOrGuardian();
        _;
    }

    constructor(
        address token_,
        address router_,
        address initialOwner_,
        address guardianOverride_,
        uint256 tokenPriceBnbPerToken_
    ) Ownable(initialOwner_) {
        if (token_ == address(0) || router_ == address(0) || initialOwner_ == address(0)) revert ZeroAddress();
        if (tokenPriceBnbPerToken_ == 0) revert InvalidPrice();
        token = IERC20(token_);
        router = IPancakeLikeRouter(router_);
        guardianOverride = guardianOverride_;
        tokenPriceBnbPerToken = tokenPriceBnbPerToken_;
        entryNft = new PvpEntryNFT("PVP Entry NFT", "PVPNFT", address(this), initialOwner_);
    }

    receive() external payable {
        if (_converting) return;
        uint256 nftAmount = msg.value / 2;
        uint256 lossAmount = msg.value - nftAmount;
        _addNftBnb(nftAmount);
        _addLossBnb(lossAmount);
        emit BnbReceived(msg.sender, msg.value, nftAmount, lossAmount);
    }

    function mintNFT(uint256 tokenAmount) external nonReentrant {
        if (tokenAmount == 0) revert InvalidTokenAmount();
        uint256 actualReceived = _pullTokens(msg.sender, tokenAmount);
        if (actualReceived == 0 || actualReceived % NFT_PRICE != 0) revert InvalidTokenAmount();
        uint256 quantity = actualReceived / NFT_PRICE;
        if (entryNft.activeSupply() + quantity > entryNft.MAX_SUPPLY()) revert MaxSupplyExceeded();

        uint256 burnAmount = actualReceived / 2;
        uint256 lossAmount = actualReceived / 4;
        uint256 nftAmount = actualReceived - burnAmount - lossAmount;

        _sendToDead(burnAmount);
        lossMintTokenBuffer += lossAmount;
        nftMintTokenBuffer += nftAmount;

        for (uint256 i = 0; i < quantity; i++) {
            entryNft.mintByVault(msg.sender);
        }
        _indexPendingNftBnb();

        emit NftMinted(msg.sender, quantity, tokenAmount, actualReceived);
    }

    function enterQueue(uint256 tierId, uint256 nftId, uint256 betAmount, bytes32 seedCommitment) external nonReentrant {
        if (seedCommitment == bytes32(0)) revert InvalidCommitment();
        Tier memory tier = tiers[tierId];
        if (!tier.enabled) revert InvalidTier();
        if (betAmount != tier.betAmount || betAmount > MAX_BET_AMOUNT) revert InvalidBetAmount();
        if (entryNft.ownerOf(nftId) != msg.sender) revert NotNftOwner();
        if (nftInActiveGame[nftId]) revert NftAlreadyActive();
        if (playerInActiveGame[msg.sender]) revert PlayerAlreadyActive();

        QueueEntry memory queued = queueOfTier[tierId];
        if (queued.player == msg.sender) revert QueueOccupied();
        if (queued.player != address(0) && queued.player == msg.sender) revert PlayerAlreadyActive();

        uint256 actualReceived = _pullTokens(msg.sender, betAmount);
        if (actualReceived != betAmount) revert InvalidBetAmount();
        entryNft.lockByVault(nftId);
        nftInActiveGame[nftId] = true;
        playerInActiveGame[msg.sender] = true;

        if (queued.player == address(0)) {
            queueOfTier[tierId] = QueueEntry(msg.sender, nftId, betAmount, seedCommitment);
            emit QueueEntered(tierId, msg.sender, nftId, betAmount);
            return;
        }

        delete queueOfTier[tierId];
        uint256 matchId = nextMatchId++;
        matches[matchId] = MatchInfo({
            playerA: queued.player,
            playerB: msg.sender,
            nftA: queued.nftId,
            nftB: nftId,
            betAmount: betAmount,
            createdAt: block.timestamp,
            commitA: queued.seedCommitment,
            commitB: seedCommitment,
            seedA: bytes32(0),
            seedB: bytes32(0),
            revealedA: false,
            revealedB: false,
            settled: false
        });
        emit MatchRequested(matchId, tierId, queued.player, msg.sender);
    }

    function leaveQueue(uint256 tierId) external nonReentrant {
        QueueEntry memory queued = queueOfTier[tierId];
        if (queued.player == address(0)) revert NoQueuedEntry();
        if (queued.player != msg.sender) revert NotQueuedPlayer();
        delete queueOfTier[tierId];
        nftInActiveGame[queued.nftId] = false;
        playerInActiveGame[msg.sender] = false;
        entryNft.unlockByVault(queued.nftId);
        token.safeTransfer(msg.sender, queued.betAmount);
        emit QueueLeft(tierId, msg.sender, queued.nftId, queued.betAmount);
    }

    function revealSeed(uint256 matchId, bytes32 seed) external nonReentrant {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        if (msg.sender == matchInfo.playerA) {
            if (keccak256(abi.encodePacked(msg.sender, seed)) != matchInfo.commitA) revert InvalidReveal();
            matchInfo.seedA = seed;
            matchInfo.revealedA = true;
        } else if (msg.sender == matchInfo.playerB) {
            if (keccak256(abi.encodePacked(msg.sender, seed)) != matchInfo.commitB) revert InvalidReveal();
            matchInfo.seedB = seed;
            matchInfo.revealedB = true;
        } else {
            revert NotQueuedPlayer();
        }
        emit SeedRevealed(matchId, msg.sender);

        if (matchInfo.revealedA && matchInfo.revealedB) {
            uint256 randomness =
                uint256(keccak256(abi.encodePacked(matchId, matchInfo.seedA, matchInfo.seedB, matchInfo.playerA, matchInfo.playerB)));
            _settleMatch(matchId, randomness);
        }
    }

    function claimRevealTimeoutWin(uint256 matchId) external nonReentrant {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        if (block.timestamp < matchInfo.createdAt + revealTimeout) revert RevealPeriodActive();

        bool aOnly = matchInfo.revealedA && !matchInfo.revealedB;
        bool bOnly = matchInfo.revealedB && !matchInfo.revealedA;
        if (!aOnly && !bOnly) revert NoRevealToForfeit();

        address winner = aOnly ? matchInfo.playerA : matchInfo.playerB;
        address loser = aOnly ? matchInfo.playerB : matchInfo.playerA;
        if (msg.sender != winner && msg.sender != owner() && !_isGuardian(msg.sender)) revert NotOwnerOrGuardian();
        emit RevealTimeoutWin(matchId, winner, loser);
        _settleMatchWithWinner(matchId, winner);
    }

    function emergencyCancelMatch(uint256 matchId) external nonReentrant {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        if (block.timestamp < matchInfo.createdAt + revealTimeout) revert RevealPeriodActive();
        if (matchInfo.revealedA || matchInfo.revealedB) revert NoRevealToForfeit();
        if (msg.sender != matchInfo.playerA && msg.sender != matchInfo.playerB && msg.sender != owner() && !_isGuardian(msg.sender)) {
            revert NotOwnerOrGuardian();
        }
        matchInfo.settled = true;

        _clearActive(matchInfo.playerA, matchInfo.nftA);
        _clearActive(matchInfo.playerB, matchInfo.nftB);
        entryNft.unlockByVault(matchInfo.nftA);
        entryNft.unlockByVault(matchInfo.nftB);
        token.safeTransfer(matchInfo.playerA, matchInfo.betAmount);
        token.safeTransfer(matchInfo.playerB, matchInfo.betAmount);

        emit MatchCancelled(matchId, matchInfo.playerA, matchInfo.playerB, matchInfo.betAmount);
    }

    function convertMintBuffers(uint256 minNftBnbOut, uint256 minLossBnbOut, uint256 deadline)
        external
        onlyOwnerOrGuardian
        nonReentrant
    {
        if (deadline < block.timestamp) revert DeadlineExpired();
        uint256 nftTokens = nftMintTokenBuffer;
        uint256 lossTokens = lossMintTokenBuffer + pvpLossTokenBuffer;
        if (nftTokens == 0 && lossTokens == 0) revert InvalidTokenAmount();

        nftMintTokenBuffer = 0;
        lossMintTokenBuffer = 0;
        pvpLossTokenBuffer = 0;

        uint256 nftBnb;
        uint256 lossBnb;
        if (nftTokens > 0) {
            nftBnb = _swapTokensForBnb(nftTokens, minNftBnbOut, deadline);
            _addNftBnb(nftBnb);
        } else if (minNftBnbOut != 0) {
            revert SlippageExceeded();
        }
        if (lossTokens > 0) {
            lossBnb = _swapTokensForBnb(lossTokens, minLossBnbOut, deadline);
            _addLossBnb(lossBnb);
        } else if (minLossBnbOut != 0) {
            revert SlippageExceeded();
        }

        emit MintBuffersConverted(nftTokens, lossTokens, nftBnb, lossBnb);
    }

    function claimNftDividends() external nonReentrant {
        _settleNftAccount(msg.sender);
        uint256 amount = _nftCredit[msg.sender];
        if (amount == 0) revert NoRewards();
        _nftCredit[msg.sender] = 0;
        claimedNftDividends[msg.sender] += amount;
        nftReservedBnb -= amount;
        _sendNative(msg.sender, amount);
        emit NftDividendsClaimed(msg.sender, amount);
    }

    function claimLossDividends() external nonReentrant {
        _settleLossAccount(msg.sender);
        uint256 amount = _lossCredit[msg.sender];
        uint256 quota = lossQuotaOf[msg.sender];
        if (amount > quota) amount = quota;
        if (amount == 0) revert NoRewards();

        _lossCredit[msg.sender] = 0;
        lossQuotaOf[msg.sender] = quota - amount;
        totalLossQuota -= amount;
        _lossRewardDebt[msg.sender] = lossQuotaOf[msg.sender] * accLossBnbPerQuota / MAGNITUDE;
        claimedLossDividends[msg.sender] += amount;
        lossReservedBnb -= amount;

        _sendNative(msg.sender, amount);
        emit LossDividendsClaimed(msg.sender, amount);
    }

    function rescueExcessBNB(address to, uint256 amount) external onlyOwnerOrGuardian nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > excessBnbAvailable()) revert InsufficientExcessBNB();
        _sendNative(to, amount);
        emit RescueExcessBNB(to, amount);
    }

    function excessBnbAvailable() public view returns (uint256) {
        uint256 reserved = nftReservedBnb + lossReservedBnb + nftUndistributedBnb + lossUndistributedBnb;
        return address(this).balance > reserved ? address(this).balance - reserved : 0;
    }

    function onNftBalanceChange(address from, address to) external {
        if (msg.sender != address(entryNft)) revert NotNftContract();
        if (from == to) return;
        if (from != address(0)) {
            uint256 oldFromBalance = entryNft.balanceOf(from);
            _settleNftAccountToBalance(from, oldFromBalance - 1);
        }
        if (to != address(0)) {
            uint256 oldToBalance = entryNft.balanceOf(to);
            _settleNftAccountToBalance(to, oldToBalance + 1);
        }
    }

    function setTier(uint256 tierId, uint256 betAmount, bool enabled) external onlyOwnerOrGuardian {
        if (betAmount == 0 || betAmount > MAX_BET_AMOUNT) revert InvalidBetAmount();
        tiers[tierId] = Tier(betAmount, enabled);
        emit TierUpdated(tierId, betAmount, enabled);
    }

    function setRouter(address router_) external onlyOwnerOrGuardian {
        if (router_ == address(0)) revert ZeroAddress();
        address oldRouter = address(router);
        router = IPancakeLikeRouter(router_);
        emit RouterUpdated(oldRouter, router_);
    }

    function setGuardianOverride(address guardian) external onlyOwnerOrGuardian {
        address oldGuardian = guardianOverride;
        guardianOverride = guardian;
        emit GuardianOverrideUpdated(oldGuardian, guardian);
    }

    function setTokenPriceBnbPerToken(uint256 newPrice) external onlyOwnerOrGuardian {
        if (newPrice == 0) revert InvalidPrice();
        uint256 oldPrice = tokenPriceBnbPerToken;
        tokenPriceBnbPerToken = newPrice;
        emit TokenPriceBnbPerTokenUpdated(oldPrice, newPrice);
    }

    function setRevealTimeout(uint256 newTimeout) external onlyOwnerOrGuardian {
        uint256 oldTimeout = revealTimeout;
        revealTimeout = newTimeout;
        emit RevealTimeoutUpdated(oldTimeout, newTimeout);
    }

    function getStats() external view returns (Stats memory stats) {
        stats = Stats({
            tokenAddress: address(token),
            nftAddress: address(entryNft),
            totalMinted: entryNft.totalMintedEver(),
            liveNftSupply: entryNft.activeSupply(),
            nftMintTokenBuffer: nftMintTokenBuffer,
            lossMintTokenBuffer: lossMintTokenBuffer,
            pvpLossTokenBuffer: pvpLossTokenBuffer,
            nftReservedBnb: nftReservedBnb,
            lossReservedBnb: lossReservedBnb,
            nftUndistributedBnb: nftUndistributedBnb,
            lossUndistributedBnb: lossUndistributedBnb,
            totalLossQuota: totalLossQuota,
            totalBurnedToken: totalBurnedToken
        });
    }

    function getMyInfo(address user) external view returns (MyInfo memory info) {
        info = MyInfo({
            nftBalance: entryNft.balanceOf(user),
            pendingNftBnb: pendingNftDividends(user),
            pendingLossBnb: pendingLossDividends(user),
            lossQuota: lossQuotaOf[user],
            lossClaimed: claimedLossDividends[user]
        });
    }

    function pendingNftDividends(address user) public view returns (uint256) {
        uint256 accumulated = entryNft.balanceOf(user) * accNftBnbPerShare / MAGNITUDE;
        uint256 debt = _nftRewardDebt[user];
        uint256 pending = accumulated > debt ? accumulated - debt : 0;
        return _nftCredit[user] + pending;
    }

    function pendingLossDividends(address user) public view returns (uint256) {
        uint256 accumulated = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
        uint256 debt = _lossRewardDebt[user];
        uint256 pending = accumulated > debt ? accumulated - debt : 0;
        uint256 amount = _lossCredit[user] + pending;
        uint256 quota = lossQuotaOf[user];
        return amount > quota ? quota : amount;
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "NFTPVPVaultV1 live NFTs ",
            _toString(entryNft.activeSupply()),
            ", NFT BNB ",
            _toString(nftReservedBnb),
            ", Loss BNB ",
            _toString(lossReservedBnb),
            ", NFT pending ",
            _toString(nftUndistributedBnb),
            ", Loss pending ",
            _toString(lossUndistributedBnb),
            "."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "NFTPVPVaultV1";
        schema.description = "NFT PVP commit-reveal vault. Use the official site to auto-create seed commitments and reveal seeds.";
        schema.methods = new VaultMethodSchema[](12);

        _viewNoInput(schema.methods[0], "getStats", "Vault stats.", _statsOutputs());
        _viewAddressInput(schema.methods[1], "getMyInfo", "Wallet info.", _myInfoOutputs());
        _viewAddressInputSingle(schema.methods[2], "pendingNftDividends", "NFT BNB.", "amount", 18);
        _viewAddressInputSingle(schema.methods[3], "pendingLossDividends", "Loss BNB.", "amount", 18);
        _writeMintNFT(schema.methods[4]);
        _writeEnterQueue(schema.methods[5]);
        _writeLeaveQueue(schema.methods[6]);
        _writeRevealSeed(schema.methods[7]);
        _writeMatchId(schema.methods[8], "claimRevealTimeoutWin", "After timeout, a revealer may claim if the opponent did not reveal.");
        _writeMatchId(schema.methods[9], "emergencyCancelMatch", "After timeout, cancel only if neither player revealed; refunds tokens and unlocks NFTs.");
        _writeNoInput(schema.methods[10], "claimNftDividends", "Claim NFT BNB.");
        _writeNoInput(schema.methods[11], "claimLossDividends", "Claim Loss BNB.");
    }

    function _settleMatch(uint256 matchId, uint256 randomness) private {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        bool aWins = randomness % 2 == 0;
        _settleMatchWithWinner(matchId, aWins ? matchInfo.playerA : matchInfo.playerB);
    }

    function _settleMatchWithWinner(uint256 matchId, address winner) private {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        matchInfo.settled = true;

        bool aWins = winner == matchInfo.playerA;
        address loser = aWins ? matchInfo.playerB : matchInfo.playerA;
        uint256 winnerNft = aWins ? matchInfo.nftA : matchInfo.nftB;
        uint256 loserNft = aWins ? matchInfo.nftB : matchInfo.nftA;
        uint256 betAmount = matchInfo.betAmount;

        uint256 winnerPayout = betAmount + (betAmount * 7_000 / BPS_DENOMINATOR);
        uint256 burnAmount = betAmount * 1_500 / BPS_DENOMINATOR;
        uint256 lossBufferAmount = betAmount - (winnerPayout - betAmount) - burnAmount;

        token.safeTransfer(winner, winnerPayout);
        _sendToDead(burnAmount);
        pvpLossTokenBuffer += lossBufferAmount;

        _settleNftAccount(loser);
        entryNft.unlockByVault(winnerNft);
        entryNft.burnByVault(loserNft);
        _clearActive(winner, winnerNft);
        _clearActive(loser, loserNft);
        _addLossQuota(loser, getTokenPriceBnb(betAmount) * 150 / 100);

        emit MatchSettled(matchId, winner, loser, betAmount);
    }

    function _swapTokensForBnb(uint256 amount, uint256 minOut, uint256 deadline) private returns (uint256 gained) {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = router.WETH();

        token.forceApprove(address(router), amount);
        uint256 beforeBalance = address(this).balance;
        _converting = true;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, minOut, path, address(this), deadline);
        _converting = false;
        gained = address(this).balance - beforeBalance;
        if (gained < minOut) revert SlippageExceeded();
    }

    function getTokenPriceBnb(uint256 amount) public view returns (uint256) {
        return amount * tokenPriceBnbPerToken / 1 ether;
    }

    function _addNftBnb(uint256 amount) private {
        if (amount == 0) return;
        if (entryNft.activeSupply() == 0) {
            nftUndistributedBnb += amount;
            return;
        }
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / entryNft.activeSupply();
    }

    function _addLossBnb(uint256 amount) private {
        if (amount == 0) return;
        if (totalLossQuota == 0) {
            lossUndistributedBnb += amount;
            return;
        }
        uint256 alloc = amount > totalLossQuota ? totalLossQuota : amount;
        uint256 rest = amount - alloc;
        lossReservedBnb += alloc;
        accLossBnbPerQuota += alloc * MAGNITUDE / totalLossQuota;
        if (rest > 0) {
            lossUndistributedBnb += rest;
        }
    }

    function _indexPendingNftBnb() private {
        uint256 amount = nftUndistributedBnb;
        uint256 supply = entryNft.activeSupply();
        if (amount == 0 || supply == 0) return;
        nftUndistributedBnb = 0;
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / supply;
    }

    function _addLossQuota(address user, uint256 quota) private {
        if (quota == 0) return;
        _settleLossAccount(user);
        lossQuotaOf[user] += quota;
        totalLossQuota += quota;
        _lossRewardDebt[user] = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
    }

    function _settleNftAccount(address user) private {
        _settleNftAccountToBalance(user, entryNft.balanceOf(user));
    }

    function _settleNftAccountToBalance(address user, uint256 newBalance) private {
        uint256 oldBalance = entryNft.balanceOf(user);
        uint256 accumulated = oldBalance * accNftBnbPerShare / MAGNITUDE;
        uint256 debt = _nftRewardDebt[user];
        if (accumulated > debt) _nftCredit[user] += accumulated - debt;
        _nftRewardDebt[user] = newBalance * accNftBnbPerShare / MAGNITUDE;
    }

    function _settleLossAccount(address user) private {
        uint256 accumulated = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
        uint256 debt = _lossRewardDebt[user];
        if (accumulated > debt) _lossCredit[user] += accumulated - debt;
        _lossRewardDebt[user] = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
    }

    function _pullTokens(address from, uint256 requestedAmount) private returns (uint256 actualReceived) {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), requestedAmount);
        actualReceived = token.balanceOf(address(this)) - beforeBalance;
    }

    function _sendToDead(uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(DEAD);
        token.safeTransfer(DEAD, amount);
        uint256 actualDeadReceived = token.balanceOf(DEAD) - beforeBalance;
        totalBurnedToken += actualDeadReceived;
    }

    function _clearActive(address player, uint256 nftId) private {
        playerInActiveGame[player] = false;
        nftInActiveGame[nftId] = false;
    }

    function _isGuardian(address account) private view returns (bool) {
        if (guardianOverride != address(0) && account == guardianOverride) return true;
        if (block.chainid != 56 && block.chainid != 97) return false;
        return account == _getGuardian();
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _viewNoInput(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        FieldDescriptor[] memory outputs
    ) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](0);
        method.outputs = outputs;
        method.approvals = new ApproveAction[](0);
    }

    function _viewAddressInput(VaultMethodSchema memory method, string memory name, string memory methodDescription, FieldDescriptor[] memory outputs)
        private
        pure
    {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("user", "address", "Wallet address to query.", 0);
        method.outputs = outputs;
        method.approvals = new ApproveAction[](0);
    }

    function _viewAddressInputSingle(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        string memory outputName,
        uint8 decimals
    ) private pure {
        FieldDescriptor[] memory outputs = new FieldDescriptor[](1);
        outputs[0] = FieldDescriptor(outputName, "uint256", methodDescription, decimals);
        _viewAddressInput(method, name, methodDescription, outputs);
    }

    function _writeMintNFT(VaultMethodSchema memory method) private pure {
        method.name = "mintNFT";
        method.description = "Mint NFT.";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tokenAmount", "uint256", "Token amount.", 18);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "tokenAmount");
        method.isWriteMethod = true;
    }

    function _writeEnterQueue(VaultMethodSchema memory method) private pure {
        method.name = "enterQueue";
        method.description =
            "Enter with NFT. seedCommitment=keccak256(abi.encodePacked(userAddress, secretSeed)); save secretSeed for revealSeed. Late or missing reveal can let opponent claim timeout win. Official site auto-handles seed/reveal.";
        method.inputs = new FieldDescriptor[](4);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", "Tier id.", 0);
        method.inputs[1] = FieldDescriptor("nftId", "uint256", "NFT id.", 0);
        method.inputs[2] = FieldDescriptor("betAmount", "uint256", "Bet amount.", 18);
        method.inputs[3] = FieldDescriptor("seedCommitment", "bytes32", "Hash of userAddress and secretSeed.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "betAmount");
        method.isWriteMethod = true;
    }

    function _writeRevealSeed(VaultMethodSchema memory method) private pure {
        method.name = "revealSeed";
        method.description = "Reveal saved secretSeed after match. If you lose it or reveal too late, the opponent may claim timeout win.";
        method.inputs = new FieldDescriptor[](2);
        method.inputs[0] = FieldDescriptor("matchId", "uint256", "Match id.", 0);
        method.inputs[1] = FieldDescriptor("secretSeed", "bytes32", "Secret seed used for seedCommitment.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeLeaveQueue(VaultMethodSchema memory method) private pure {
        method.name = "leaveQueue";
        method.description = "Leave queue.";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", "Tier id.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeNoInput(VaultMethodSchema memory method, string memory name, string memory methodDescription)
        private
        pure
    {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeMatchId(VaultMethodSchema memory method, string memory name, string memory methodDescription)
        private
        pure
    {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("matchId", "uint256", "Match id.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _statsOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](13);
        outputs[0] = FieldDescriptor("tokenAddress", "address", "Token.", 0);
        outputs[1] = FieldDescriptor("nftAddress", "address", "NFT.", 0);
        outputs[2] = FieldDescriptor("totalMinted", "uint256", "Minted.", 0);
        outputs[3] = FieldDescriptor("liveNftSupply", "uint256", "Live NFTs.", 0);
        outputs[4] = FieldDescriptor("nftMintTokenBuffer", "uint256", "NFT token buffer.", 18);
        outputs[5] = FieldDescriptor("lossMintTokenBuffer", "uint256", "Loss token buffer.", 18);
        outputs[6] = FieldDescriptor("pvpLossTokenBuffer", "uint256", "PVP loss buffer.", 18);
        outputs[7] = FieldDescriptor("nftReservedBnb", "uint256", "NFT BNB.", 18);
        outputs[8] = FieldDescriptor("lossReservedBnb", "uint256", "Loss BNB.", 18);
        outputs[9] = FieldDescriptor("nftUndistributedBnb", "uint256", "NFT pending BNB.", 18);
        outputs[10] = FieldDescriptor("lossUndistributedBnb", "uint256", "Loss pending BNB.", 18);
        outputs[11] = FieldDescriptor("totalLossQuota", "uint256", "Loss quota.", 18);
        outputs[12] = FieldDescriptor("totalBurnedToken", "uint256", "DEAD tokens.", 18);
    }

    function _myInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](5);
        outputs[0] = FieldDescriptor("nftBalance", "uint256", "NFT balance.", 0);
        outputs[1] = FieldDescriptor("pendingNftBnb", "uint256", "NFT BNB.", 18);
        outputs[2] = FieldDescriptor("pendingLossBnb", "uint256", "Loss BNB.", 18);
        outputs[3] = FieldDescriptor("lossQuota", "uint256", "Loss quota.", 18);
        outputs[4] = FieldDescriptor("lossClaimed", "uint256", "Loss claimed.", 18);
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
