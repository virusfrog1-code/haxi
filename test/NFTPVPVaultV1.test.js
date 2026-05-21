const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NFTPVPVaultV1", function () {
  const NFT_PRICE = ethers.parseEther("100000");
  const BET = ethers.parseEther("1000");
  const RATE = ethers.parseUnits("0.00001", 18);
  const TOKEN_PRICE_BNB_PER_TOKEN = RATE;
  const DEAD = "0x000000000000000000000000000000000000dEaD";
  const SEED_A = ethers.encodeBytes32String("alice-seed");
  const SEED_B = ethers.encodeBytes32String("bob-seed");

  async function deployFixture() {
    const [owner, guardian, alice, bob, carol] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(ethers.ZeroAddress, RATE);
    await owner.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("100") });

    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const vault = await Vault.deploy(
      await token.getAddress(),
      await router.getAddress(),
      owner.address,
      guardian.address,
      TOKEN_PRICE_BNB_PER_TOKEN
    );

    const nft = await ethers.getContractAt("PvpEntryNFT", await vault.entryNft());
    await vault.setTier(1, BET, true);

    for (const user of [alice, bob, carol]) {
      await token.mint(user.address, ethers.parseEther("100000000"));
      await token.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    }

    return { owner, guardian, alice, bob, carol, token, router, vault, nft };
  }

  async function deadline(offset = 3600) {
    const block = await ethers.provider.getBlock("latest");
    return BigInt(block.timestamp + offset);
  }

  async function expectSolvent(vault) {
    const reserved =
      (await vault.nftReservedBnb()) +
      (await vault.lossReservedBnb()) +
      (await vault.nftUndistributedBnb()) +
      (await vault.lossUndistributedBnb());
    expect(await ethers.provider.getBalance(await vault.getAddress())).to.be.gte(reserved);
  }

  async function mintOne(vault, user) {
    await vault.connect(user).mintNFT(NFT_PRICE);
  }

  function commitment(user, seed) {
    return ethers.keccak256(ethers.solidityPacked(["address", "bytes32"], [user.address, seed]));
  }

  function revealRandomness(matchId, seedA, seedB, playerA, playerB) {
    return BigInt(
      ethers.keccak256(
        ethers.solidityPacked(["uint256", "bytes32", "bytes32", "address", "address"], [matchId, seedA, seedB, playerA.address, playerB.address])
      )
    );
  }

  function seedsForWinner(playerA, playerB, aWins, matchId = 1n) {
    for (let i = 1n; i < 1000n; i++) {
      const seedA = ethers.toBeHex(i, 32);
      const seedB = ethers.toBeHex(i + 10_000n, 32);
      if ((revealRandomness(matchId, seedA, seedB, playerA, playerB) % 2n === 0n) === aWins) {
        return { seedA, seedB };
      }
    }
    throw new Error("no test seeds found");
  }

  async function enter(vault, user, tierId, nftId, seed, bet = BET) {
    await vault.connect(user).enterQueue(tierId, nftId, bet, commitment(user, seed));
  }

  async function matchAndReveal(vault, playerA, playerB, aWins = true, matchId = 1n) {
    const { seedA, seedB } = seedsForWinner(playerA, playerB, aWins, matchId);
    await enter(vault, playerA, 1, 1, seedA);
    await enter(vault, playerB, 1, 2, seedB);
    await vault.connect(playerA).revealSeed(matchId, seedA);
    await vault.connect(playerB).revealSeed(matchId, seedB);
    return { seedA, seedB };
  }

  it("mintNFT correctly mints NFTs", async function () {
    const { alice, vault, nft } = await deployFixture();

    await mintOne(vault, alice);

    expect(await nft.ownerOf(1)).to.equal(alice.address);
    expect(await nft.balanceOf(alice.address)).to.equal(1n);
    expect(await nft.totalMinted()).to.equal(1n);
    expect(await nft.totalMintedEver()).to.equal(1n);
    expect(await nft.activeSupply()).to.equal(1n);
  });

  it("mintNFT over 8888 fails before minting", async function () {
    const { alice, token, vault } = await deployFixture();
    const tooMany = NFT_PRICE * 8889n;
    await token.mint(alice.address, tooMany);

    await expect(vault.connect(alice).mintNFT(tooMany)).to.be.revertedWithCustomError(vault, "MaxSupplyExceeded");
  });

  it("mintNFT splits token funds 50/25/25", async function () {
    const { alice, token, vault } = await deployFixture();

    await mintOne(vault, alice);

    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("50000"));
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("50000"));
    expect(await vault.lossMintTokenBuffer()).to.equal(ethers.parseEther("25000"));
    expect(await vault.nftMintTokenBuffer()).to.equal(ethers.parseEther("25000"));
    expect(await token.balanceOf(await vault.getAddress())).to.equal(ethers.parseEther("50000"));
  });

  it("mintNFT accounts from actual received token amount for taxed tokens", async function () {
    const { alice, carol, token, vault, nft } = await deployFixture();
    await token.setTransferFee(5000, carol.address);

    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);

    expect(await nft.balanceOf(alice.address)).to.equal(1n);
    expect(await vault.lossMintTokenBuffer()).to.equal(ethers.parseEther("25000"));
    expect(await vault.nftMintTokenBuffer()).to.equal(ethers.parseEther("25000"));
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("25000"));
  });

  it("reverts mintNFT when actual received is not an exact mint price multiple", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await token.setTransferFee(1000, carol.address);

    await expect(vault.connect(alice).mintNFT(NFT_PRICE)).to.be.revertedWithCustomError(vault, "InvalidTokenAmount");
  });

  it("tracks only actual tokens received by DEAD when DEAD transfers are taxed", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await token.setTransferFee(5000, carol.address);

    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);

    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("25000"));
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("25000"));
  });

  it("enterQueue reverts when a taxed transfer underfunds the exact bet", async function () {
    const { alice, carol, token, vault } = await deployFixture();
    await mintOne(vault, alice);
    await token.setTransferFee(1000, carol.address);

    await expect(enter(vault, alice, 1, 1, SEED_A)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("enterQueue locks NFT", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await mintOne(vault, alice);

    await enter(vault, alice, 1, 1, SEED_A);

    expect(await nft.locked(1)).to.equal(true);
    await expect(nft.connect(alice).transferFrom(alice.address, bob.address, 1)).to.be.revertedWithCustomError(
      nft,
      "LockedToken"
    );
  });

  it("PvpEntryNFT lock, unlock, and burn are vault-only", async function () {
    const { owner, alice, vault, nft } = await deployFixture();
    await mintOne(vault, alice);

    await expect(nft.connect(owner).lockByVault(1)).to.be.revertedWithCustomError(nft, "NotVault");
    await enter(vault, alice, 1, 1, SEED_A);
    await expect(nft.connect(owner).unlockByVault(1)).to.be.revertedWithCustomError(nft, "NotVault");
    await expect(nft.connect(owner).burnByVault(1)).to.be.revertedWithCustomError(nft, "NotVault");
  });

  it("onNftBalanceChange only accepts calls from the NFT contract", async function () {
    const { alice, bob, vault } = await deployFixture();

    await expect(vault.connect(alice).onNftBalanceChange(alice.address, bob.address)).to.be.revertedWithCustomError(
      vault,
      "NotNftContract"
    );
  });

  it("onNftBalanceChange preserves NFT dividends across transfers without iterating NFTs", async function () {
    const { owner, alice, bob, vault, nft } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    await nft.connect(alice).transferFrom(alice.address, bob.address, 1);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    expect(await vault.pendingNftDividends(alice.address)).to.equal(ethers.parseEther("0.25"));
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("0.75"));
  });

  it("leaveQueue unlocks NFT and refunds tokens", async function () {
    const { alice, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    const before = await token.balanceOf(alice.address);

    await enter(vault, alice, 1, 1, SEED_A);
    await vault.connect(alice).leaveQueue(1);

    expect(await nft.locked(1)).to.equal(false);
    expect(await token.balanceOf(alice.address)).to.equal(before);
  });

  it("settles with winner receiving 70% of loser bet and burns loser NFT", async function () {
    const { alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    const aliceBefore = await token.balanceOf(alice.address);
    await matchAndReveal(vault, alice, bob, true);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore + ethers.parseEther("700"));
    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await nft.locked(1)).to.equal(false);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("100000") + ethers.parseEther("150"));
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("100000") + ethers.parseEther("150"));
    expect(await vault.pvpLossTokenBuffer()).to.equal(ethers.parseEther("150"));
  });

  it("reduces activeSupply after NFT burn and allows later minting while active supply stays capped", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await matchAndReveal(vault, alice, bob, true);

    expect(await nft.activeSupply()).to.equal(1n);
    expect(await nft.totalBurnedNFT()).to.equal(1n);
    expect(await nft.totalMintedEver()).to.equal(2n);

    await mintOne(vault, bob);
    expect(await nft.activeSupply()).to.equal(2n);
    expect(await nft.totalMintedEver()).to.equal(3n);
    expect(await nft.ownerOf(3)).to.equal(bob.address);
  });

  it("preserves loser historical NFT dividends after loser NFT is burned", async function () {
    const { owner, alice, bob, vault, nft } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    await matchAndReveal(vault, alice, bob, true);

    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("0.25"));
    await vault.connect(bob).claimNftDividends();
    expect(await vault.pendingNftDividends(bob.address)).to.equal(0n);
  });

  it("sets LossVault quota to 150% of losing principal BNB value", async function () {
    const { alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await matchAndReveal(vault, alice, bob, true);

    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.015"));
  });

  it("uses fixed token price for LossVault quota instead of router spot quote", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await expect(vault.connect(owner).setTokenPriceBnbPerToken(ethers.parseUnits("0.00002", 18)))
      .to.emit(vault, "TokenPriceBnbPerTokenUpdated")
      .withArgs(TOKEN_PRICE_BNB_PER_TOKEN, ethers.parseUnits("0.00002", 18));

    await matchAndReveal(vault, alice, bob, true);

    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.03"));
  });

  it("receive() splits BNB 50/50 into NFT pool and LossVault pending buffer", async function () {
    const { owner, alice, vault } = await deployFixture();
    await mintOne(vault, alice);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.5"));
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));
    await expectSolvent(vault);
  });

  it("records external BNB as separate NFT and LossVault undistributed balances when no supply exists", async function () {
    const { owner, alice, vault } = await deployFixture();
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    expect(await vault.nftUndistributedBnb()).to.equal(ethers.parseEther("0.5"));
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));
    await expect(vault.rescueExcessBNB(owner.address, 1n)).to.be.revertedWithCustomError(
      vault,
      "InsufficientExcessBNB"
    );

    await mintOne(vault, alice);
    expect(await vault.nftUndistributedBnb()).to.equal(0n);
    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.5"));
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));
    await expectSolvent(vault);
  });

  it("removes a loser from effective LossVault quota after claiming the 150% cap", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await matchAndReveal(vault, alice, bob, true);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("0.03") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(ethers.parseEther("0.015"));
    await vault.connect(bob).claimLossDividends();
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
    expect(await vault.totalLossQuota()).to.equal(0n);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
  });

  it("does not let a new loser claim historical LossVault income from before their quota", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));

    await matchAndReveal(vault, alice, bob, true);

    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("0.01") });
    expect(await vault.pendingLossDividends(bob.address)).to.be.closeTo(ethers.parseEther("0.005"), 1n);
  });

  it("rescueExcessBNB cannot withdraw reserved or pending BNB", async function () {
    const { owner, alice, vault } = await deployFixture();
    await mintOne(vault, alice);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    await expect(vault.rescueExcessBNB(owner.address, 1n)).to.be.revertedWithCustomError(
      vault,
      "InsufficientExcessBNB"
    );
    await expectSolvent(vault);
  });

  it("rescueExcessBNB preserves balance invariant when excess exists", async function () {
    const { owner, alice, vault } = await deployFixture();
    await mintOne(vault, alice);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    await ethers.provider.send("hardhat_setBalance", [await vault.getAddress(), "0x1BC16D674EC80000"]);

    expect(await vault.excessBnbAvailable()).to.equal(ethers.parseEther("1"));
    await vault.rescueExcessBNB(owner.address, ethers.parseEther("1"));
    expect(await vault.excessBnbAvailable()).to.equal(0n);
    await expectSolvent(vault);
  });

  it("convertMintBuffers swaps token buffers into NFT and LossVault BNB pools", async function () {
    const { owner, alice, vault } = await deployFixture();
    await mintOne(vault, alice);

    await vault.connect(owner).convertMintBuffers(ethers.parseEther("0.25"), ethers.parseEther("0.25"), await deadline());

    expect(await vault.nftMintTokenBuffer()).to.equal(0n);
    expect(await vault.lossMintTokenBuffer()).to.equal(0n);
    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.25"));
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.25"));
    await expectSolvent(vault);
  });

  it("routes mint buffers to the correct pools without receive 50/50 splitting conversion output", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await vault.connect(owner).convertMintBuffers(ethers.parseEther("0.5"), ethers.parseEther("0.5"), await deadline());

    expect(await vault.nftReservedBnb()).to.equal(ethers.parseEther("0.5"));
    expect(await vault.lossReservedBnb()).to.equal(0n);
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));
    await expectSolvent(vault);
  });

  it("routes pvpLossTokenBuffer conversion 100% to LossVault, not through receive 50/50 split", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await vault.connect(owner).convertMintBuffers(0, 0, await deadline());

    await matchAndReveal(vault, alice, bob, true);

    const nftReservedBefore = await vault.nftReservedBnb();
    const lossReservedBefore = await vault.lossReservedBnb();
    await vault.connect(owner).convertMintBuffers(0, ethers.parseEther("0.0015"), await deadline());

    expect(await vault.pvpLossTokenBuffer()).to.equal(0n);
    expect(await vault.nftReservedBnb()).to.equal(nftReservedBefore);
    expect(await vault.lossReservedBnb()).to.equal(lossReservedBefore + ethers.parseEther("0.0015"));
  });

  it("convertMintBuffers enforces slippage and deadline", async function () {
    const { owner, alice, vault } = await deployFixture();
    await mintOne(vault, alice);

    await expect(
      vault.connect(owner).convertMintBuffers(ethers.parseEther("0.251"), 0, await deadline())
    ).to.be.revertedWith("INSUFFICIENT_OUTPUT_AMOUNT");
    await expect(vault.connect(owner).convertMintBuffers(0, 0, await deadline(-1))).to.be.revertedWithCustomError(
      vault,
      "DeadlineExpired"
    );
  });

  it("does not allow one address to match itself through another tier", async function () {
    const { alice, vault } = await deployFixture();
    await vault.setTier(2, BET, true);
    await vault.connect(alice).mintNFT(NFT_PRICE * 2n);

    await enter(vault, alice, 1, 1, SEED_A);
    await expect(vault.connect(alice).enterQueue(2, 2, BET, commitment(alice, SEED_B))).to.be.revertedWithCustomError(
      vault,
      "PlayerAlreadyActive"
    );
  });

  it("matched players cannot leaveQueue, but can emergency cancel after reveal timeout with no reveals", async function () {
    const { owner, alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);

    await enter(vault, alice, 1, 1, SEED_A);
    await enter(vault, bob, 1, 2, SEED_B);

    await expect(vault.connect(alice).leaveQueue(1)).to.be.revertedWithCustomError(vault, "NoQueuedEntry");
    await expect(vault.connect(owner).emergencyCancelMatch(1)).to.be.revertedWithCustomError(vault, "RevealPeriodActive");
    await vault.connect(owner).setRevealTimeout(0);
    await vault.connect(owner).emergencyCancelMatch(1);

    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await vault.lossQuotaOf(alice.address)).to.equal(0n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("100000"));
    await expectSolvent(vault);
  });

  it("lets a matched player emergency cancel after timeout and refund without quota, burn, or winner payout", async function () {
    const { alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);

    await enter(vault, alice, 1, 1, SEED_A);
    await enter(vault, bob, 1, 2, SEED_B);
    await vault.setRevealTimeout(0);
    await vault.connect(alice).emergencyCancelMatch(1);

    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await vault.lossQuotaOf(alice.address)).to.equal(0n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("100000"));
  });

  it("lets the only revealer win after reveal timeout", async function () {
    const { alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    const aliceBefore = await token.balanceOf(alice.address);
    const { seedA, seedB } = seedsForWinner(alice, bob, false);

    await enter(vault, alice, 1, 1, seedA);
    await enter(vault, bob, 1, 2, seedB);
    await vault.connect(alice).revealSeed(1, seedA);
    await vault.setRevealTimeout(0);
    await vault.connect(alice).claimRevealTimeoutWin(1);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore + ethers.parseEther("700"));
    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.015"));
  });

  it("claimNftDividends and claimLossDividends reduce reserved balances correctly", async function () {
    const { owner, alice, bob, vault } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    const nftReservedBefore = await vault.nftReservedBnb();
    const aliceNftPending = await vault.pendingNftDividends(alice.address);
    await vault.connect(alice).claimNftDividends();
    expect(await vault.nftReservedBnb()).to.equal(nftReservedBefore - aliceNftPending);
    await expectSolvent(vault);

    await matchAndReveal(vault, alice, bob, true);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("0.03") });

    const lossReservedBefore = await vault.lossReservedBnb();
    const bobLossPending = await vault.pendingLossDividends(bob.address);
    await vault.connect(bob).claimLossDividends();
    expect(await vault.lossReservedBnb()).to.equal(lossReservedBefore - bobLossPending);
    await expectSolvent(vault);
  });

  it("vaultUISchema exposes required methods and approval amount fields", async function () {
    const { vault } = await deployFixture();
    const schema = await vault.vaultUISchema();
    const names = schema.methods.map((method) => method.name);

    expect(names).to.deep.equal([
      "getStats",
      "getMyInfo",
      "pendingNftDividends",
      "pendingLossDividends",
      "mintNFT",
      "enterQueue",
      "leaveQueue",
      "revealSeed",
      "claimRevealTimeoutWin",
      "emergencyCancelMatch",
      "claimNftDividends",
      "claimLossDividends"
    ]);
    expect(schema.description).to.include("commit-reveal");
    expect(schema.methods[4].inputs[0].name).to.equal("tokenAmount");
    expect(schema.methods[4].approvals[0].tokenType).to.equal("taxToken");
    expect(schema.methods[4].approvals[0].amountFieldName).to.equal("tokenAmount");
    expect(schema.methods[5].description).to.include("keccak256(abi.encodePacked(userAddress, secretSeed))");
    expect(schema.methods[5].description).to.include("save secretSeed");
    expect(schema.methods[5].description).to.include("timeout win");
    expect(schema.methods[5].inputs[2].name).to.equal("betAmount");
    expect(schema.methods[5].inputs[3].name).to.equal("seedCommitment");
    expect(schema.methods[5].approvals[0].tokenType).to.equal("taxToken");
    expect(schema.methods[5].approvals[0].amountFieldName).to.equal("betAmount");
    expect(schema.methods[7].inputs[0].name).to.equal("matchId");
    expect(schema.methods[7].inputs[1].name).to.equal("secretSeed");
    expect(schema.methods[8].inputs[0].name).to.equal("matchId");
    expect(schema.methods[9].inputs[0].name).to.equal("matchId");
  });

  it("factory creates NFTPVPVaultV1 and exposes Flap vaultDataSchema", async function () {
    const { owner, guardian, token, router } = await deployFixture();
    const Factory = await ethers.getContractFactory("NFTPVPVaultFactory");
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const approvedHash = ethers.keccak256(Vault.bytecode);
    const factory = await Factory.deploy(
      owner.address,
      await router.getAddress(),
      guardian.address,
      TOKEN_PRICE_BNB_PER_TOKEN,
      approvedHash
    );

    const schema = await factory.vaultDataSchema();
    expect(schema.fields.length).to.equal(4);

    const coder = ethers.AbiCoder.defaultAbiCoder();
    const vaultData = coder.encode(
      ["address", "address", "uint256", "bytes"],
      [await router.getAddress(), guardian.address, TOKEN_PRICE_BNB_PER_TOKEN, Vault.bytecode]
    );
    const tx = await factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, vaultData);
    const receipt = await tx.wait();
    const event = receipt.logs.map((log) => {
      try {
        return factory.interface.parseLog(log);
      } catch {
        return null;
      }
    }).find((parsed) => parsed && parsed.name === "VaultCreated");

    const vaultAddress = event.args.vault;
    const createdVault = await ethers.getContractAt("NFTPVPVaultV1", vaultAddress);
    expect(await createdVault.owner()).to.equal(owner.address);
    expect(await createdVault.guardianOverride()).to.equal(guardian.address);
    expect(await createdVault.tokenPriceBnbPerToken()).to.equal(TOKEN_PRICE_BNB_PER_TOKEN);
  });

  it("factory rejects non-approved vault creation code", async function () {
    const { owner, guardian, token, router } = await deployFixture();
    const Factory = await ethers.getContractFactory("NFTPVPVaultFactory");
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const factory = await Factory.deploy(
      owner.address,
      await router.getAddress(),
      guardian.address,
      TOKEN_PRICE_BNB_PER_TOKEN,
      ethers.keccak256(Vault.bytecode)
    );

    const coder = ethers.AbiCoder.defaultAbiCoder();
    const badVaultData = coder.encode(
      ["address", "address", "uint256", "bytes"],
      [await router.getAddress(), guardian.address, TOKEN_PRICE_BNB_PER_TOKEN, "0x6000"]
    );

    await expect(
      factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, badVaultData)
    ).to.be.revertedWithCustomError(factory, "UnapprovedCreationCode");
  });
});
