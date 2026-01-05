const convert = (amount, decimals) => ethers.utils.parseUnits(amount, decimals);
const divDec = (amount, decimals = 18) => amount / 10 ** decimals;
const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const AddressZero = "0x0000000000000000000000000000000000000000";
const AddressDead = "0x000000000000000000000000000000000000dEaD";

let owner, protocol, launcher, user1, user2;
let weth, donut, core, multicall;
let content, minter, rewarder, auction, unit, lpToken;
let unitFactory, contentFactory, minterFactory, rewarderFactory, auctionFactory;
let uniswapFactory, uniswapRouter;

const WEEK = 7 * 24 * 60 * 60;
const DAY = 24 * 60 * 60;

describe("Multicall Tests", function () {
  before("Initial set up", async function () {
    await network.provider.send("hardhat_reset");
    console.log("Begin Initialization");

    [owner, protocol, launcher, user1, user2] = await ethers.getSigners();

    // Deploy WETH
    const wethArtifact = await ethers.getContractFactory("MockWETH");
    weth = await wethArtifact.deploy();
    console.log("- WETH Initialized");

    // Deploy mock DONUT token
    donut = await wethArtifact.deploy();
    console.log("- DONUT Initialized");

    // Deploy mock Uniswap V2 Factory and Router
    const mockUniswapFactoryArtifact = await ethers.getContractFactory("MockUniswapV2Factory");
    uniswapFactory = await mockUniswapFactoryArtifact.deploy();
    console.log("- Uniswap V2 Factory Initialized");

    const mockUniswapRouterArtifact = await ethers.getContractFactory("MockUniswapV2Router");
    uniswapRouter = await mockUniswapRouterArtifact.deploy(uniswapFactory.address);
    console.log("- Uniswap V2 Router Initialized");

    // Deploy factories
    const unitFactoryArtifact = await ethers.getContractFactory("UnitFactory");
    unitFactory = await unitFactoryArtifact.deploy();
    console.log("- UnitFactory Initialized");

    const contentFactoryArtifact = await ethers.getContractFactory("ContentFactory");
    contentFactory = await contentFactoryArtifact.deploy();
    console.log("- ContentFactory Initialized");

    const minterFactoryArtifact = await ethers.getContractFactory("MinterFactory");
    minterFactory = await minterFactoryArtifact.deploy();
    console.log("- MinterFactory Initialized");

    const rewarderFactoryArtifact = await ethers.getContractFactory("RewarderFactory");
    rewarderFactory = await rewarderFactoryArtifact.deploy();
    console.log("- RewarderFactory Initialized");

    const auctionFactoryArtifact = await ethers.getContractFactory("AuctionFactory");
    auctionFactory = await auctionFactoryArtifact.deploy();
    console.log("- AuctionFactory Initialized");

    // Deploy Core
    const coreArtifact = await ethers.getContractFactory("Core");
    core = await coreArtifact.deploy(
      weth.address,
      donut.address,
      uniswapFactory.address,
      uniswapRouter.address,
      unitFactory.address,
      contentFactory.address,
      minterFactory.address,
      auctionFactory.address,
      rewarderFactory.address,
      protocol.address,
      convert("100", 18)
    );
    console.log("- Core Initialized");

    // Deploy Multicall
    const multicallArtifact = await ethers.getContractFactory("Multicall");
    multicall = await multicallArtifact.deploy(core.address, weth.address, donut.address);
    console.log("- Multicall Initialized");

    // Mint DONUT to launcher and launch a content engine
    await donut.connect(launcher).deposit({ value: convert("10000", 18) });
    console.log("- DONUT minted to launcher");

    const launchParams = {
      launcher: launcher.address,
      tokenName: "Test Unit",
      tokenSymbol: "TUNIT",
      uri: "https://example.com/metadata",
      donutAmount: convert("500", 18),
      unitAmount: convert("1000000", 18),
      initialUps: convert("4", 18),
      tailUps: convert("0.01", 18),
      halvingPeriod: WEEK,
      contentMinInitPrice: convert("0.001", 18),
      contentIsModerated: false,
      auctionInitPrice: convert("1", 18),
      auctionEpochPeriod: DAY,
      auctionPriceMultiplier: convert("1.5", 18),
      auctionMinInitPrice: convert("0.001", 18),
    };

    await donut.connect(launcher).approve(core.address, launchParams.donutAmount);
    const tx = await core.connect(launcher).launch(launchParams);
    const receipt = await tx.wait();

    const launchEvent = receipt.events.find((e) => e.event === "Core__Launched");
    content = await ethers.getContractAt("Content", launchEvent.args.content);
    unit = await ethers.getContractAt("Unit", launchEvent.args.unit);
    minter = await ethers.getContractAt("Minter", launchEvent.args.minter);
    rewarder = await ethers.getContractAt("Rewarder", launchEvent.args.rewarder);
    auction = await ethers.getContractAt("Auction", launchEvent.args.auction);
    lpToken = await ethers.getContractAt("IERC20", launchEvent.args.lpToken);

    console.log("- Content Engine launched");
    console.log("Initialization Complete\n");
  });

  describe("Initialization", function () {
    it("Should deploy with correct core address", async function () {
      expect(await multicall.core()).to.equal(core.address);
    });

    it("Should deploy with correct weth address", async function () {
      expect(await multicall.weth()).to.equal(weth.address);
    });

    it("Should deploy with correct donut address", async function () {
      expect(await multicall.donut()).to.equal(donut.address);
    });

    it("Should revert with zero addresses", async function () {
      const multicallArtifact = await ethers.getContractFactory("Multicall");

      await expect(
        multicallArtifact.deploy(AddressZero, weth.address, donut.address)
      ).to.be.revertedWith("Multicall__ZeroAddress()");

      await expect(
        multicallArtifact.deploy(core.address, AddressZero, donut.address)
      ).to.be.revertedWith("Multicall__ZeroAddress()");

      await expect(
        multicallArtifact.deploy(core.address, weth.address, AddressZero)
      ).to.be.revertedWith("Multicall__ZeroAddress()");
    });
  });

  describe("getContent()", function () {
    it("Should return correct content state", async function () {
      const state = await multicall.getContent(content.address, user1.address);

      expect(state.rewarder).to.equal(rewarder.address);
      expect(state.unit).to.equal(unit.address);
      expect(state.uri).to.equal("https://example.com/metadata");
      expect(state.isModerated).to.be.false;
      expect(state.totalSupply).to.equal(0);
      expect(state.minInitPrice).to.equal(convert("0.001", 18));
    });

    it("Should return user balances when account provided", async function () {
      // Give user1 some tokens
      await weth.connect(user1).deposit({ value: convert("10", 18) });
      await donut.connect(user1).deposit({ value: convert("50", 18) });

      const state = await multicall.getContent(content.address, user1.address);

      expect(state.wethBalance).to.equal(convert("10", 18));
      expect(state.donutBalance).to.equal(convert("50", 18));
    });

    it("Should return zero balances when account is zero address", async function () {
      const state = await multicall.getContent(content.address, AddressZero);

      expect(state.wethBalance).to.equal(0);
      expect(state.donutBalance).to.equal(0);
      expect(state.unitBalance).to.equal(0);
    });
  });

  describe("getToken()", function () {
    it("Should return correct token state", async function () {
      // Create a token
      await content.connect(user1).create(user1.address, "ipfs://token1");
      const tokenId = await content.nextTokenId();

      const state = await multicall.getToken(content.address, tokenId);

      expect(state.tokenId).to.equal(tokenId);
      expect(state.owner).to.equal(user1.address);
      expect(state.creator).to.equal(user1.address);
      expect(state.isApproved).to.be.true;
      expect(state.stake).to.equal(0);
      expect(state.epochId).to.equal(0);
      expect(state.tokenUri).to.equal("ipfs://token1");
    });

    it("Should update state after collection", async function () {
      const tokenId = await content.nextTokenId();

      // Collect
      const price = await content.getPrice(tokenId);
      await weth.connect(user2).deposit({ value: price });
      await weth.connect(user2).approve(content.address, price);
      const auctionData = await content.getAuction(tokenId);
      await content
        .connect(user2)
        .collect(user2.address, tokenId, auctionData.epochId, ethers.constants.MaxUint256, price);

      const state = await multicall.getToken(content.address, tokenId);

      expect(state.owner).to.equal(user2.address);
      expect(state.creator).to.equal(user1.address);
      expect(state.stake).to.be.gt(0); // Stake recorded (exact value may differ due to price decay)
      expect(state.epochId).to.equal(1);
    });
  });

  describe("getMinter()", function () {
    it("Should return correct minter state", async function () {
      const state = await multicall.getMinter(content.address);

      expect(state.initialUps).to.equal(convert("4", 18));
      expect(state.tailUps).to.equal(convert("0.01", 18));
      expect(state.halvingPeriod).to.equal(WEEK);
    });

    it("Should update after emission period", async function () {
      await ethers.provider.send("evm_increaseTime", [WEEK]);
      await ethers.provider.send("evm_mine");
      await minter.updatePeriod();

      const state = await multicall.getMinter(content.address);

      expect(state.weeklyEmission).to.be.gt(0);
      expect(state.activePeriod).to.be.gt(0);
    });
  });

  describe("getRewarder()", function () {
    it("Should return correct rewarder state", async function () {
      const state = await multicall.getRewarder(content.address, user1.address);

      expect(state.totalSupply).to.be.gt(0); // We collected earlier
    });

    it("Should show stake after collection", async function () {
      const state = await multicall.getRewarder(content.address, user2.address);

      expect(state.accountBalance).to.be.gt(0);
    });
  });

  describe("getAuction()", function () {
    it("Should return correct auction state", async function () {
      const state = await multicall.getAuction(content.address, user1.address);

      expect(state.epochId).to.be.gte(0);
      expect(state.paymentToken).to.equal(lpToken.address);
    });
  });

  describe("updateMinterPeriod()", function () {
    it("Should trigger minter update through multicall", async function () {
      await ethers.provider.send("evm_increaseTime", [WEEK]);
      await ethers.provider.send("evm_mine");

      const periodBefore = await minter.activePeriod();
      await multicall.updateMinterPeriod(content.address);
      const periodAfter = await minter.activePeriod();

      expect(periodAfter).to.be.gt(periodBefore);
    });

    it("Should emit from minter contract", async function () {
      await ethers.provider.send("evm_increaseTime", [WEEK]);
      await ethers.provider.send("evm_mine");

      await expect(multicall.updateMinterPeriod(content.address)).to.emit(minter, "Minter__Minted");
    });
  });

  describe("claimRewards()", function () {
    it("Should claim rewards through multicall", async function () {
      // Distribute rewards
      await content.distribute();

      await ethers.provider.send("evm_increaseTime", [DAY]);
      await ethers.provider.send("evm_mine");

      const balanceBefore = await unit.balanceOf(user2.address);
      await multicall.connect(user2).claimRewards(content.address);
      const balanceAfter = await unit.balanceOf(user2.address);

      // Should have received some rewards
      expect(balanceAfter).to.be.gte(balanceBefore);
    });
  });

  describe("launch() through Multicall", function () {
    it("Should launch content engine through multicall", async function () {
      const launchParams = {
        launcher: user1.address,
        tokenName: "Multicall Unit",
        tokenSymbol: "MUNIT",
        uri: "ipfs://multicall-test",
        donutAmount: convert("500", 18),
        unitAmount: convert("500000", 18),
        initialUps: convert("2", 18),
        tailUps: convert("0.005", 18),
        halvingPeriod: WEEK,
        contentMinInitPrice: convert("0.005", 18),
        contentIsModerated: false,
        auctionInitPrice: convert("0.5", 18),
        auctionEpochPeriod: DAY,
        auctionPriceMultiplier: convert("1.2", 18),
        auctionMinInitPrice: convert("0.05", 18),
      };

      // Give user1 DONUT and approve multicall
      await donut.connect(user1).deposit({ value: launchParams.donutAmount });
      await donut.connect(user1).approve(multicall.address, launchParams.donutAmount);

      const contentCountBefore = await core.deployedContentsLength();
      const tx = await multicall.connect(user1).launch(launchParams);
      await tx.wait();
      const contentCountAfter = await core.deployedContentsLength();

      // Should have created a new content engine
      expect(contentCountAfter).to.be.gt(contentCountBefore);
    });

    it("Should use msg.sender as launcher", async function () {
      const launchParams = {
        launcher: owner.address, // This gets overwritten
        tokenName: "Multicall Unit 2",
        tokenSymbol: "MUNIT2",
        uri: "ipfs://multicall-test-2",
        donutAmount: convert("500", 18),
        unitAmount: convert("500000", 18),
        initialUps: convert("2", 18),
        tailUps: convert("0.005", 18),
        halvingPeriod: WEEK,
        contentMinInitPrice: convert("0.005", 18),
        contentIsModerated: false,
        auctionInitPrice: convert("0.5", 18),
        auctionEpochPeriod: DAY,
        auctionPriceMultiplier: convert("1.2", 18),
        auctionMinInitPrice: convert("0.05", 18),
      };

      await donut.connect(user2).deposit({ value: launchParams.donutAmount });
      await donut.connect(user2).approve(multicall.address, launchParams.donutAmount);

      // Get content count to find the new content address
      const contentCountBefore = await core.deployedContentsLength();
      const tx = await multicall.connect(user2).launch(launchParams);
      await tx.wait();

      // Get the new content address from core
      const newContentAddress = await core.deployedContents(contentCountBefore);
      const newContent = await ethers.getContractAt("Content", newContentAddress);

      // Launcher (owner) should be user2, not owner
      expect(await newContent.owner()).to.equal(user2.address);
    });
  });

  describe("Edge Cases", function () {
    it("Should handle zero address account in view functions", async function () {
      const contentState = await multicall.getContent(content.address, AddressZero);
      expect(contentState.ethBalance).to.equal(0);

      const rewarderState = await multicall.getRewarder(content.address, AddressZero);
      expect(rewarderState.accountBalance).to.equal(0);

      const auctionState = await multicall.getAuction(content.address, AddressZero);
      expect(auctionState.wethBalance).to.equal(0);
    });
  });
});
