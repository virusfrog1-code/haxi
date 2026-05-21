const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NFTPVPVaultV1", function () {
  const NFT_PRICE = ethers.parseEther("100000");
  const BET = ethers.parseEther("1000");
  const RATE = ethers.parseUnits("0.00001", 18);
  const TOKEN_PRICE_BNB_PER_TOKEN = RATE;
  const DEAD = "0x000000000000000000000000000000000000dEaD";

  async function deployFixture() {
    const [owner, guardian, alice, bob, carol] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(ethers.ZeroAddress, RATE);
    await owner.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("100") });

    const Vrf = await ethers.getContractFactory("MockVRFCoordinator");
    const vrf = await Vrf.deploy();

    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const vault = await Vault.deploy(
      await token.getAddress(),
      await router.getAddress(),
      owner.address,
      guardian.address,
      await vrf.getAddress(),
      ethers.ZeroHash,
      0,
      TOKEN_PRICE_BNB_PER_TOKEN
    );

    const nft = await ethers.getContractAt("PvpEntryNFT", await vault.entryNft());
    await vault.setTier(1, BET, true);

    for (const user of [alice, bob, carol]) {
      await token.mint(user.address, ethers.parseEther("100000000"));
      await token.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    }

    return { owner, guardian, alice, bob, carol, token, router, vrf, vault, nft };
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

    await expect(vault.connect(alice).enterQueue(1, 1, BET)).to.be.revertedWithCustomError(vault, "InvalidBetAmount");
  });

  it("enterQueue locks NFT", async function () {
    const { alice, bob, vault, nft } = await deployFixture();
    await mintOne(vault, alice);

    await vault.connect(alice).enterQueue(1, 1, BET);

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
    await vault.connect(alice).enterQueue(1, 1, BET);
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

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(alice).leaveQueue(1);

    expect(await nft.locked(1)).to.equal(false);
    expect(await token.balanceOf(alice.address)).to.equal(before);
  });

  it("settles with winner receiving 70% of loser bet and burns loser NFT", async function () {
    const { alice, bob, vault, nft, token, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    const aliceBefore = await token.balanceOf(alice.address);
    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);

    await vrf.fulfill(await vault.getAddress(), 1, 0);

    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore + ethers.parseEther("700"));
    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await nft.locked(1)).to.equal(false);
    expect(await token.balanceOf(DEAD)).to.equal(ethers.parseEther("100000") + ethers.parseEther("150"));
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("100000") + ethers.parseEther("150"));
    expect(await vault.pvpLossTokenBuffer()).to.equal(ethers.parseEther("150"));
  });

  it("reduces activeSupply after NFT burn and allows later minting while active supply stays capped", async function () {
    const { alice, bob, vault, nft, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

    expect(await nft.activeSupply()).to.equal(1n);
    expect(await nft.totalBurnedNFT()).to.equal(1n);
    expect(await nft.totalMintedEver()).to.equal(2n);

    await mintOne(vault, bob);
    expect(await nft.activeSupply()).to.equal(2n);
    expect(await nft.totalMintedEver()).to.equal(3n);
    expect(await nft.ownerOf(3)).to.equal(bob.address);
  });

  it("preserves loser historical NFT dividends after loser NFT is burned", async function () {
    const { owner, alice, bob, vault, nft, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

    await expect(nft.ownerOf(2)).to.be.reverted;
    expect(await vault.pendingNftDividends(bob.address)).to.equal(ethers.parseEther("0.25"));
    await vault.connect(bob).claimNftDividends();
    expect(await vault.pendingNftDividends(bob.address)).to.equal(0n);
  });

  it("sets LossVault quota to 150% of losing principal BNB value", async function () {
    const { alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

    expect(await vault.lossQuotaOf(bob.address)).to.equal(ethers.parseEther("0.015"));
  });

  it("uses fixed token price for LossVault quota instead of router spot quote", async function () {
    const { owner, alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await expect(vault.connect(owner).setTokenPriceBnbPerToken(ethers.parseUnits("0.00002", 18)))
      .to.emit(vault, "TokenPriceBnbPerTokenUpdated")
      .withArgs(TOKEN_PRICE_BNB_PER_TOKEN, ethers.parseUnits("0.00002", 18));

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

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
    const { owner, alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("0.03") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(ethers.parseEther("0.015"));
    await vault.connect(bob).claimLossDividends();
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
    expect(await vault.totalLossQuota()).to.equal(0n);

    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    expect(await vault.pendingLossDividends(bob.address)).to.equal(0n);
  });

  it("does not let a new loser claim historical LossVault income from before their quota", async function () {
    const { owner, alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });
    expect(await vault.lossUndistributedBnb()).to.equal(ethers.parseEther("0.5"));

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

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
    const { owner, alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await vault.connect(owner).convertMintBuffers(0, 0, await deadline());

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);

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

    await vault.connect(alice).enterQueue(1, 1, BET);
    await expect(vault.connect(alice).enterQueue(2, 2, BET)).to.be.revertedWithCustomError(
      vault,
      "PlayerAlreadyActive"
    );
  });

  it("matched players cannot leaveQueue, but owner can emergency cancel and refund", async function () {
    const { owner, alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);

    await expect(vault.connect(alice).leaveQueue(1)).to.be.revertedWithCustomError(vault, "NoQueuedEntry");
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

  it("lets a matched player emergency cancel and refund without quota, burn, or winner payout", async function () {
    const { alice, bob, vault, nft, token } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    const aliceBefore = await token.balanceOf(alice.address);
    const bobBefore = await token.balanceOf(bob.address);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vault.connect(alice).emergencyCancelMatch(1);

    expect(await nft.locked(1)).to.equal(false);
    expect(await nft.locked(2)).to.equal(false);
    expect(await token.balanceOf(alice.address)).to.equal(aliceBefore);
    expect(await token.balanceOf(bob.address)).to.equal(bobBefore);
    expect(await vault.lossQuotaOf(alice.address)).to.equal(0n);
    expect(await vault.lossQuotaOf(bob.address)).to.equal(0n);
    expect(await vault.totalBurnedToken()).to.equal(ethers.parseEther("100000"));
  });

  it("claimNftDividends and claimLossDividends reduce reserved balances correctly", async function () {
    const { owner, alice, bob, vault, vrf } = await deployFixture();
    await mintOne(vault, alice);
    await mintOne(vault, bob);
    await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("1") });

    const nftReservedBefore = await vault.nftReservedBnb();
    const aliceNftPending = await vault.pendingNftDividends(alice.address);
    await vault.connect(alice).claimNftDividends();
    expect(await vault.nftReservedBnb()).to.equal(nftReservedBefore - aliceNftPending);
    await expectSolvent(vault);

    await vault.connect(alice).enterQueue(1, 1, BET);
    await vault.connect(bob).enterQueue(1, 2, BET);
    await vrf.fulfill(await vault.getAddress(), 1, 0);
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
      "claimNftDividends",
      "claimLossDividends",
      "convertMintBuffers",
      "rescueExcessBNB"
    ]);
    expect(schema.methods[4].inputs[0].name).to.equal("tokenAmount");
    expect(schema.methods[4].approvals[0].amountFieldName).to.equal("tokenAmount");
    expect(schema.methods[5].inputs[2].name).to.equal("betAmount");
    expect(schema.methods[5].approvals[0].amountFieldName).to.equal("betAmount");
    expect(schema.methods[9].inputs[0].name).to.equal("minNftBnbOut");
    expect(schema.methods[9].inputs[1].name).to.equal("minLossBnbOut");
    expect(schema.methods[9].inputs[2].name).to.equal("deadline");
  });

  it("factory creates NFTPVPVaultV1 and exposes Flap vaultDataSchema", async function () {
    const { owner, guardian, token, router, vrf } = await deployFixture();
    const Factory = await ethers.getContractFactory("NFTPVPVaultFactory");
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const approvedHash = ethers.keccak256(Vault.bytecode);
    const factory = await Factory.deploy(
      owner.address,
      await router.getAddress(),
      guardian.address,
      await vrf.getAddress(),
      ethers.ZeroHash,
      0,
      TOKEN_PRICE_BNB_PER_TOKEN,
      approvedHash
    );

    const schema = await factory.vaultDataSchema();
    expect(schema.fields.length).to.equal(7);

    const coder = ethers.AbiCoder.defaultAbiCoder();
    const vaultData = coder.encode(
      ["address", "address", "address", "bytes32", "uint64", "uint256", "bytes"],
      [
        await router.getAddress(),
        guardian.address,
        await vrf.getAddress(),
        ethers.ZeroHash,
        0,
        TOKEN_PRICE_BNB_PER_TOKEN,
        Vault.bytecode
      ]
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
    const { owner, guardian, token, router, vrf } = await deployFixture();
    const Factory = await ethers.getContractFactory("NFTPVPVaultFactory");
    const Vault = await ethers.getContractFactory("NFTPVPVaultV1");
    const factory = await Factory.deploy(
      owner.address,
      await router.getAddress(),
      guardian.address,
      await vrf.getAddress(),
      ethers.ZeroHash,
      0,
      TOKEN_PRICE_BNB_PER_TOKEN,
      ethers.keccak256(Vault.bytecode)
    );

    const coder = ethers.AbiCoder.defaultAbiCoder();
    const badVaultData = coder.encode(
      ["address", "address", "address", "bytes32", "uint64", "uint256", "bytes"],
      [await router.getAddress(), guardian.address, await vrf.getAddress(), ethers.ZeroHash, 0, TOKEN_PRICE_BNB_PER_TOKEN, "0x6000"]
    );

    await expect(
      factory.createVault(await token.getAddress(), ethers.ZeroAddress, owner.address, badVaultData)
    ).to.be.revertedWithCustomError(factory, "UnapprovedCreationCode");
  });
});
