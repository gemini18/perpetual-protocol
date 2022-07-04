import { expect } from "chai";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { ethers } from "hardhat";
import { deployContract } from "./shared/fixtures";
import { increaseTime } from "./shared/utilities";
import { waffle } from "hardhat";

describe("Market", () => {
  const { provider } = waffle;
  const [, user0, user1, executor] = provider.getWallets();
  let vault: Contract;
  let usdg: Contract;
  let bnb: Contract;
  let bnbPriceFeed: Contract;
  let usdc: Contract;
  let market: Contract;
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

    market = await deployContract("Market", [vault.address, weth.address]);

    await bnbPriceFeed.setLatestAnswer(parseUnits("300", 18));

    await vaultPriceFeed.configToken(bnb.address, bnbPriceFeed.address);

    await vault.setPlugin(market.address);

    await vault.setWhitelistedToken(bnb.address);

    await market.setMaxTimeDelay(300); // 5 minutes
  });

  it("should be revert with increase position expired", async () => {
    await market.setMaxTimeDelay(300); // 5 minutes

    await bnbPriceFeed.setLatestAnswer(parseUnits("200", 18));

    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(market.address, parseUnits("200", 6));

    await market
      .connect(user0)
      .createIncreasePosition(
        bnb.address,
        parseUnits("200", 6),
        parseUnits("400", 6),
        false
      );

    const requestKey = ethers.utils.keccak256(
      ethers.utils.solidityPack(["address", "uint256"], [user0.address, 1])
    );

    await increaseTime(provider, 600);
    await expect(
      market.connect(executor).executeIncreasePosition(requestKey)
    ).to.be.revertedWith("Market::executeIncreasePosition Request has expired");
  });

  it("should execute", async () => {
    await bnbPriceFeed.setLatestAnswer(parseUnits("200", 18));

    await usdc.connect(user1).mint(parseUnits("400", 6));
    await usdc.connect(user1).approve(vault.address, parseUnits("400", 6));

    await vault.connect(user1).buyUSDG(parseUnits("400", 6));

    await usdc.connect(user0).mint(parseUnits("200", 6));
    await usdc.connect(user0).approve(market.address, parseUnits("200", 6));

    await expect(
      market
        .connect(user0)
        .createIncreasePosition(
          bnb.address,
          parseUnits("200", 6),
          parseUnits("400", 6),
          true
        )
    ).to.emit(market, "CreateIncreasePosition");

    const requestKey = ethers.utils.keccak256(
      ethers.utils.solidityPack(["address", "uint256"], [user0.address, 1])
    );

    await expect(
      market.connect(executor).executeIncreasePosition(requestKey)
    ).to.emit(market, "ExecuteIncreasePosition");

    await bnbPriceFeed.setLatestAnswer(parseUnits("220", 18));

    await expect(
      market
        .connect(user0)
        .createDecreasePosition(bnb.address, 0, parseUnits("400", 6), true)
    ).to.emit(market, "CreateDecreasePosition");

    await expect(
      market.connect(executor).executeDecreasePosition(requestKey)
    ).to.emit(market, "ExecuteDecreasePosition");

    expect(await usdc.balanceOf(user0.address)).to.be.equal(
      parseUnits("240", 6)
    );
  });
});
