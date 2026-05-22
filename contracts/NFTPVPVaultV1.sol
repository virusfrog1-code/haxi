// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {PvpEntryNFT} from "./PvpEntryNFT.sol";
import {NFTPVPVaultV1SchemaHelper} from "./NFTPVPVaultV1SchemaHelper.sol";

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

interface IVRFCoordinatorV25 {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

contract NFTPVPVaultV1 is VaultBaseV2, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant NFT_PRICE = 50_000 ether;
    uint256 public constant MAX_BET_AMOUNT = 2_000_000 ether;
    uint8 public constant MAX_NFT_STAKE = 40;
    uint256 private constant MAGNITUDE = 1e36;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    PvpEntryNFT public immutable entryNft;
    NFTPVPVaultV1SchemaHelper public immutable schemaHelper;
    IVRFCoordinatorV25 public immutable vrfCoordinator;
    bytes32 public immutable vrfKeyHash;
    uint256 public immutable vrfSubId;
    uint32 public immutable vrfCallbackGasLimit;
    uint16 public immutable vrfRequestConfirmations;
    IPancakeLikeRouter public router;
    address public guardianOverride;

    uint256 public tokenPriceBnbPerToken;
    uint256 public vrfTimeout = 1 days;
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

    enum StakeMode {
        TOKEN,
        NFT
    }

    struct Tier {
        uint256 tokenAmount;
        uint8 nftCount;
        bool enabled;
    }

    struct QueueEntry {
        address player;
        StakeMode mode;
        uint8 nftCount;
        uint256[40] nftIds;
        uint256 stakeAmount;
    }

    struct MatchInfo {
        address playerA;
        address playerB;
        StakeMode mode;
        uint8 nftCountA;
        uint8 nftCountB;
        uint256[40] nftIdsA;
        uint256[40] nftIdsB;
        uint256 stakeAmount;
        uint256 vrfRequestId;
        uint256 randomWord;
        bool randomnessFulfilled;
        uint256 createdAt;
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
    mapping(uint256 => mapping(uint8 => QueueEntry)) private _queueOfTier;
    mapping(uint256 => MatchInfo) public matches;
    mapping(uint256 => uint256) public matchOfRequest;
    mapping(uint256 => bool) public nftInActiveGame;
    mapping(address => bool) public playerInActiveGame;
    mapping(address => uint256) private _nftRewardWeightOf;

    mapping(address => uint256) private _nftRewardDebt;
    mapping(address => uint256) private _nftCredit;
    mapping(address => uint256) public claimedNftDividends;

    mapping(address => uint256) public lossQuotaOf;
    mapping(address => uint256) private _lossRewardDebt;
    mapping(address => uint256) private _lossCredit;
    mapping(address => uint256) public claimedLossDividends;

    bool private _converting;

