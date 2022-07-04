import { expect } from "chai";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { waffle } from "hardhat";
import { deployContract } from "./shared/fixtures";

describe("OrderBook", () => {
  const { provider } = waffle;
  const [, user0, user1, executor] = provider.getWallets();
  let vault: Contract;
  let usdg: Contract;
  let bnb: Contract;
  let bnbPriceFeed: Contract;
  let usdc: Contract;
  let order: Contract;
  let vaultPriceFeed: Contract;
  let weth: Contract;

  beforeEach(async () => {
    bnb = await deployContract("MockERC20", ["BNB", "BNB", 18]);
    bnbPriceFeed = await deployContract("MockPriceFeed", [18]);

    vaultPriceFeed = await deployContract("VaultPriceFeed", []);

    usdc = await deployContract("MockERC20", ["USDC", "USDC", 6]);

    weth = await deployContract("WETH9Mock", []);

    usdg = await deployContract("MockERC20", ["USDG", "USDG", 18]);

    vault = await deployContract("Vault", [
      weth.address,
      usdc.address,
      usdg.address,
      vaultPriceFeed.address,
    ]);

    order = await deployContract("OrderBook", [vault.address, weth.address]);

    await bnbPriceFeed.setLatestAnswer(parseUnits("300", 18));

    await vaultPriceFeed.configToken(bnb.address, bnbPriceFeed.address);

    await vault.setPlugin(order.address);

    await vault.setWhitelistedToken(bnb.address);
  });

  it("should revert increase order if trigger price not passed", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createIncreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order.connect(executor).executeIncreaseOrder(user0.address, 1)
    ).to.be.revertedWith("OrderBook: invalid price for execution");
  });

  it("should revert if cancel order not exist", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createIncreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order.connect(user0).cancelIncreaseOrder(2)
    ).to.be.revertedWith("OrderBook: non-existent order");
  });

  it("should update increase order success", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createIncreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order
        .connect(user0)
        .updateIncreaseOrder(1, 0, parseUnits("190", 6), false)
    ).to.be.emit(order, "UpdateIncreaseOrder");
  });

  it("should execute increase order", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createIncreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await bnbPriceFeed.setLatestAnswer(parseUnits("180", 18));

    await expect(
      order.connect(executor).executeIncreaseOrder(user0.address, 1)
    ).to.be.emit(order, "ExecuteIncreaseOrder");
  });

  it("should create decrease order", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await expect(
      order
        .connect(user0)
        .createDecreaseOrder(
          bnb.address,
          parseUnits("200", 6),
          parseUnits("400", 6),
          true,
          parseUnits("180", 18),
          false
        )
    ).to.be.emit(order, "CreateDecreaseOrder");
  });

  it("should revert decrease order if trigger price not passed", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createDecreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order.connect(executor).executeDecreaseOrder(user0.address, 1)
    ).to.be.revertedWith("OrderBook: invalid price for execution");
  });

  it("should update decrease order success", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createDecreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order
        .connect(user0)
        .updateDecreaseOrder(
          1,
          0,
          parseUnits("400", 6),
          parseUnits("190", 6),
          false
        )
    ).to.be.emit(order, "UpdateDecreaseOrder");
  });

  it("should execute decrease order", async () => {
    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(order.address, parseUnits("200", 6));

    await order
      .connect(user0)
      .createIncreaseOrder(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        true,
        parseUnits("180", 18),
        false
      );

    await bnbPriceFeed.setLatestAnswer(parseUnits("180", 18));

    await expect(
      order.connect(executor).executeIncreaseOrder(user0.address, 1)
    ).to.be.emit(order, "ExecuteIncreaseOrder");

    await order
      .connect(user0)
      .createDecreaseOrder(
        bnb.address,
        parseUnits("400", 6),
        0,
        true,
        parseUnits("180", 18),
        false
      );

    await expect(
      order.connect(executor).executeDecreaseOrder(user0.address, 1)
    ).to.be.emit(order, "ExecuteDecreaseOrder");
  });
});
