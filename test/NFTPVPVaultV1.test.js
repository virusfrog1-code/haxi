const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("NFTPVPVaultV1", function () {
  const NFT_PRICE = ethers.parseEther("100000");
  const RATE = ethers.parseUnits("0.00001", 18);
  const TOKEN_PRICE_BNB_PER_TOKEN = RATE;
  const DEAD = "0x000000000000000000000000000000000000dEaD";
  const KEY_HASH = ethers.id("key-hash");
  const SUB_ID = 123n;
  const CALLBACK_GAS_LIMIT = 900000;
  const REQUEST_CONFIRMATIONS = 3;
  const tiers = [
    ethers.parseEther("100000"),
    ethers.parseEther("500000"),
    ethers.parseEther("2000000"),
    ethers.parseEther("5000000"),
    ethers.parseEther("10000000")
  ];

  async function deployFixture() {
    const [owner, guardian, alice, bob, carol, dave, erin] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy();
    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(ethers.ZeroAddress, RATE);
    await owner.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("100") });
    const VRF = await ethers.getContractFactory("MockVRFCoordinatorV25");
    const vrf = await VRF.deploy();
    const SchemaHelper = await ethers.getContractFactory("NFTPVPVaultV1SchemaHelper");
    const schemaHelper = await SchemaHelper.deploy();

    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const vault = await Vault.deploy(
      await token.getAddress(),
      await router.getAddress(),
      owner.address,
      guardian.address,
      TOKEN_PRICE_BNB_PER_TOKEN,
      await vrf.getAddress(),
      SUB_ID,
      KEY_HASH,
      CALLBACK_GAS_LIMIT,
      REQUEST_CONFIRMATIONS,
      await schemaHelper.getAddress()
    );
    const deployedStats = await vault.getStats();
    const nft = await ethers.getContractAt("PvpEntryNFT", deployedStats.nftAddress);

    for (const user of [alice, bob, carol, dave, erin]) {
      await token.mint(user.address, ethers.parseEther("100000000"));
      await token.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    }

    return { owner, guardian, alice, bob, carol, dave, erin, token, router, vrf, vault, nft };
  }

  async function enter(vault, user, tierId, nftId) {
    void nftId;
    return vault.connect(user).enterQueueByAmount(tiers[tierId]);
  }

  async function closeRoundAndRequest(vault, roundId) {
    await time.increase(5 * 60 + 1);
    await vault.requestRoundRandomness(roundId);
  }

  async function fulfill(vault, vrf, roundId, randomWord) {
    const round = await vault.getRound(roundId);
    await vrf.fulfill(round.vrfRequestId, randomWord);
  }

  async function expectSolvent(vault) {
    const stats = await vault.getStats();
    const reserved = stats.nftReservedBnb + stats.lossReservedBnb + stats.nftUndistributedBnb + stats.lossUndistributedBnb;
    expect(await ethers.provider.getBalance(await vault.getAddress())).to.be.gte(reserved);
  }

  it("mintNFT by token amount and mintNFTByCount mint at 100,000 Token each", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    const before = await token.balanceOf(alice.address);

    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);
    await vault.connect(alice).mintNFTByCount(1);
    await expect(vault.connect(alice).mintNFT(NFT_PRICE + 1n)).to.be.revertedWithCustomError(vault, "InvalidTokenAmount");

    expect(await token.balanceOf(alice.address)).to.equal(before - NFT_PRICE * 4n);
    expect(await nft.balanceOf(alice.address)).to.equal(4n);
    expect((await vault.getStats()).effectiveNftRewards).to.equal(4n);
  });

  it("mintNFTByCount rejects zero and keeps 50/25/25 allocation plus active supply cap", async function () {
    const { alice, token, vault } = await deployFixture();
    await expect(vault.connect(alice).mintNFTByCount(0)).to.be.revertedWithCustomError(vault, "InvalidTokenAmount");
    await vault.connect(alice).mintNFTByCount(1);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("50000"));
    expect((await vault.getStats()).lossMintTokenBuffer).to.equal(ethers.parseEther("25000"));
    expect((await vault.getStats()).nftMintTokenBuffer).to.equal(ethers.parseEther("25000"));

    await token.mint(alice.address, NFT_PRICE * 8889n);
    await expect(vault.connect(alice).mintNFTByCount(8889)).to.be.revertedWithCustomError(vault, "MaxSupplyExceeded");
  });

  it("default tiers match final Round tiers up to 10,000,000 Token", async function () {
    const { vault } = await deployFixture();
    for (let i = 0; i < tiers.length; i++) {
      const data = await vault.tiers(i);
      expect(data.tokenAmount).to.equal(tiers[i]);
      expect(data.enabled).to.equal(true);
    }
    await expect(vault.setTier(5, ethers.parseEther("10000001"), true)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("enterQueueByAmount maps each exact Token amount to its tier and rejects invalid amounts or missing NFTs", async function () {
    const { alice, bob, carol, dave, erin, vault } = await deployFixture();
    const users = [alice, bob, carol, dave, erin];
    for (const user of users) {
      await vault.connect(user).mintNFT(NFT_PRICE);
    }
    for (let i = 0; i < tiers.length; i++) {
      await vault.connect(users[i]).enterQueueByAmount(tiers[i]);
      const info = await vault.getMyInfo(users[i].address);
      expect(info.currentTierId).to.equal(BigInt(i));
      expect(info.stakedTokenAmount).to.equal(tiers[i]);
    }
    await expect(vault.connect(alice).enterQueueByAmount(ethers.parseEther("123456"))).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
    await expect(vault.connect((await ethers.getSigners())[8]).enterQueueByAmount(tiers[0])).to.be.revertedWithCustomError(vault, "NoAvailableNFT");
  });

  it("enterQueueByAmount automatically selects the first available NFT", async function () {
    const { alice, bob, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    expect(await vault.getAutoSelectedNFT(alice.address)).to.equal(1n);
    await vault.connect(alice).enterQueueByAmount(tiers[0]);
    expect((await vault.getMyInfo(alice.address)).stakedNftId).to.equal(1n);
    expect(await vault.getAutoSelectedNFT(alice.address)).to.equal(2n);
    await vault.connect(bob).enterQueueByAmount(tiers[0]);
    await time.increase(301);
    await vault.requestRoundRandomness(1);
    expect(await vault.getAutoSelectedNFT(alice.address)).to.equal(2n);
  });

  it("first player creates a waiting Round without deadline and can leave before an opponent joins", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    const before = await token.balanceOf(alice.address);
    await enter(vault, alice, 0, 1);
    const round = await vault.getRound(1);

    expect(round.roundId).to.equal(1n);
    expect(round.tierId).to.equal(0n);
    expect(round.startTime).to.equal(0n);
    expect(round.joinDeadline).to.equal(0n);
    expect(round.participantCount).to.equal(1n);
    expect(round.canCancel).to.equal(true);
    expect(await nft.locked(1)).to.equal(true);
    expect((await vault.getStats()).lockedNftsInRounds).to.equal(1n);

    await vault.connect(alice).leaveQueue();
    expect(await token.balanceOf(alice.address)).to.equal(before);
    expect(await nft.locked(1)).to.equal(false);
    expect((await vault.getStats()).effectiveNftRewards).to.equal(1n);
  });

  it("multiple users join the same tier Round and second user starts the 5 minute deadline", async function () {
    const { alice, bob, carol, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await vault.connect(carol).mintNFT(NFT_PRICE);

    await enter(vault, alice, 0, 1);
    const tx = await enter(vault, bob, 0, 2);
    const block = await ethers.provider.getBlock(tx.blockNumber);
    expect((await vault.getRound(1)).startTime).to.equal(BigInt(block.timestamp));
    expect((await vault.getRound(1)).joinDeadline).to.equal(BigInt(block.timestamp + 300));
    await enter(vault, carol, 0, 3);

    expect(await vault.getRoundParticipants(1)).to.deep.equal([alice.address, bob.address, carol.address]);
    expect((await vault.getCurrentRound(0)).participantCount).to.equal(3n);
  });

  it("after deadline new entrants go to next Round and old Round can request VRF", async function () {
    const { alice, bob, carol, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await vault.connect(carol).mintNFT(NFT_PRICE);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await time.increase(301);

    await expect(enter(vault, carol, 0, 3)).to.emit(vault, "RoundCreated");
    expect((await vault.getRound(2)).joinDeadline).to.equal(0n);
    expect(await vault.canRequestRoundRandomness(1)).to.equal(true);
    await vault.requestRoundRandomness(1);
    expect((await vault.getRound(1)).status).to.equal(2n);
  });

  it("single-player waiting Round can be cancelled without winner or quota", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    const before = await token.balanceOf(alice.address);
    await enter(vault, alice, 0, 1);
    expect((await vault.getMyInfo(alice.address)).canCancel).to.equal(true);
    await vault.connect(alice).emergencyCancelRound(1);

    expect(await token.balanceOf(alice.address)).to.equal(before);
    expect(await nft.locked(1)).to.equal(false);
    expect((await vault.getStats()).totalLosers).to.equal(0n);
    expect((await vault.getStats()).totalLossQuota).to.equal(0n);
  });

  it("VRF selects exactly one winner among all participants", async function () {
    const { alice, bob, carol, token, vrf, vault, nft } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await vault.connect(carol).mintNFT(NFT_PRICE);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);
    const carolBefore = await token.balanceOf(carol.address);
    const deadBefore = await token.balanceOf(DEAD);

    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await enter(vault, carol, 0, 3);
    await closeRoundAndRequest(vault, 1);
    await fulfill(vault, vrf, 1, 1); // index 1 => bob
    await vault.settleRound(1);

    expect(await token.balanceOf(bob.address)).to.equal(bobBefore + ethers.parseEther("140000"));
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore - tiers[0]);
    expect(await token.balanceOf(carol.address)).to.equal(carolBefore - tiers[0]);
    expect((await token.balanceOf(DEAD)) - deadBefore).to.equal(ethers.parseEther("30000"));
    expect((await vault.getStats()).pvpLossTokenBuffer).to.equal(ethers.parseEther("30000"));
    expect(await nft.ownerOf(2)).to.equal(bob.address);
    await expect(nft.ownerOf(1)).to.be.reverted;
    await expect(nft.ownerOf(3)).to.be.reverted;
    expect((await vault.getStats()).liveNftSupply).to.equal(1n);
    expect((await vault.getStats()).totalBurnedNFT).to.equal(2n);
    expect((await vault.getMyInfo(alice.address)).lossQuotaRemaining).to.equal(ethers.parseEther("1.5"));
    expect((await vault.getMyInfo(carol.address)).lossQuotaRemaining).to.equal(ethers.parseEther("1.5"));
  });

  it("owner or guardian cannot decide winner and settle waits for VRF", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await closeRoundAndRequest(vault, 1);
    await expect(vault.settleRound(1)).to.be.revertedWithCustomError(vault, "RoundRandomNotReady").withArgs(1);
    await expect(vault.connect(owner).rawFulfillRandomWords(1, [1])).to.be.revertedWithCustomError(vault, "InvalidVrfCoordinator");
    await fulfill(vault, vrf, 1, 0);
    expect(await vault.canSettleRound(1)).to.equal(true);
  });

  it("VRF timeout emergencyCancelRound refunds all players and has readable early error", async function () {
    const { alice, bob, token, vault, nft } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await closeRoundAndRequest(vault, 1);
    await expect(vault.connect(alice).emergencyCancelRound(1)).to.be.revertedWithCustomError(vault, "RoundNotExpired");
    await vault.setVrfTimeout(0);
    await vault.connect(alice).emergencyCancelRound(1);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
    expect((await vault.getStats()).totalLossQuota).to.equal(0n);
  });

  it("fee-on-transfer underfunding reverts when entering queue", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await token.setTransferFee(1000, carol.address);
    await expect(enter(vault, alice, 0, 1)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("same address cannot join another Round and locked NFT cannot transfer", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);
    await enter(vault, alice, 0, 1);
    await expect(enter(vault, alice, 1, 2)).to.be.revertedWithCustomError(vault, "PlayerAlreadyActive");
    await expect(nft.connect(alice).transferFrom(alice.address, bob.address, 1)).to.be.revertedWithCustomError(nft, "LockedToken");
  });

  it("NFT entering Round settles historical dividends and pauses future dividends", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("0.5"));

    await enter(vault, alice, 0, 1);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("0.5"));
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("1.5"));
  });

  it("winner NFT restores dividends, loser pending dividends remain claimable, and repeated claim does not underflow", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await closeRoundAndRequest(vault, 1);
    await fulfill(vault, vrf, 1, 0); // alice wins
    await vault.settleRound(1);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("1.5"));
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("0.5"));
    await vault.connect(bob).claimNftDividends();
    await expect(vault.connect(bob).claimNftDividends()).to.be.revertedWithCustomError(vault, "NoRewards");
  });

  it("LossVault excludes historical rewards, tracks total, claimed and remaining quota", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await closeRoundAndRequest(vault, 1);
    await fulfill(vault, vrf, 1, 0);
    await vault.settleRound(1);

    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("4") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(ethers.parseEther("1.5"));
    await vault.connect(bob).claimLossDividends();
    const info = await vault.getMyInfo(bob.address);
    expect(info.lossQuota).to.equal(ethers.parseEther("1.5"));
    expect(info.lossClaimed).to.equal(ethers.parseEther("1.5"));
    expect(info.lossQuotaRemaining).to.equal(0n);
  });

  it("rescueExcessBNB cannot withdraw reserved or undistributed BNB", async function () {
    const { owner, alice, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    await expect(vault.rescueExcessBNB(alice.address, 1)).to.be.revertedWithCustomError(vault, "InsufficientExcessBNB");
    await expectSolvent(vault);
  });

  it("convertMintBuffers keeps router BNB out of receive 50/50 split", async function () {
    const { alice, bob, vrf, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await closeRoundAndRequest(vault, 1);
    await fulfill(vault, vrf, 1, 0);
    await vault.settleRound(1);

    await vault.convertMintBuffers(1, 1, (await time.latest()) + 3600);
    const stats = await vault.getStats();
    expect(stats.nftReservedBnb).to.equal(ethers.parseEther("0.5"));
    expect(stats.lossReservedBnb).to.equal(ethers.parseEther("0.65"));
  });

  it("getStats and getMyInfo expose Round and LossVault user data", async function () {
    const { alice, bob, vault } = await deployFixture();
    await vault.connect(alice).mintNFT(NFT_PRICE);
    await vault.connect(bob).mintNFT(NFT_PRICE);
    await enter(vault, alice, 1, 1);
    await enter(vault, bob, 1, 2);

    const stats = await vault.getStats();
    expect(stats.maxNftSupply).to.equal(8888n);
    expect(stats.totalRounds).to.equal(1n);
    expect(stats.currentRoundIds[1]).to.equal(1n);
    expect(stats.currentRoundPlayers[1]).to.equal(2n);
    expect(stats.currentRoundDeadlines[1]).to.equal((await vault.getRound(1)).joinDeadline);
    const info = await vault.getMyInfo(alice.address);
    expect(info.tokenBalance).to.be.gt(0n);
    expect(info.autoSelectedNftId).to.equal(0n);
    expect(info.currentRoundId).to.equal(1n);
    expect(info.currentTierId).to.equal(1n);
    expect(info.stakedNftId).to.equal(1n);
    expect(info.stakedTokenAmount).to.equal(tiers[1]);
    expect(info.currentRoundStatus).to.equal(1n);
    expect(info.canCancel).to.equal(false);
    const roundInfo = await vault.getMyRoundInfo(alice.address);
    expect(roundInfo.currentRoundId).to.equal(1n);
    expect(roundInfo.currentRoundPlayers).to.equal(2n);
    const lossInfo = await vault.getMyLossInfo(alice.address);
    expect(lossInfo.lossPrincipalBnb).to.equal(0n);
    expect(lossInfo.lossQuota).to.equal(0n);
    expect(await vault.getRoundStatus(1)).to.equal(1n);
    expect(await vault.roundDeadline(1)).to.equal((await vault.getRound(1)).joinDeadline);
    expect(await vault.roundRandomReady(1)).to.equal(false);
  });

  it("factory creates the Round VRF vault and rejects unapproved creation code", async function () {
    const { owner, guardian, token, router, vrf } = await deployFixture();
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const Factory = await ethers.getContractFactory("NFTPVPVaultFactory");
    const factory = await Factory.deploy(
      owner.address,
      await router.getAddress(),
      guardian.address,
      TOKEN_PRICE_BNB_PER_TOKEN,
      await vrf.getAddress(),
      SUB_ID,
      KEY_HASH,
      CALLBACK_GAS_LIMIT,
      REQUEST_CONFIRMATIONS,
      ethers.keccak256(Vault.bytecode)
    );
    const vaultData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint256", "address", "uint256", "bytes32", "uint32", "uint16", "bytes"],
      [await router.getAddress(), guardian.address, TOKEN_PRICE_BNB_PER_TOKEN, await vrf.getAddress(), SUB_ID, KEY_HASH, CALLBACK_GAS_LIMIT, REQUEST_CONFIRMATIONS, Vault.bytecode]
    );
    const tx = await factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, vaultData);
    const receipt = await tx.wait();
    const event = receipt.logs.map((log) => factory.interface.parseLog(log)).find((log) => log && log.name === "VaultCreated");
    const createdVault = await ethers.getContractAt("NFTPVPVaultV1", event.args.vault);
    expect((await createdVault.getStats()).tokenAddress).to.equal(await token.getAddress());

    const badVaultData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint256", "address", "uint256", "bytes32", "uint32", "uint16", "bytes"],
      [await router.getAddress(), guardian.address, TOKEN_PRICE_BNB_PER_TOKEN, await vrf.getAddress(), SUB_ID, KEY_HASH, CALLBACK_GAS_LIMIT, REQUEST_CONFIRMATIONS, "0x1234"]
    );
    await expect(factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, badVaultData)).to.be.revertedWithCustomError(factory, "UnapprovedCreationCode");
  });

  it("vaultUISchema exposes Chinese multiplayer Round flow and hides old 1v1/advanced features", async function () {
    const { vault } = await deployFixture();
    const schema = await vault.vaultUISchema();
    const names = schema.methods.map((method) => method.name);
    const methodByName = Object.fromEntries(schema.methods.map((method) => [method.name, method]));
    expect(names).to.include.members([
      "mintNFT",
      "enterQueueByAmount",
      "leaveQueue",
      "claimNftDividends",
      "claimLossDividends",
      "getMyInfo",
      "getStats",
      "getAutoSelectedNFT",
      "getMyLossInfo",
      "requestRoundRandomness",
      "settleRound",
      "emergencyCancelRound",
      "claimNftDividends",
      "claimLossDividends",
      "getRound",
      "getCurrentRound",
      "getRoundStatus",
      "roundDeadline",
      "roundRandomReady",
      "canRequestRoundRandomness",
      "canSettleRound",
      "canEmergencyCancelRound",
      "pendingNftDividends",
      "pendingLossDividends"
    ]);
    for (const removed of [
      "mint1NFT",
      "mint2NFT",
      "mint5NFT",
      "mint10NFT",
      "mintNFTByCount",
      "enterQueue",
      "settleMatch",
      "emergencyCancelMatch",
      "mergeBaseNFTs",
      "enterNftQueue",
      "enterTokenQueue",
      "revealSeed",
      "claimRevealTimeoutWin"
    ]) {
      expect(names).to.not.include(removed);
    }
    expect(methodByName.mintNFT.inputs).to.have.length(1);
    expect(methodByName.mintNFT.inputs[0].name).to.equal("tokenAmount");
    expect(methodByName.mintNFT.approvals[0].amountFieldName).to.equal("tokenAmount");
    expect(methodByName.enterQueueByAmount.inputs).to.have.length(1);
    expect(methodByName.enterQueueByAmount.inputs[0].name).to.equal("tokenAmount");
    expect(methodByName.enterQueueByAmount.approvals[0].amountFieldName).to.equal("tokenAmount");
    expect(methodByName.leaveQueue.inputs).to.have.length(0);
    for (const text of ["输入 100000 = 铸造 1 张 NFT", "加入 PVP 只需输入对赌 Token 数量", "系统自动选择", "多人 Round", "5 分钟倒计时", "唯一赢家", "Chainlink VRF", "输家 NFT 销毁", "150%", "70%", "15%", "LossVault"]) {
      expect(schema.description).to.include(text);
    }
    expect(methodByName.getStats.outputs.map((field) => field.name)).to.include("各档倒计时结束时间");
    expect(methodByName.getMyInfo.outputs.map((field) => field.name)).to.include("自动选择 NFT ID");
  });

  it("ABI no longer exposes removed reveal, merge, or dual-mode queue methods", async function () {
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const vaultNames = Vault.interface.fragments.filter((fragment) => fragment.type === "function").map((fragment) => fragment.name);
    for (const removed of ["revealSeed", "claimRevealTimeoutWin", "mergeBaseNFTs", "enterNftQueue", "enterTokenQueue", "mint1NFT", "mint2NFT", "mint5NFT", "mint10NFT", "enterQueue"]) {
      expect(vaultNames).to.not.include(removed);
    }
  });
});

