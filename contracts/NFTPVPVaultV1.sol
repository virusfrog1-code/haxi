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

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant NFT_PRICE = 100_000 ether;
    uint256 private constant MAX_BET_AMOUNT = 10_000_000 ether;
    uint256 private constant ROUND_JOIN_DURATION = 5 minutes;
    uint256 private constant MAX_ROUND_PLAYERS = 50;
    uint256 private constant MAGNITUDE = 1e36;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 private immutable token;
    PvpEntryNFT private immutable entryNft;
    NFTPVPVaultV1SchemaHelper private immutable schemaHelper;
    IVRFCoordinatorV25 private immutable vrfCoordinator;
    bytes32 private immutable vrfKeyHash;
    uint256 private immutable vrfSubId;
    uint32 private immutable vrfCallbackGasLimit;
    uint16 private immutable vrfRequestConfirmations;
    IPancakeLikeRouter private router;
    address private guardianOverride;

    uint256 private tokenPriceBnbPerToken;
    uint256 private vrfTimeout = 1 days;
    uint256 private nextRoundId = 1;

    uint256 private nftMintTokenBuffer;
    uint256 private lossMintTokenBuffer;
    uint256 private pvpLossTokenBuffer;
    uint256 private totalBurnedToken;
    uint256 private totalNftRewardWeight;

    uint256 private nftReservedBnb;
    uint256 private lossReservedBnb;
    uint256 private nftUndistributedBnb;
    uint256 private lossUndistributedBnb;

    uint256 private accNftBnbPerShare;
    uint256 private accLossBnbPerQuota;
    uint256 private totalLossQuota;
    uint256 private totalLossQuotaGranted;
    uint256 private totalClaimedLossBnb;
    uint256 private totalClaimedNftBnb;

    uint256 private totalRoundsCreated;
    uint256 private totalRoundsSettled;
    uint256 private totalRoundsCancelled;
    uint256 private openRoundCount;
    uint256 private totalParticipantEntries;
    uint256 private totalWinners;
    uint256 private totalLosers;

    enum RoundStatus {
        None,
        Open,
        RandomnessRequested,
        RandomReady,
        Settled,
        Cancelled
    }

    struct Tier {
        uint256 tokenAmount;
        bool enabled;
    }

    struct Round {
        uint256 tierId;
        uint256 betAmount;
        uint256 startTime;
        uint256 joinDeadline;
        uint256 requestTime;
        uint256 vrfRequestId;
        uint256 randomWord;
        address winner;
        RoundStatus status;
    }

    struct Participant {
        bool joined;
        uint256 nftId;
        uint256 stakeAmount;
    }

    struct Stats {
        address tokenAddress;
        address nftAddress;
        uint256 totalMinted;
        uint256 liveNftSupply;
        uint256 totalBurnedNFT;
        uint256 effectiveNftRewards;
        uint256 lockedNftsInRounds;
        uint256 nftMintTokenBuffer;
        uint256 lossMintTokenBuffer;
        uint256 pvpLossTokenBuffer;
        uint256 nftReservedBnb;
        uint256 lossReservedBnb;
        uint256 nftUndistributedBnb;
        uint256 lossUndistributedBnb;
        uint256 totalLossQuota;
        uint256 totalLossQuotaGranted;
        uint256 totalClaimedLossBnb;
        uint256 totalClaimedNftBnb;
        uint256 totalBurnedToken;
        uint256 totalRounds;
        uint256 settledRounds;
        uint256 openRounds;
        uint256 totalParticipantEntries;
        uint256 totalWinners;
        uint256 totalLosers;
        uint256[5] currentRoundIds;
        uint256[5] currentRoundPlayers;
        uint256[5] currentRoundDeadlines;
    }

    struct MyInfo {
        uint256 nftBalance;
        uint256 effectiveNftRewards;
        uint256 pendingNftBnb;
        uint256 pendingLossBnb;
        uint256 lossPrincipalBnb;
        uint256 lossQuota;
        uint256 lossClaimed;
        uint256 lossQuotaRemaining;
        uint256 roundsJoined;
        uint256 wins;
        uint256 losses;
        uint256 currentRoundId;
        uint256 currentTierId;
        uint256 stakedNftId;
        uint256 stakedTokenAmount;
        uint8 currentRoundStatus;
        uint256 currentRoundPlayers;
        bool canRequestVrf;
        bool canSettle;
        bool canCancel;
    }

    struct RoundView {
        uint256 roundId;
        uint256 tierId;
        uint256 betAmount;
        uint256 startTime;
        uint256 joinDeadline;
        uint256 requestTime;
        uint256 vrfRequestId;
        uint256 randomWord;
        address winner;
        uint8 status;
        uint256 participantCount;
        bool canRequestVrf;
        bool canSettle;
        bool canCancel;
    }

    mapping(uint256 => Tier) public tiers;
    mapping(uint256 => Round) private rounds;
    mapping(uint256 => address[]) private _roundPlayers;
    mapping(uint256 => mapping(address => Participant)) private _roundParticipant;
    mapping(uint256 => mapping(address => uint256)) private _roundPlayerIndexPlusOne;
    mapping(uint256 => uint256) private roundOfRequest;
    mapping(uint256 => uint256) private currentRoundOfTier;
    mapping(uint256 => bool) private nftInActiveGame;
    mapping(uint256 => bool) private nftRewardActive;

    mapping(address => uint256) private playerCurrentRound;
    mapping(address => uint256) private _nftWeightOf;
    mapping(address => uint256) private _nftRewardDebt;
    mapping(address => uint256) private _nftCredit;
    mapping(address => uint256) private claimedNftDividends;

    mapping(address => uint256) private lossQuotaOf;
    mapping(address => uint256) private lossQuotaGrantedOf;
    mapping(address => uint256) private lossPrincipalBnbOf;
    mapping(address => uint256) private _lossRewardDebt;
    mapping(address => uint256) private _lossCredit;
    mapping(address => uint256) private claimedLossDividends;
    mapping(address => uint256) private roundsJoinedOf;
    mapping(address => uint256) private winsOf;
    mapping(address => uint256) private lossesOf;

    bool private _converting;

    event NftMinted(address indexed user, uint256 quantity, uint256 requestedTokenAmount, uint256 actualReceived);
    event RoundCreated(uint256 indexed roundId, uint256 indexed tierId, uint256 betAmount, uint256 joinDeadline);
    event RoundEntered(uint256 indexed roundId, uint256 indexed tierId, address indexed user, uint256 nftId, uint256 stakeAmount);
    event RoundLeft(uint256 indexed roundId, uint256 indexed tierId, address indexed user, uint256 nftId, uint256 stakeAmount);
    event RoundRandomnessRequested(uint256 indexed roundId, uint256 indexed requestId);
    event RoundRandomnessFulfilled(uint256 indexed roundId, uint256 indexed requestId, uint256 randomWord);
    event RoundSettled(uint256 indexed roundId, address indexed winner, uint256 participantCount, uint256 loserCount, uint256 stakeAmount);
    event RoundCancelled(uint256 indexed roundId, uint256 participantCount);
    event MintBuffersConverted(uint256 nftTokens, uint256 lossTokens, uint256 nftBnb, uint256 lossBnb);
    event NftDividendsClaimed(address indexed user, uint256 amount);
    event LossDividendsClaimed(address indexed user, uint256 amount);
    event BnbReceived(address indexed sender, uint256 amount, uint256 nftAmount, uint256 lossAmount);
    event RescueExcessBNB(address indexed to, uint256 amount);
    event TierUpdated(uint256 indexed tierId, uint256 tokenAmount, bool enabled);
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
    error RoundJoinClosed();
    error RoundFull();
    error AlreadyJoinedRound();
    error NftAlreadyActive();
    error PlayerAlreadyActive();
    error NotRoundParticipant();
    error NotNftOwner();
    error NotNftContract();
    error RoundNotFound();
    error RoundNotOpen();
    error RoundTooSmall();
    error RoundRandomAlreadyRequested();
    error RoundRandomNotReady(uint256 roundId);
    error RoundAlreadySettled();
    error RoundNotExpired(uint256 roundId, uint256 deadline);
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
        uint16 vrfRequestConfirmations_,
        address schemaHelper_
    ) Ownable(initialOwner_) {
        if (
            token_ == address(0) || router_ == address(0) || initialOwner_ == address(0) || vrfCoordinator_ == address(0)
                || schemaHelper_ == address(0)
        ) {
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
        schemaHelper = NFTPVPVaultV1SchemaHelper(schemaHelper_);
        _setTier(0, 100_000 ether, true);
        _setTier(1, 500_000 ether, true);
        _setTier(2, 2_000_000 ether, true);
        _setTier(3, 5_000_000 ether, true);
        _setTier(4, 10_000_000 ether, true);
    }

    receive() external payable {
        if (_converting) return;
        uint256 nftAmount = msg.value / 2;
        uint256 lossAmount = msg.value - nftAmount;
        _addNftBnb(nftAmount);
        _addLossBnb(lossAmount);
        emit BnbReceived(msg.sender, msg.value, nftAmount, lossAmount);
    }

    function mint1NFT() external nonReentrant {
        _mintNFT(msg.sender, NFT_PRICE);
    }

    function mint2NFT() external nonReentrant {
        _mintNFT(msg.sender, NFT_PRICE * 2);
    }

    function mint5NFT() external nonReentrant {
        _mintNFT(msg.sender, NFT_PRICE * 5);
    }

    function mint10NFT() external nonReentrant {
        _mintNFT(msg.sender, NFT_PRICE * 10);
    }

    function mintNFTByCount(uint256 quantity) external nonReentrant {
        if (quantity == 0) revert InvalidTokenAmount();
        _mintNFT(msg.sender, quantity * NFT_PRICE);
    }

    function enterQueue(uint256 tierId, uint256 nftId) external nonReentrant {
        Tier memory tier = tiers[tierId];
        if (!tier.enabled) revert InvalidTier();
        if (playerCurrentRound[msg.sender] != 0) revert PlayerAlreadyActive();
        if (entryNft.ownerOf(nftId) != msg.sender) revert NotNftOwner();
        if (nftInActiveGame[nftId]) revert NftAlreadyActive();

        uint256 actualReceived = _pullTokens(msg.sender, tier.tokenAmount);
        if (actualReceived != tier.tokenAmount) revert InvalidBetAmount();

        uint256 roundId = _getOrCreateOpenRound(tierId, tier.tokenAmount);
        Round storage round = rounds[roundId];
        if (block.timestamp > round.joinDeadline) revert RoundJoinClosed();
        if (_roundPlayers[roundId].length >= MAX_ROUND_PLAYERS) revert RoundFull();
        if (_roundParticipant[roundId][msg.sender].joined) revert AlreadyJoinedRound();

        _pauseNftReward(msg.sender, nftId);
        entryNft.lockByVault(nftId);
        nftInActiveGame[nftId] = true;
        playerCurrentRound[msg.sender] = roundId;
        _roundParticipant[roundId][msg.sender] = Participant(true, nftId, tier.tokenAmount);
        _roundPlayerIndexPlusOne[roundId][msg.sender] = _roundPlayers[roundId].length + 1;
        _roundPlayers[roundId].push(msg.sender);
        roundsJoinedOf[msg.sender] += 1;
        totalParticipantEntries += 1;
        emit RoundEntered(roundId, tierId, msg.sender, nftId, tier.tokenAmount);
    }

    function leaveQueue(uint256 tierId) external nonReentrant {
        uint256 roundId = playerCurrentRound[msg.sender];
        if (roundId == 0) revert NotRoundParticipant();
        Round storage round = rounds[roundId];
        if (round.tierId != tierId) revert InvalidTier();
        if (round.status != RoundStatus.Open) revert RoundNotOpen();
        if (block.timestamp > round.joinDeadline) revert RoundJoinClosed();
        _removeParticipantAndRefund(roundId, msg.sender);
        if (_roundPlayers[roundId].length == 0) {
            round.status = RoundStatus.Cancelled;
            totalRoundsCancelled += 1;
            openRoundCount -= 1;
            if (currentRoundOfTier[tierId] == roundId) currentRoundOfTier[tierId] = 0;
            emit RoundCancelled(roundId, 0);
        }
    }

    function requestRoundRandomness(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status == RoundStatus.None) revert RoundNotFound();
        if (round.status != RoundStatus.Open) revert RoundRandomAlreadyRequested();
        if (_roundPlayers[roundId].length < 2) revert RoundTooSmall();
        if (block.timestamp < round.joinDeadline && _roundPlayers[roundId].length < MAX_ROUND_PLAYERS) {
            revert RoundNotExpired(roundId, round.joinDeadline);
        }

        round.status = RoundStatus.RandomnessRequested;
        round.requestTime = block.timestamp;
        if (openRoundCount > 0) openRoundCount -= 1;
        if (currentRoundOfTier[round.tierId] == roundId) currentRoundOfTier[round.tierId] = 0;
        round.vrfRequestId = _requestRandomness(roundId);
        emit RoundRandomnessRequested(roundId, round.vrfRequestId);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert InvalidVrfCoordinator();
        uint256 roundId = roundOfRequest[requestId];
        Round storage round = rounds[roundId];
        if (round.status != RoundStatus.RandomnessRequested) revert RoundRandomNotReady(roundId);
        round.randomWord = randomWords[0];
        round.status = RoundStatus.RandomReady;
        emit RoundRandomnessFulfilled(roundId, requestId, randomWords[0]);
    }

    function settleRound(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status == RoundStatus.None) revert RoundNotFound();
        if (round.status == RoundStatus.Settled || round.status == RoundStatus.Cancelled) revert RoundAlreadySettled();
        if (round.status != RoundStatus.RandomReady) revert RoundRandomNotReady(roundId);
        _settleRound(roundId, round.randomWord);
    }

    function emergencyCancelRound(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];
        if (round.status == RoundStatus.None) revert RoundNotFound();
        if (round.status == RoundStatus.Settled || round.status == RoundStatus.Cancelled) revert RoundAlreadySettled();

        bool soloExpired = round.status == RoundStatus.Open && _roundPlayers[roundId].length == 1 && block.timestamp >= round.joinDeadline;
        bool vrfExpired = round.status == RoundStatus.RandomnessRequested && block.timestamp >= round.requestTime + vrfTimeout;
        if (!soloExpired && !vrfExpired) {
            uint256 deadline = round.status == RoundStatus.Open ? round.joinDeadline : round.requestTime + vrfTimeout;
            revert RoundNotExpired(roundId, deadline);
        }
        if (!_roundParticipant[roundId][msg.sender].joined && msg.sender != owner() && !_isGuardian(msg.sender)) {
            revert NotRoundParticipant();
        }
        _cancelRound(roundId);
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
        if (amount > nftReservedBnb) amount = nftReservedBnb;
        _nftCredit[msg.sender] = 0;
        claimedNftDividends[msg.sender] += amount;
        totalClaimedNftBnb += amount;
        nftReservedBnb -= amount;
        _sendNative(msg.sender, amount);
        emit NftDividendsClaimed(msg.sender, amount);
    }

    function claimLossDividends() external nonReentrant {
        _settleLossAccount(msg.sender);
        uint256 amount = _lossCredit[msg.sender];
        uint256 quota = lossQuotaOf[msg.sender];
        if (amount > quota) amount = quota;
        if (amount > lossReservedBnb) amount = lossReservedBnb;
        if (amount == 0) revert NoRewards();

        _lossCredit[msg.sender] = 0;
        lossQuotaOf[msg.sender] = quota - amount;
        totalLossQuota -= amount;
        _lossRewardDebt[msg.sender] = lossQuotaOf[msg.sender] * accLossBnbPerQuota / MAGNITUDE;
        claimedLossDividends[msg.sender] += amount;
        totalClaimedLossBnb += amount;
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

    function onNftBalanceChange(address from, address to, uint256 tokenId) external {
        if (msg.sender != address(entryNft)) revert NotNftContract();
        if (from == to) return;
        if (from == address(0) && to != address(0)) {
            nftRewardActive[tokenId] = true;
            _increaseNftWeight(to);
        } else if (to == address(0)) {
            if (nftRewardActive[tokenId]) {
                nftRewardActive[tokenId] = false;
                _decreaseNftWeight(from);
            }
        } else if (nftRewardActive[tokenId]) {
            _decreaseNftWeight(from);
            _increaseNftWeight(to);
        }
    }

    function setTier(uint256 tierId, uint256 tokenAmount, bool enabled) external onlyOwnerOrGuardian {
        _setTier(tierId, tokenAmount, enabled);
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
            totalBurnedNFT: entryNft.totalBurnedNFT(),
            effectiveNftRewards: totalNftRewardWeight,
            lockedNftsInRounds: entryNft.activeSupply() - totalNftRewardWeight,
            nftMintTokenBuffer: nftMintTokenBuffer,
            lossMintTokenBuffer: lossMintTokenBuffer,
            pvpLossTokenBuffer: pvpLossTokenBuffer,
            nftReservedBnb: nftReservedBnb,
            lossReservedBnb: lossReservedBnb,
            nftUndistributedBnb: nftUndistributedBnb,
            lossUndistributedBnb: lossUndistributedBnb,
            totalLossQuota: totalLossQuota,
            totalLossQuotaGranted: totalLossQuotaGranted,
            totalClaimedLossBnb: totalClaimedLossBnb,
            totalClaimedNftBnb: totalClaimedNftBnb,
            totalBurnedToken: totalBurnedToken,
            totalRounds: totalRoundsCreated,
            settledRounds: totalRoundsSettled,
            openRounds: openRoundCount,
            totalParticipantEntries: totalParticipantEntries,
            totalWinners: totalWinners,
            totalLosers: totalLosers,
            currentRoundIds: _currentRoundIds(),
            currentRoundPlayers: _currentRoundPlayers(),
            currentRoundDeadlines: _currentRoundDeadlines()
        });
    }

    function getMyInfo(address user) public view returns (MyInfo memory info) {
        uint256 roundId = playerCurrentRound[user];
        Participant memory participant = roundId == 0 ? Participant(false, 0, 0) : _roundParticipant[roundId][user];
        Round memory round = rounds[roundId];
        info = MyInfo({
            nftBalance: entryNft.balanceOf(user),
            effectiveNftRewards: _nftWeightOf[user],
            pendingNftBnb: pendingNftDividends(user),
            pendingLossBnb: pendingLossDividends(user),
            lossPrincipalBnb: lossPrincipalBnbOf[user],
            lossQuota: lossQuotaGrantedOf[user],
            lossClaimed: claimedLossDividends[user],
            lossQuotaRemaining: lossQuotaOf[user],
            roundsJoined: roundsJoinedOf[user],
            wins: winsOf[user],
            losses: lossesOf[user],
            currentRoundId: roundId,
            currentTierId: round.tierId,
            stakedNftId: participant.nftId,
            stakedTokenAmount: participant.stakeAmount,
            currentRoundStatus: uint8(round.status),
            currentRoundPlayers: _roundPlayers[roundId].length,
            canRequestVrf: canRequestRoundRandomness(roundId),
            canSettle: canSettleRound(roundId),
            canCancel: canEmergencyCancelRound(roundId)
        });
    }

    function getCurrentRound(uint256 tierId) external view returns (RoundView memory) {
        return getRound(currentRoundOfTier[tierId]);
    }

    function getMyRoundInfo(address user) external view returns (MyInfo memory) {
        return getMyInfo(user);
    }

    function getMyLossInfo(address user)
        external
        view
        returns (
            uint256 lossPrincipalBnb,
            uint256 lossQuota,
            uint256 lossClaimed,
            uint256 lossQuotaRemaining,
            uint256 pendingLossBnb
        )
    {
        return (
            lossPrincipalBnbOf[user],
            lossQuotaGrantedOf[user],
            claimedLossDividends[user],
            lossQuotaOf[user],
            pendingLossDividends(user)
        );
    }

    function getRound(uint256 roundId) public view returns (RoundView memory view_) {
        Round memory round = rounds[roundId];
        view_ = RoundView({
            roundId: roundId,
            tierId: round.tierId,
            betAmount: round.betAmount,
            startTime: round.startTime,
            joinDeadline: round.joinDeadline,
            requestTime: round.requestTime,
            vrfRequestId: round.vrfRequestId,
            randomWord: round.randomWord,
            winner: round.winner,
            status: uint8(round.status),
            participantCount: _roundPlayers[roundId].length,
            canRequestVrf: canRequestRoundRandomness(roundId),
            canSettle: canSettleRound(roundId),
            canCancel: canEmergencyCancelRound(roundId)
        });
    }

    function getRoundParticipants(uint256 roundId) external view returns (address[] memory) {
        return _roundPlayers[roundId];
    }

    function getRoundStatus(uint256 roundId) external view returns (uint8) {
        return uint8(rounds[roundId].status);
    }

    function roundDeadline(uint256 roundId) external view returns (uint256) {
        return rounds[roundId].joinDeadline;
    }

    function roundRandomReady(uint256 roundId) external view returns (bool) {
        return rounds[roundId].status == RoundStatus.RandomReady;
    }

    function canRequestRoundRandomness(uint256 roundId) public view returns (bool) {
        Round memory round = rounds[roundId];
        if (round.status != RoundStatus.Open || _roundPlayers[roundId].length < 2) return false;
        return block.timestamp >= round.joinDeadline || _roundPlayers[roundId].length >= MAX_ROUND_PLAYERS;
    }

    function canSettleRound(uint256 roundId) public view returns (bool) {
        return rounds[roundId].status == RoundStatus.RandomReady;
    }

    function canEmergencyCancelRound(uint256 roundId) public view returns (bool) {
        Round memory round = rounds[roundId];
        if (round.status == RoundStatus.Open) {
            return _roundPlayers[roundId].length <= 1 && block.timestamp >= round.joinDeadline;
        }
        if (round.status == RoundStatus.RandomnessRequested) {
            return block.timestamp >= round.requestTime + vrfTimeout;
        }
        return false;
    }

    function pendingNftDividends(address user) public view returns (uint256) {
        uint256 accumulated = _nftWeightOf[user] * accNftBnbPerShare / MAGNITUDE;
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

    function description() public pure override returns (string memory) {
        return unicode"NFT PVP 多人 Round 分红金库。";
    }

    function vaultUISchema() public view override returns (VaultUISchema memory schema) {
        return schemaHelper.vaultUISchema();
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

    function _getOrCreateOpenRound(uint256 tierId, uint256 betAmount) private returns (uint256 roundId) {
        roundId = currentRoundOfTier[tierId];
        if (roundId != 0) {
            Round storage current = rounds[roundId];
            if (current.status == RoundStatus.Open && block.timestamp <= current.joinDeadline && _roundPlayers[roundId].length < MAX_ROUND_PLAYERS) {
                return roundId;
            }
        }
        roundId = nextRoundId++;
        currentRoundOfTier[tierId] = roundId;
        Round storage round = rounds[roundId];
        round.tierId = tierId;
        round.betAmount = betAmount;
        round.startTime = block.timestamp;
        round.joinDeadline = block.timestamp + ROUND_JOIN_DURATION;
        round.status = RoundStatus.Open;
        totalRoundsCreated += 1;
        openRoundCount += 1;
        emit RoundCreated(roundId, tierId, betAmount, round.joinDeadline);
    }

    function _requestRandomness(uint256 roundId) private returns (uint256 requestId) {
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
        roundOfRequest[requestId] = roundId;
    }

    function _settleRound(uint256 roundId, uint256 randomness) private {
        Round storage round = rounds[roundId];
        address[] storage players = _roundPlayers[roundId];
        uint256 playerCount = players.length;
        uint256 winnerIndex = randomness % playerCount;
        address winner = players[winnerIndex];
        uint256 stakeAmount = round.betAmount;
        uint256 loserCount = playerCount - 1;
        uint256 winnerPayout = stakeAmount + (loserCount * stakeAmount * 7_000 / BPS_DENOMINATOR);
        uint256 burnAmountEach = stakeAmount * 1_500 / BPS_DENOMINATOR;
        uint256 lossBufferEach = stakeAmount - (stakeAmount * 7_000 / BPS_DENOMINATOR) - burnAmountEach;

        round.status = RoundStatus.Settled;
        round.winner = winner;
        totalRoundsSettled += 1;
        totalWinners += 1;
        totalLosers += loserCount;
        winsOf[winner] += 1;
        token.safeTransfer(winner, winnerPayout);

        for (uint256 i = 0; i < playerCount; i++) {
            address player = players[i];
            Participant memory participant = _roundParticipant[roundId][player];
            delete _roundParticipant[roundId][player];
            delete _roundPlayerIndexPlusOne[roundId][player];
            playerCurrentRound[player] = 0;
            nftInActiveGame[participant.nftId] = false;
            if (player == winner) {
                entryNft.unlockByVault(participant.nftId);
                _resumeNftReward(player, participant.nftId);
            } else {
                lossesOf[player] += 1;
                _sendToDead(burnAmountEach);
                pvpLossTokenBuffer += lossBufferEach;
                entryNft.burnByVault(participant.nftId);
                uint256 principalBnb = _getTokenPriceBnb(stakeAmount);
                lossPrincipalBnbOf[player] += principalBnb;
                _addLossQuota(player, principalBnb * 150 / 100);
            }
        }
        emit RoundSettled(roundId, winner, playerCount, loserCount, stakeAmount);
    }

    function _cancelRound(uint256 roundId) private {
        Round storage round = rounds[roundId];
        address[] storage players = _roundPlayers[roundId];
        uint256 count = players.length;
        bool wasOpen = round.status == RoundStatus.Open;
        round.status = RoundStatus.Cancelled;
        totalRoundsCancelled += 1;
        if (wasOpen && openRoundCount > 0) openRoundCount -= 1;
        if (currentRoundOfTier[round.tierId] == roundId) currentRoundOfTier[round.tierId] = 0;
        for (uint256 i = 0; i < count; i++) {
            address player = players[i];
            _refundParticipant(roundId, player);
        }
        emit RoundCancelled(roundId, count);
    }

    function _removeParticipantAndRefund(uint256 roundId, address player) private {
        uint256 indexPlusOne = _roundPlayerIndexPlusOne[roundId][player];
        if (indexPlusOne == 0) revert NotRoundParticipant();
        address[] storage players = _roundPlayers[roundId];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = players.length - 1;
        if (index != lastIndex) {
            address last = players[lastIndex];
            players[index] = last;
            _roundPlayerIndexPlusOne[roundId][last] = index + 1;
        }
        players.pop();
        _refundParticipant(roundId, player);
    }

    function _refundParticipant(uint256 roundId, address player) private {
        Participant memory participant = _roundParticipant[roundId][player];
        delete _roundParticipant[roundId][player];
        delete _roundPlayerIndexPlusOne[roundId][player];
        playerCurrentRound[player] = 0;
        nftInActiveGame[participant.nftId] = false;
        entryNft.unlockByVault(participant.nftId);
        _resumeNftReward(player, participant.nftId);
        token.safeTransfer(player, participant.stakeAmount);
        emit RoundLeft(roundId, rounds[roundId].tierId, player, participant.nftId, participant.stakeAmount);
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

    function _getTokenPriceBnb(uint256 amount) private view returns (uint256) {
        return amount * tokenPriceBnbPerToken / 1 ether;
    }

    function _addNftBnb(uint256 amount) private {
        if (amount == 0) return;
        if (totalNftRewardWeight == 0) {
            nftUndistributedBnb += amount;
            return;
        }
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / totalNftRewardWeight;
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
        if (rest > 0) lossUndistributedBnb += rest;
    }

    function _indexPendingNftBnb() private {
        uint256 amount = nftUndistributedBnb;
        if (amount == 0 || totalNftRewardWeight == 0) return;
        nftUndistributedBnb = 0;
        nftReservedBnb += amount;
        accNftBnbPerShare += amount * MAGNITUDE / totalNftRewardWeight;
    }

    function _addLossQuota(address user, uint256 quota) private {
        if (quota == 0) return;
        _settleLossAccount(user);
        lossQuotaOf[user] += quota;
        lossQuotaGrantedOf[user] += quota;
        totalLossQuota += quota;
        totalLossQuotaGranted += quota;
        _lossRewardDebt[user] = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
    }

    function _pauseNftReward(address user, uint256 nftId) private {
        if (!nftRewardActive[nftId]) return;
        nftRewardActive[nftId] = false;
        _decreaseNftWeight(user);
    }

    function _resumeNftReward(address user, uint256 nftId) private {
        if (nftRewardActive[nftId]) return;
        nftRewardActive[nftId] = true;
        _increaseNftWeight(user);
        _indexPendingNftBnb();
    }

    function _increaseNftWeight(address user) private {
        _settleNftAccount(user);
        _nftWeightOf[user] += 1;
        totalNftRewardWeight += 1;
        _nftRewardDebt[user] = _nftWeightOf[user] * accNftBnbPerShare / MAGNITUDE;
    }

    function _decreaseNftWeight(address user) private {
        _settleNftAccount(user);
        _nftWeightOf[user] -= 1;
        totalNftRewardWeight -= 1;
        _nftRewardDebt[user] = _nftWeightOf[user] * accNftBnbPerShare / MAGNITUDE;
    }

    function _settleNftAccount(address user) private {
        uint256 accumulated = _nftWeightOf[user] * accNftBnbPerShare / MAGNITUDE;
        uint256 debt = _nftRewardDebt[user];
        if (accumulated > debt) _nftCredit[user] += accumulated - debt;
        _nftRewardDebt[user] = accumulated;
    }

    function _settleLossAccount(address user) private {
        uint256 accumulated = lossQuotaOf[user] * accLossBnbPerQuota / MAGNITUDE;
        uint256 debt = _lossRewardDebt[user];
        if (accumulated > debt) _lossCredit[user] += accumulated - debt;
        _lossRewardDebt[user] = accumulated;
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

    function _setTier(uint256 tierId, uint256 tokenAmount, bool enabled) private {
        if (tokenAmount == 0 || tokenAmount > MAX_BET_AMOUNT) revert InvalidBetAmount();
        tiers[tierId] = Tier(tokenAmount, enabled);
        emit TierUpdated(tierId, tokenAmount, enabled);
    }

    function _currentRoundIds() private view returns (uint256[5] memory out) {
        for (uint256 i = 0; i < 5; i++) out[i] = currentRoundOfTier[i];
    }

    function _currentRoundPlayers() private view returns (uint256[5] memory out) {
        for (uint256 i = 0; i < 5; i++) out[i] = _roundPlayers[currentRoundOfTier[i]].length;
    }

    function _currentRoundDeadlines() private view returns (uint256[5] memory out) {
        for (uint256 i = 0; i < 5; i++) out[i] = rounds[currentRoundOfTier[i]].joinDeadline;
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
}