    event NftMinted(address indexed user, uint256 quantity, uint256 requestedTokenAmount, uint256 actualReceived);
    event QueueEntered(uint256 indexed tierId, address indexed user, StakeMode mode, uint256 stakeAmount, uint256 nftCount);
    event QueueLeft(uint256 indexed tierId, address indexed user, StakeMode mode, uint256 stakeAmount, uint256 nftCount);
    event MatchRequested(uint256 indexed matchId, uint256 indexed tierId, address indexed playerA, address playerB);
    event RandomnessRequested(uint256 indexed matchId, uint256 indexed requestId);
    event RandomnessFulfilled(uint256 indexed matchId, uint256 indexed requestId, uint256 randomWord);
    event MatchSettled(uint256 indexed matchId, address indexed winner, address indexed loser, StakeMode mode, uint256 stakeAmount);
    event MatchCancelled(uint256 indexed matchId, address indexed playerA, address indexed playerB, StakeMode mode, uint256 stakeAmount);
    event MintBuffersConverted(uint256 nftTokens, uint256 lossTokens, uint256 nftBnb, uint256 lossBnb);
    event NftDividendsClaimed(address indexed user, uint256 amount);
    event LossDividendsClaimed(address indexed user, uint256 amount);
    event BnbReceived(address indexed sender, uint256 amount, uint256 nftAmount, uint256 lossAmount);
    event RescueExcessBNB(address indexed to, uint256 amount);
    event TierUpdated(uint256 indexed tierId, uint256 tokenAmount, uint8 nftCount, bool enabled);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event GuardianOverrideUpdated(address indexed oldGuardian, address indexed newGuardian);
    event TokenPriceBnbPerTokenUpdated(uint256 oldPrice, uint256 newPrice);
    event VrfTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

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
    error RandomnessPending();
    error VrfPeriodActive();
    error InvalidVrfCoordinator();
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
        uint256 tokenPriceBnbPerToken_,
        address vrfCoordinator_,
        uint256 vrfSubId_,
        bytes32 vrfKeyHash_,
        uint32 vrfCallbackGasLimit_,
        uint16 vrfRequestConfirmations_
    ) Ownable(initialOwner_) {
        if (token_ == address(0) || router_ == address(0) || initialOwner_ == address(0) || vrfCoordinator_ == address(0)) {
            revert ZeroAddress();
        }
        if (tokenPriceBnbPerToken_ == 0) revert InvalidPrice();
        token = IERC20(token_);
        router = IPancakeLikeRouter(router_);
        guardianOverride = guardianOverride_;
        tokenPriceBnbPerToken = tokenPriceBnbPerToken_;
        vrfCoordinator = IVRFCoordinatorV25(vrfCoordinator_);
        vrfSubId = vrfSubId_;
        vrfKeyHash = vrfKeyHash_;
        vrfCallbackGasLimit = vrfCallbackGasLimit_;
        vrfRequestConfirmations = vrfRequestConfirmations_;
        entryNft = new PvpEntryNFT("PVP Entry NFT", "PVPNFT", address(this), initialOwner_);
        schemaHelper = new NFTPVPVaultV1SchemaHelper();
        _setTier(0, 50_000 ether, 1, true);
        _setTier(1, 150_000 ether, 3, true);
        _setTier(2, 250_000 ether, 5, true);
        _setTier(3, 500_000 ether, 10, true);
        _setTier(4, 1_000_000 ether, 20, true);
        _setTier(5, 2_000_000 ether, 40, true);
    }

    receive() external payable {
        if (_converting) return;
        uint256 nftAmount = msg.value / 2;
        uint256 lossAmount = msg.value - nftAmount;
        _addNftBnb(nftAmount);
        _addLossBnb(lossAmount);
        emit BnbReceived(msg.sender, msg.value, nftAmount, lossAmount);
    }

    function mintNFTByCount(uint256 quantity) external nonReentrant {
        if (quantity == 0) revert InvalidTokenAmount();
        _mintNFT(msg.sender, quantity * NFT_PRICE);
    }

    function mintNFT(uint256 tokenAmount) external nonReentrant {
        _mintNFT(msg.sender, tokenAmount);
    }

    function _mintNFT(address minter, uint256 tokenAmount) private {
        if (tokenAmount == 0) revert InvalidTokenAmount();
        uint256 actualReceived = _pullTokens(minter, tokenAmount);
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
            entryNft.mintByVault(minter);
        }
        _indexPendingNftBnb();

