const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NFTPVPVaultV1", function () {
  const NFT_PRICE = ethers.parseEther("50000");
  const RATE = ethers.parseUnits("0.00001", 18);
  const TOKEN_PRICE_BNB_PER_TOKEN = RATE;
  const DEAD = "0x000000000000000000000000000000000000dEaD";
  const KEY_HASH = ethers.id("key-hash");
  const SUB_ID = 123n;
  const CALLBACK_GAS_LIMIT = 900000;
  const REQUEST_CONFIRMATIONS = 3;
  const tiers = [
    { id: 0, units: 1n, amount: ethers.parseEther("50000") },
    { id: 1, units: 3n, amount: ethers.parseEther("150000") },
    { id: 2, units: 5n, amount: ethers.parseEther("250000") },
    { id: 3, units: 10n, amount: ethers.parseEther("500000") },
    { id: 4, units: 20n, amount: ethers.parseEther("1000000") },
    { id: 5, units: 40n, amount: ethers.parseEther("2000000") }
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

  function ids(from, count) {
    return Array.from({ length: count }, (_, i) => from + i);
  }

  it("mintNFTByCount(1) consumes 50,000 Token and mints 1 base NFT", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    const before = await token.balanceOf(alice.address);
    await mintCount(vault, alice, 1);
    expect(await token.balanceOf(alice.address)).to.equal(before - NFT_PRICE);
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.nftBaseUnits(1)).to.equal(1n);
    expect(await nft.nftRewardWeight(1)).to.equal(1n);
    expect(await nft.isVpnEligible(1)).to.equal(false);
  });

  it("mintNFTByCount(10) consumes 500,000 Token and mints 10 base NFTs", async function () {
    const { alice, token, vault, nft } = await deployFixture();
    const before = await token.balanceOf(alice.address);
    await mintCount(vault, alice, 10);
    expect(await token.balanceOf(alice.address)).to.equal(before - NFT_PRICE * 10n);
    expect(await nft.balanceOf(alice.address)).to.equal(10n);
    expect(await nft.totalRewardWeight()).to.equal(10n);
  });

  it("mintNFT keeps 50/25/25 allocation and activeSupply cap", async function () {
    const { alice, token, vault } = await deployFixture();
    await mintCount(vault, alice, 1);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("25000"));
    expect(await vault.lossMintTokenBuffer()).to.equal(ethers.parseEther("12500"));
    expect(await vault.nftMintTokenBuffer()).to.equal(ethers.parseEther("12500"));
    await token.mint(alice.address, NFT_PRICE * 8889n);
    await expect(vault.connect(alice).mintNFT(NFT_PRICE * 8889n)).to.be.revertedWithCustomError(vault, "MaxSupplyExceeded");
  });

  it("merges 10 base NFTs into 1 advanced NFT with 12 reward weight and VPN eligibility", async function () {
    const { alice, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 10);
    await vault.connect(alice).mergeBaseNFTs(ids(1, 10));
    expect(await nft.activeSupply()).to.equal(1n);
    expect(await nft.totalBurnedNFT()).to.equal(10n);
    expect(await nft.totalRewardWeight()).to.equal(12n);
    expect(await nft.ownerOf(11)).to.equal(alice.address);
    expect(await nft.isVpnEligible(11)).to.equal(true);
    expect(await nft.nftBaseUnits(11)).to.equal(10n);
    expect(await nft.nftRewardWeight(11)).to.equal(12n);
    await expect(nft.ownerOf(1)).to.be.reverted;
  });

  it("rejects merge with fewer than 10 base NFTs or a locked in-game NFT", async function () {
    const { alice, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 10);
    await expect(vault.connect(alice).mergeBaseNFTs(ids(1, 9))).to.be.revertedWithCustomError(nft, "InvalidMerge");
    await vault.connect(alice).enterNftQueue(0, [1]);
    await expect(vault.connect(alice).mergeBaseNFTs(ids(1, 10))).to.be.revertedWithCustomError(nft, "InvalidMerge");
  });

  it("default tiers map 1/3/5/10/20/40 units and reject above 2,000,000 Token", async function () {
    const { vault } = await deployFixture();
    for (const tier of tiers) {
      const data = await vault.tiers(tier.id);
      expect(data.tokenAmount).to.equal(tier.amount);
      expect(data.nftCount).to.equal(tier.units);
      expect(data.enabled).to.equal(true);
    }
    await expect(vault.setTier(6, ethers.parseEther("2050000"), 41, true)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("B joining Token queue creates match and requests VRF", async function () {
    const { alice, bob, vault } = await deployFixture();
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await expect(vault.connect(bob).enterTokenQueue(0, tiers[0].amount))
      .to.emit(vault, "MatchRequested")
      .withArgs(1, 0, alice.address, bob.address);
    const info = await vault.matches(1);
    expect(info.vrfRequestId).to.equal(1n);
    expect(await vault.matchOfRequest(1)).to.equal(1n);
  });

  it("Token mode settles 70/15/15 and creates correct LossVault quota", async function () {
    const { alice, bob, token, vrf, vault } = await deployFixture();
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(bob).enterTokenQueue(0, tiers[0].amount);
    await fulfillAndSettle(vault, vrf, 1, 2);
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore + ethers.parseEther("35000"));
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore - tiers[0].amount);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("7500"));
    expect(await vault.pvpLossTokenBuffer()).to.equal(ethers.parseEther("7500"));
    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.75"));
  });

  it("fee-on-transfer Token mode underfunding reverts", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await token.setTransferFee(1000, carol.address);
    await expect(vault.connect(alice).enterTokenQueue(0, tiers[0].amount)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("base NFT can match base NFT and winner receives loser NFT without burning", async function () {
    const { alice, bob, vrf, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    await vault.connect(alice).enterNftQueue(0, [1]);
    await vault.connect(bob).enterNftQueue(0, [2]);
    await fulfillAndSettle(vault, vrf, 1, 2);
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.ownerOf(2)).to.equal(alice.address);
    expect(await nft.totalBurnedNFT()).to.equal(0n);
    expect(await nft.activeSupply()).to.equal(2n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.75"));
  });

  it("advanced NFT can match 10 base NFTs using baseUnits, not rewardWeight", async function () {
    const { alice, bob, vrf, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 10);
    await vault.connect(alice).mergeBaseNFTs(ids(1, 10));
    await mintCount(vault, bob, 10);
    await vault.connect(alice).enterNftQueue(3, [11]);
    await vault.connect(bob).enterNftQueue(3, ids(12, 10));
    await fulfillAndSettle(vault, vrf, 1, 2);
    expect(await nft.balanceOf(alice.address)).to.equal(11n);
    expect(await nft.ownerOf(11)).to.equal(alice.address);
    expect(await nft.activeSupply()).to.equal(11n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("7.5"));
  });

  it("NFT mode rejects unequal baseUnits", async function () {
    const { alice, bob, vault } = await deployFixture();
    await mintCount(vault, alice, 10);
    await vault.connect(alice).mergeBaseNFTs(ids(1, 10));
    await mintCount(vault, bob, 1);
    await vault.connect(alice).enterNftQueue(3, [11]);
    await expect(vault.connect(bob).enterNftQueue(3, [12])).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("same address cannot self-match and same NFT cannot be reused", async function () {
    const { alice, vault } = await deployFixture();
    await mintCount(vault, alice, 2);
    await vault.connect(alice).enterNftQueue(0, [1]);
    await expect(vault.connect(alice).enterNftQueue(0, [2])).to.be.revertedWithCustomError(vault, "PlayerAlreadyActive");
    await expect(vault.connect(alice).enterNftQueue(0, [1])).to.be.revertedWithCustomError(vault, "PlayerAlreadyActive");
  });

  it("locked NFT cannot transfer", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await mintCount(vault, alice, 1);
    await vault.connect(alice).enterNftQueue(0, [1]);
    await expect(nft.connect(alice).transferFrom(alice.address, bob.address, 1)).to.be.revertedWithCustomError(nft, "LockedToken");
  });

  it("emergencyCancelMatch after VRF timeout refunds Token / NFT and creates no quota", async function () {
    const { alice, bob, token, vault, nft } = await deployFixture();
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(bob).enterTokenQueue(0, tiers[0].amount);
    await vault.setVrfTimeout(0);
    await vault.connect(alice).emergencyCancelMatch(1);
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await vault.totalLossQuota()).to.equal(0n);

    await mintCount(vault, alice, 1);
    await mintCount(vault, bob, 1);
    await vault.connect(alice).enterNftQueue(0, [1]);
    await vault.connect(bob).enterNftQueue(0, [2]);
    await vault.connect(bob).emergencyCancelMatch(2);
    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.ownerOf(2)).to.equal(bob.address);
    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
  });

  it("cannot settle before VRF and owner/guardian cannot provide randomness", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(bob).enterTokenQueue(0, tiers[0].amount);
    await expect(vault.settleMatch(1)).to.be.revertedWithCustomError(vault, "RandomnessPending");
    await expect(vault.connect(owner).rawFulfillRandomWords(1, [2])).to.be.revertedWithCustomError(vault, "InvalidVrfCoordinator");
  });

  it("leaves unmatched Token and NFT queues", async function () {
    const { alice, bob, token, vault, nft } = await deployFixture();
    const before = await token.balanceOf(alice.address);
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(alice).leaveQueue(0);
    expect(await token.balanceOf(alice.address)).to.equal(before);
    await mintCount(vault, bob, 1);
    await vault.connect(bob).enterNftQueue(0, [1]);
    await vault.connect(bob).leaveQueue(0);
    expect(await nft.locked(1)).to.equal(false);
  });

  it("NFT rewards are distributed by rewardWeight and advanced NFT gets 12 base weights", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintCount(vault, alice, 10);
    await vault.connect(alice).mergeBaseNFTs(ids(1, 10));
    await mintCount(vault, bob, 1);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("26") });
    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("12"));
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("1"));
  });

  it("LossVault does not give new losers historical rewards and caps at 150%", async function () {
    const { owner, alice, bob, vrf, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(bob).enterTokenQueue(0, tiers[0].amount);
    await fulfillAndSettle(vault, vrf, 1, 2);
    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("2") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(ethers.parseEther("0.75"));
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
    await vault.connect(alice).enterTokenQueue(0, tiers[0].amount);
    await vault.connect(bob).enterTokenQueue(0, tiers[0].amount);
    await fulfillAndSettle(vault, vrf, 1, 2);
    await vault.convertMintBuffers(1, 1, (await ethers.provider.getBlock("latest")).timestamp + 3600);
    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.125"));
    expect(await vault.lossReservedBnb()).to.equal(ethers.parseEther("0.2"));
  });

  it("factory creates NFTPVPVaultV1 with VRF config and approved creation code", async function () {
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

  it("vaultUISchema exposes VRF dual-mode actions and hides reveal actions", async function () {
    const { vault } = await deployFixture();
    const schema = await vault.vaultUISchema();
    const names = schema.methods.map((method) => method.name);
    expect(names).to.include.members([
      "mintNFTByCount",
      "mergeBaseNFTs",
      "enterTokenQueue",
      "enterNftQueue",
      "settleMatch",
      "emergencyCancelMatch",
      "claimNftDividends",
      "claimLossDividends"
    ]);
    expect(names).to.not.include("revealSeed");
    expect(names).to.not.include("claimRevealTimeoutWin");
    for (const text of ["50,000", "10", "1.2X", "VPN", "4%", "70%", "15%", "150%", "Chainlink VRF"]) {
      expect(schema.description).to.include(text);
    }
    expect(schema.description).to.include("owner / guardian");
    expect(schema.methods.find((method) => method.name === "enterTokenQueue").approvals[0].amountFieldName).to.equal("tokenAmount");
  });

  it("ABI no longer exposes revealSeed or claimRevealTimeoutWin", async function () {
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const names = Vault.interface.fragments.filter((fragment) => fragment.type === "function").map((fragment) => fragment.name);
    expect(names).to.not.include("revealSeed");
    expect(names).to.not.include("claimRevealTimeoutWin");
  });
});
