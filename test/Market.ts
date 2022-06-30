import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { ethers } from "hardhat";
import { deployContract } from "./shared/fixtures";

declare let waffle: any;

describe("Market", async () => {
  const provider = waffle.provider;
  const [wallet, user0, user1, executor] = provider.getWallets();
  let vault: Contract;
  let usdg: Contract;
  let bnb: Contract;
  let bnbPriceFeed: Contract;
  let usdc: Contract;
  let market: Contract;
  let vaultPriceFeed: Contract;
  let weth: Contract;

  const messages = [
    "NO_ERROR",
    "POSISTION_NOT_EXIST",
    "LOSSES_EXCEED_COLLATERAL",
    "MAX_LEVERAGE_EXCEED",
  ];

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

    await vault.setErrors(messages);

    market = await deployContract("Market", [vault.address, weth.address]);

    await market.setMaxTimeDelay(300);

    await bnbPriceFeed.setLatestAnswer(parseUnits("300", 18));

    await vaultPriceFeed.configToken(bnb.address, bnbPriceFeed.address);

    await vault.setPlugin(market.address);

    await vault.setWhitelistedToken(bnb.address);
  });

  it("validateExecution", async () => {
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

    const requestKey = await market.getRequestKey(user0.address, 1);

    console.log("request", await market.increasePositionRequests(requestKey));

    await market.connect(executor).executeIncreasePosition(requestKey);

    const hash = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["address", "address", "bool"],
        [user0.address, bnb.address, false]
      )
    );

    const postion = await vault.positions(hash);

    console.log("position before:", postion);

    await bnbPriceFeed.setLatestAnswer(parseUnits("150", 18));

    await market
      .connect(user0)
      .createDecreasePosition(bnb.address, 0, parseUnits("400", 6), false);

    await market.connect(executor).executeDecreasePosition(requestKey);

    const postion_after = await vault.positions(hash);

    console.log("position after:", postion_after);
  });
});
