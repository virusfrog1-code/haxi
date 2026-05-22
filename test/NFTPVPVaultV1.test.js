const { expect } = require("chai");
const { ethers } = require("hardhat");

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
    { id: 0, amount: ethers.parseEther("100000") },
    { id: 1, amount: ethers.parseEther("300000") },
    { id: 2, amount: ethers.parseEther("500000") },
    { id: 3, amount: ethers.parseEther("1000000") },
    { id: 4, amount: ethers.parseEther("2000000") }
  ];

  async function deployFixture() {
    const [owner, guardian, alice, bob, carol] = await ethers.getSigners();
    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy();
    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(ethers.ZeroAddress, RATE);
    await owner.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("100") });
    const VRF = await ethers.getContractFactory("MockVRFCoordinatorV25");
    const vrf = await VRF.deploy();

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
      REQUEST_CONFIRMATIONS
    );
    const nft = await ethers.getContractAt("PvpEntryNFT", await vault.entryNft());

    for (const user of [alice, bob, carol]) {
      await token.mint(user.address, ethers.parseEther("100000000"));
      await token.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    }

    return { owner, guardian, alice, bob, carol, token, router, vrf, vault, nft };
  }

  async function mintCount(vault, user, quantity) {
    await vault.connect(user).mintNFTByCount(quantity);
  }

  async function enter(vault, user, tierId, nftId) {
    await vault.connect(user).enterQueue(tierId, nftId, tiers[tierId].amount);
  }

  async function fulfillAndSettle(vault, vrf, matchId, randomWord) {
    const info = await vault.matches(matchId);
    await vrf.fulfill(info.vrfRequestId, randomWord);
    await vault.settleMatch(matchId);
  }

  async function expectSolvent(vault) {
    const reserved =
      (await vault.nftReservedBnb()) +
      (await vault.lossReservedBnb()) +
      (await vault.nftUndistributedBnb()) +
      (await vault.lossUndistributedBnb());
    expect(await ethers.provider.getBalance(await vault.getAddress())).to.be.gte(reserved);
  }

  it("mintNFTByCount consumes 100,000 Token per NFT and rejects zero", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    const before = await token.balanceOf(alice.address);

    await mintCount(vault, alice, 1);
    expect(await token.balanceOf(alice.address)).to.equal(before - NFT_PRICE);
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.activeSupply()).to.equal(1n);
    expect(await nft.totalRewardWeight()).to.equal(1n);

    await mintCount(vault, alice, 2);
    expect(await token.balanceOf(alice.address)).to.equal(before - NFT_PRICE * 3n);
    expect(await nft.balanceOf(alice.address)).to.equal(3n);
    expect(await nft.totalRewardWeight()).to.equal(3n);

    await expect(vault.connect(alice).mintNFTByCount(0)).to.be.revertedWithCustomError(vault, "InvalidTokenAmount");
  });

  it("mintNFT keeps 50/25/25 allocation and activeSupply cap", async function () {
    const { alice, token, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("50000"));
    expect(await vault.lossMintTokenBuffer()).to.equal(ethers.parseEther("25000"));
    expect(await vault.nftMintTokenBuffer()).to.equal(ethers.parseEther("25000"));

    await token.mint(alice.address, NFT_PRICE * 8889n);
    await expect(vault.connect(alice).mintNFT(NFT_PRICE * 8889n)).to.be.revertedWithCustomError(vault, "MaxSupplyExceeded");
  });

  it("default tiers are simple Token tiers up to 2,000,000 Token", async function () {
    const { vault } = await deployFixture();
    for (const tier of tiers) {
      const data = await vault.tiers(tier.id);
      expect(data.tokenAmount).to.equal(tier.amount);
      expect(data.enabled).to.equal(true);
    }
    await expect(vault.setTier(5, ethers.parseEther("2000001"), true)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("A enterQueue locks Token plus one NFT, and leaveQueue refunds both before matching", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    const before = await token.balanceOf(alice.address);

    await enter(vault, alice, 0, 1);
    expect(await token.balanceOf(alice.address)).to.equal(before - tiers[0].amount);
    expect(await nft.locked(1)).to.equal(true);

    await vault.connect(alice).leaveQueue(0);
    expect(await token.balanceOf(alice.address)).to.equal(before);
    expect(await nft.locked(1)).to.equal(false);
  });

  it("B enterQueue on same tier creates a match and requests Chainlink VRF", async function () {
    const { alice, bob, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);

    await enter(vault, alice, 0, 1);
    await expect(vault.connect(bob).enterQueue(0, 2, tiers[0].amount))
      .to.emit(vault, "MatchRequested")
      .withArgs(1, 0, alice.address, bob.address);
    const info = await vault.matches(1);
    expect(info.vrfRequestId).to.equal(1n);
    expect(await vault.matchOfRequest(1)).to.equal(1n);
  });

  it("VRF settlement pays 70%, burns 15%, buffers 15%, burns loser NFT, and creates 150% quota", async function () {
    const { alice, bob, token, vrf, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);
    const deadBefore = await token.balanceOf(DEAD);

    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await fulfillAndSettle(vault, vrf, 1, 2);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore + ethers.parseEther("70000"));
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore - tiers[0].amount);
    expect((await token.balanceOf(DEAD)) - deadBefore).to.equal(ethers.parseEther("15000"));
    expect(await vault.pvpLossTokenBuffer()).to.equal(ethers.parseEther("15000"));
    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.activeSupply()).to.equal(1n);
    expect(await nft.totalBurnedNFT()).to.equal(1n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("1.5"));
  });

  it("winner can be playerB and owner or guardian cannot decide randomness", async function () {
    const { owner, alice, bob, token, vrf, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    const bobBefore = await token.balanceOf(bob.address);

    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await expect(vault.settleMatch(1)).to.be.revertedWithCustomError(vault, "RandomnessPending");
    await expect(vault.connect(owner).rawFulfillRandomWords(1, [1])).to.be.revertedWithCustomError(vault, "InvalidVrfCoordinator");
    await fulfillAndSettle(vault, vrf, 1, 1);

    expect(await token.balanceOf(bob.address)).to.equal(bobBefore + ethers.parseEther("70000"));
    await expect(nft.ownerOf(1)).to.be.reverted;
    expect(await nft.ownerOf(2)).to.equal(bob.address);
  });

  it("fee-on-transfer underfunding reverts when entering queue", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    await token.setTransferFee(1000, carol.address);
    await expect(enter(vault, alice, 0, 1)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("same address cannot self-match, same NFT cannot be reused, and locked NFT cannot transfer", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 2);
    await enter(vault, alice, 0, 1);
    await expect(enter(vault, alice, 0, 2)).to.be.revertedWithCustomError(vault, "PlayerAlreadyActive");
    await expect(nft.connect(alice).transferFrom(alice.address, bob.address, 1)).to.be.revertedWithCustomError(nft, "LockedToken");
  });

  it("emergencyCancelMatch after VRF timeout refunds both Token and NFT and creates no quota", async function () {
    const { alice, bob, token, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);

    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await vault.setVrfTimeout(0);
    await vault.connect(alice).emergencyCancelMatch(1);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.ownerOf(2)).to.equal(bob.address);
    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
    expect(await vault.totalLossQuota()).to.equal(0n);
  });

  it("NFT dividends use equal weight per effective NFT and burn preserves historical pending rewards", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("4") });
    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("1"));
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("1"));

    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await fulfillAndSettle(vault, vrf, 1, 2);
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("1"));
    await vault.connect(bob).claimNftDividends();
  });

  it("LossVault excludes historical rewards for new losers, caps at 150%, and claimLossDividends works", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await fulfillAndSettle(vault, vrf, 1, 2);

    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("4") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(ethers.parseEther("1.5"));
    await vault.connect(bob).claimLossDividends();
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
  });

  it("rescueExcessBNB cannot withdraw reserved or undistributed BNB", async function () {
    const { owner, alice, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    await expect(vault.rescueExcessBNB(alice.address, 1)).to.be.revertedWithCustomError(vault, "InsufficientExcessBNB");
    await expectSolvent(vault);
  });

  it("convertMintBuffers keeps router BNB out of receive 50/50 split", async function () {
    const { alice, bob, vrf, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    await enter(vault, alice, 0, 1);
    await enter(vault, bob, 0, 2);
    await fulfillAndSettle(vault, vrf, 1, 2);

    await vault.convertMintBuffers(1, 1, (await ethers.provider.getBlock("latest")).timestamp + 3600);
    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.5"));
    expect(await vault.lossReservedBnb()).to.equal(ethers.parseEther("0.65"));
  });

  it("factory creates simplified VRF vault and rejects unapproved creation code", async function () {
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
    expect(await createdVault.vrfCoordinator()).to.equal(await vrf.getAddress());

    const badVaultData = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint256", "address", "uint256", "bytes32", "uint32", "uint16", "bytes"],
      [await router.getAddress(), guardian.address, TOKEN_PRICE_BNB_PER_TOKEN, await vrf.getAddress(), SUB_ID, KEY_HASH, CALLBACK_GAS_LIMIT, REQUEST_CONFIRMATIONS, "0x1234"]
    );
    await expect(factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, badVaultData)).to.be.revertedWithCustomError(factory, "UnapprovedCreationCode");
  });

  it("vaultUISchema exposes final simplified Chinese VRF flow and hides removed features", async function () {
    const { vault } = await deployFixture();
    const schema = await vault.vaultUISchema();
    const names = schema.methods.map((method) => method.name);
    expect(names).to.include.members([
      "getStats",
      "getMyInfo",
      "pendingNftDividends",
      "pendingLossDividends",
      "mintNFTByCount",
      "mintNFT",
      "enterQueue",
      "leaveQueue",
      "settleMatch",
      "emergencyCancelMatch",
      "claimNftDividends",
      "claimLossDividends"
    ]);
    for (const removed of [
      "mergeBaseNFTs",
      "enterNftQueue",
      "enterTokenQueue",
      "nftRewardWeight",
      "nftBaseUnits",
      "isVpnEligible",
      "revealSeed",
      "claimRevealTimeoutWin"
    ]) {
      expect(names).to.not.include(removed);
    }
    for (const text of ["100,000 Token", "8,888", "Chainlink VRF", "4%", "70%", "15%", "LossVault", "150%", "输家 NFT 被销毁"]) {
      expect(schema.description).to.include(text);
    }
    for (const removedText of ["高级 NFT", "VPN", "baseUnits", "rewardWeight"]) {
      expect(schema.description).to.not.include(removedText);
    }
    expect(schema.methods.find((method) => method.name === "enterQueue").approvals[0].amountFieldName).to.equal("tokenAmount");
    expect(schema.methods.find((method) => method.name === "mintNFT").approvals[0].amountFieldName).to.equal("tokenAmount");
  });

  it("ABI no longer exposes removed reveal, merge, advanced NFT, or dual-mode queue methods", async function () {
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const vaultNames = Vault.interface.fragments.filter((fragment) => fragment.type === "function").map((fragment) => fragment.name);
    for (const removed of [
      "revealSeed",
      "claimRevealTimeoutWin",
      "mergeBaseNFTs",
      "enterNftQueue",
      "enterTokenQueue",
      "nftRewardWeight",
      "nftBaseUnits",
      "isVpnEligible"
    ]) {
      expect(vaultNames).to.not.include(removed);
    }

    const Nft = await ethers.getContractFactory("PvpEntryNFT");
    const nftNames = Nft.interface.fragments.filter((fragment) => fragment.type === "function").map((fragment) => fragment.name);
    for (const removed of ["mergeBaseNFTsByVault", "nftLevel", "nftType", "nftRewardWeight", "nftBaseUnits", "isVpnEligible"]) {
      expect(nftNames).to.not.include(removed);
    }
  });
});