        emit NftMinted(minter, quantity, tokenAmount, actualReceived);
    }

    function mergeBaseNFTs(uint256[] calldata tokenIds) external nonReentrant returns (uint256 tokenId) {
        tokenId = entryNft.mergeBaseNFTsByVault(msg.sender, tokenIds);
        _indexPendingNftBnb();
    }

    function enterTokenQueue(uint256 tierId, uint256 tokenAmount) external nonReentrant {
        Tier memory tier = tiers[tierId];
        if (!tier.enabled) revert InvalidTier();
        if (tokenAmount != tier.tokenAmount || tokenAmount > MAX_BET_AMOUNT) revert InvalidBetAmount();
        if (playerInActiveGame[msg.sender]) revert PlayerAlreadyActive();

        uint256 actualReceived = _pullTokens(msg.sender, tokenAmount);
        if (actualReceived != tokenAmount) revert InvalidBetAmount();
        playerInActiveGame[msg.sender] = true;

        uint256[40] memory emptyNfts;
        _enterQueue(tierId, StakeMode.TOKEN, 0, emptyNfts, tokenAmount);
    }

    function enterNftQueue(uint256 tierId, uint256[] calldata nftIds) external nonReentrant {
        Tier memory tier = tiers[tierId];
        if (!tier.enabled) revert InvalidTier();
        if (nftIds.length == 0 || nftIds.length > MAX_NFT_STAKE) revert InvalidBetAmount();
        if (tier.tokenAmount > MAX_BET_AMOUNT) revert InvalidBetAmount();
        if (playerInActiveGame[msg.sender]) revert PlayerAlreadyActive();

        uint256[40] memory packedNfts;
        uint256 units;
        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            if (entryNft.ownerOf(nftId) != msg.sender) revert NotNftOwner();
            if (nftInActiveGame[nftId]) revert NftAlreadyActive();
            for (uint256 j = 0; j < i; j++) {
                if (packedNfts[j] == nftId) revert NftAlreadyActive();
            }
            entryNft.lockByVault(nftId);
            nftInActiveGame[nftId] = true;
            packedNfts[i] = nftId;
            units += entryNft.nftBaseUnits(nftId);
        }
        if (units != tier.nftCount) revert InvalidBetAmount();
        playerInActiveGame[msg.sender] = true;

        _enterQueue(tierId, StakeMode.NFT, uint8(nftIds.length), packedNfts, tier.tokenAmount);
    }

    function _enterQueue(
        uint256 tierId,
        StakeMode mode,
        uint8 nftCount,
        uint256[40] memory nftIds,
        uint256 stakeAmount
    ) private {
        QueueEntry storage queued = _queueOfTier[tierId][uint8(mode)];
        if (queued.player == msg.sender) revert QueueOccupied();

        if (queued.player == address(0)) {
            queued.player = msg.sender;
            queued.mode = mode;
            queued.nftCount = nftCount;
            queued.nftIds = nftIds;
            queued.stakeAmount = stakeAmount;
            emit QueueEntered(tierId, msg.sender, mode, stakeAmount, nftCount);
            return;
        }

        address playerA = queued.player;
        uint8 queuedNftCount = queued.nftCount;
        uint256[40] memory queuedNfts = queued.nftIds;
        uint256 queuedStakeAmount = queued.stakeAmount;
        delete _queueOfTier[tierId][uint8(mode)];
        uint256 matchId = nextMatchId++;
        MatchInfo storage matchInfo = matches[matchId];
        matchInfo.playerA = playerA;
        matchInfo.playerB = msg.sender;
        matchInfo.mode = mode;
        matchInfo.nftCountA = queuedNftCount;
        matchInfo.nftCountB = nftCount;
        matchInfo.nftIdsA = queuedNfts;
        matchInfo.nftIdsB = nftIds;
        matchInfo.stakeAmount = queuedStakeAmount;
        matchInfo.createdAt = block.timestamp;
        matchInfo.vrfRequestId = _requestRandomness(matchId);
        emit MatchRequested(matchId, tierId, playerA, msg.sender);
        emit RandomnessRequested(matchId, matchInfo.vrfRequestId);
    }

    function leaveQueue(uint256 tierId) external nonReentrant {
        QueueEntry memory queued = _queueOfTier[tierId][uint8(StakeMode.TOKEN)];
        uint8 modeKey = uint8(StakeMode.TOKEN);
        if (queued.player != msg.sender) {
            queued = _queueOfTier[tierId][uint8(StakeMode.NFT)];
            modeKey = uint8(StakeMode.NFT);
        }
        if (queued.player == address(0)) revert NoQueuedEntry();
        if (queued.player != msg.sender) revert NotQueuedPlayer();
        delete _queueOfTier[tierId][modeKey];
        playerInActiveGame[msg.sender] = false;
        if (queued.mode == StakeMode.TOKEN) {
            token.safeTransfer(msg.sender, queued.stakeAmount);
        } else {
            _unlockNfts(queued.nftIds, queued.nftCount);
            _clearNftsActive(queued.nftIds, queued.nftCount);
        }
        emit QueueLeft(tierId, msg.sender, queued.mode, queued.stakeAmount, queued.nftCount);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert InvalidVrfCoordinator();
        uint256 matchId = matchOfRequest[requestId];
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        matchInfo.randomWord = randomWords[0];
        matchInfo.randomnessFulfilled = true;
        emit RandomnessFulfilled(matchId, requestId, randomWords[0]);
    }

    function settleMatch(uint256 matchId) external nonReentrant {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        if (!matchInfo.randomnessFulfilled) revert RandomnessPending();
        _settleMatch(matchId, matchInfo.randomWord);
    }

    function emergencyCancelMatch(uint256 matchId) external nonReentrant {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        if (block.timestamp < matchInfo.createdAt + vrfTimeout) revert VrfPeriodActive();
        if (matchInfo.randomnessFulfilled) revert RandomnessPending();
        if (msg.sender != matchInfo.playerA && msg.sender != matchInfo.playerB && msg.sender != owner() && !_isGuardian(msg.sender)) {
            revert NotOwnerOrGuardian();
        }
        matchInfo.settled = true;

        _clearActive(matchInfo.playerA);
        _clearActive(matchInfo.playerB);
        if (matchInfo.mode == StakeMode.TOKEN) {
            token.safeTransfer(matchInfo.playerA, matchInfo.stakeAmount);
            token.safeTransfer(matchInfo.playerB, matchInfo.stakeAmount);
        } else {
            _unlockNfts(matchInfo.nftIdsA, matchInfo.nftCountA);
            _unlockNfts(matchInfo.nftIdsB, matchInfo.nftCountB);
            _clearNftsActive(matchInfo.nftIdsA, matchInfo.nftCountA);
            _clearNftsActive(matchInfo.nftIdsB, matchInfo.nftCountB);
        }

        emit MatchCancelled(matchId, matchInfo.playerA, matchInfo.playerB, matchInfo.mode, matchInfo.stakeAmount);
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

    function onNftBalanceChange(address from, address to, uint256 rewardWeight) external {
        if (msg.sender != address(entryNft)) revert NotNftContract();
        if (from == to) return;
        if (from != address(0)) {
            _settleNftAccount(from);
            _nftRewardWeightOf[from] -= rewardWeight;
        }
        if (to != address(0)) {
            _settleNftAccount(to);
            _nftRewardWeightOf[to] += rewardWeight;
        }
    }

    function setTier(uint256 tierId, uint256 tokenAmount, uint8 nftCount, bool enabled) external onlyOwnerOrGuardian {
        _setTier(tierId, tokenAmount, nftCount, enabled);
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

    function setVrfTimeout(uint256 newTimeout) external onlyOwnerOrGuardian {
        uint256 oldTimeout = vrfTimeout;
        vrfTimeout = newTimeout;
        emit VrfTimeoutUpdated(oldTimeout, newTimeout);
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
        uint256 accumulated = _nftRewardWeightOf[user] * accNftBnbPerShare / MAGNITUDE;
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

    function nftLevel(uint256 tokenId) external view returns (uint8) {
        return entryNft.nftLevel(tokenId);
    }

    function nftType(uint256 tokenId) external view returns (uint8) {
        return entryNft.nftType(tokenId);
    }

    function nftRewardWeight(uint256 tokenId) external view returns (uint256) {
        return entryNft.nftRewardWeight(tokenId);
    }

    function nftBaseUnits(uint256 tokenId) external view returns (uint256) {
        return entryNft.nftBaseUnits(tokenId);
    }

    function isVpnEligible(uint256 tokenId) external view returns (bool) {
        return entryNft.isVpnEligible(tokenId);
    }

    function description() public view override returns (string memory) {
        return string.concat(
            unicode"NFT PVP 双模式分红金库。当前存活 NFT ",
            _toString(entryNft.activeSupply()),
            unicode"，NFT 分红池 BNB ",
            _toString(nftReservedBnb),
            unicode"，LossVault 池 BNB ",
            _toString(lossReservedBnb),
            unicode"，NFT 未分配 BNB ",
            _toString(nftUndistributedBnb),
            unicode"，LossVault 未分配 BNB ",
            _toString(lossUndistributedBnb),
            unicode"。基础 NFT 铸造价格为 50,000 Token；10 张基础 NFT 可合成 1 张高级 NFT，高级 NFT 拥有 12 张基础 NFT 分红权重和永久 VPN 权益。PVP 使用 Chainlink VRF 自动开奖，owner / guardian 不能手动指定赢家。交易税应为 4%，其中 50% 分配给 NFT 持有人，50% 进入 LossVault，分红资产为 BNB。getTokenPriceBnb 当前仅为测试网/预上线使用的 router spot quote，主网正式生产前必须替换为 TWAP / 固定估值 / 抗操纵报价。"
        );
    }

    function vaultUISchema() public view override returns (VaultUISchema memory schema) {
        return schemaHelper.vaultUISchema();
    }

    function _settleMatch(uint256 matchId, uint256 randomness) private {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        bool aWins = randomness % 2 == 0;
        _settleMatchWithWinner(matchId, aWins ? matchInfo.playerA : matchInfo.playerB);
    }

    function _requestRandomness(uint256 matchId) private returns (uint256 requestId) {
        requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV25.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: ""
            })
        );
        matchOfRequest[requestId] = matchId;
    }

    function _settleMatchWithWinner(uint256 matchId, address winner) private {
        MatchInfo storage matchInfo = matches[matchId];
        if (matchInfo.playerA == address(0)) revert NoQueuedEntry();
        if (matchInfo.settled) revert MatchAlreadySettled();
        matchInfo.settled = true;

        bool aWins = winner == matchInfo.playerA;
        address loser = aWins ? matchInfo.playerB : matchInfo.playerA;
        uint256[40] memory winnerNfts = aWins ? matchInfo.nftIdsA : matchInfo.nftIdsB;
        uint256[40] memory loserNfts = aWins ? matchInfo.nftIdsB : matchInfo.nftIdsA;
        uint8 winnerNftCount = aWins ? matchInfo.nftCountA : matchInfo.nftCountB;
        uint8 loserNftCount = aWins ? matchInfo.nftCountB : matchInfo.nftCountA;
        uint256 stakeAmount = matchInfo.stakeAmount;

        if (matchInfo.mode == StakeMode.TOKEN) {
            uint256 winnerPayout = stakeAmount + (stakeAmount * 7_000 / BPS_DENOMINATOR);
            uint256 burnAmount = stakeAmount * 1_500 / BPS_DENOMINATOR;
            uint256 lossBufferAmount = stakeAmount - (winnerPayout - stakeAmount) - burnAmount;

            token.safeTransfer(winner, winnerPayout);
            _sendToDead(burnAmount);
            pvpLossTokenBuffer += lossBufferAmount;
        } else {
            _unlockNfts(winnerNfts, winnerNftCount);
            _transferNfts(loser, winner, loserNfts, loserNftCount);
            _clearNftsActive(winnerNfts, winnerNftCount);
            _clearNftsActive(loserNfts, loserNftCount);
        }

        _clearActive(winner);
        _clearActive(loser);
        _addLossQuota(loser, getTokenPriceBnb(stakeAmount) * 150 / 100);

        emit MatchSettled(matchId, winner, loser, matchInfo.mode, stakeAmount);
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
        uint256 totalWeight = entryNft.totalRewardWeight();
        if (totalWeight == 0) {
            nftUndistributedBnb += amount;
            return;
        }
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / totalWeight;
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
        uint256 totalWeight = entryNft.totalRewardWeight();
        if (amount == 0 || totalWeight == 0) return;
        nftUndistributedBnb = 0;
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / totalWeight;
    }

    function _addLossQuota(address user, uint256 quota) private {
        if (quota == 0) return;
        _settleLossAccount(user);
        lossQuotaOf[user] += quota;
        totalLossQuota += quota;
        _lossRewardDebt[user] = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
    }

    function _settleNftAccount(address user) private {
        uint256 weight = _nftRewardWeightOf[user];
        uint256 accumulated = weight * accNftBnbPerShare / MAGNITUDE;
        uint256 debt = _nftRewardDebt[user];
        if (accumulated > debt) _nftCredit[user] += accumulated - debt;
        _nftRewardDebt[user] = weight * accNftBnbPerShare / MAGNITUDE;
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

    function _setTier(uint256 tierId, uint256 tokenAmount, uint8 nftCount, bool enabled) private {
        if (
            tokenAmount == 0 || tokenAmount > MAX_BET_AMOUNT || nftCount == 0 || nftCount > MAX_NFT_STAKE
                || tokenAmount != uint256(nftCount) * NFT_PRICE
        ) {
            revert InvalidBetAmount();
        }
        tiers[tierId] = Tier(tokenAmount, nftCount, enabled);
        emit TierUpdated(tierId, tokenAmount, nftCount, enabled);
    }

    function _unlockNfts(uint256[40] memory nftIds, uint8 nftCount) private {
        for (uint256 i = 0; i < nftCount; i++) {
            entryNft.unlockByVault(nftIds[i]);
        }
    }

    function _transferNfts(address from, address to, uint256[40] memory nftIds, uint8 nftCount) private {
        for (uint256 i = 0; i < nftCount; i++) {
            entryNft.transferByVault(from, to, nftIds[i]);
        }
    }

    function _clearNftsActive(uint256[40] memory nftIds, uint8 nftCount) private {
        for (uint256 i = 0; i < nftCount; i++) {
            nftInActiveGame[nftIds[i]] = false;
        }
    }

    function _clearActive(address player) private {
        playerInActiveGame[player] = false;
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
