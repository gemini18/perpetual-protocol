import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
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

  beforeEach(async () => {
    bnb = await deployContract("MockERC20", ["BNB", "BNB", 18]);
    bnbPriceFeed = await deployContract("MockPriceFeed", [18]);

    vaultPriceFeed = await deployContract("VaultPriceFeed", []);

    usdc = await deployContract("MockERC20", ["USDC", "USDC", 6]);

    weth = await deployContract("WETH9Mock", []);

    vault = await deployContract("Vault", [
      weth.address,
      usdc.address,
      vaultPriceFeed.address,
      parseUnits("5", 18), // liquidation fee
      60000, // fundingRateFactor
    ]);

    usdg = await deployContract("MockERC20", ["USDG", "USDG", 18]);

    market = await deployContract("Market", [vault.address, weth.address]);

    await market.setMaxTimeDelay(300);

    await bnbPriceFeed.setLatestAnswer(parseUnits("300", 18));

    await vaultPriceFeed.configToken(bnb.address, bnbPriceFeed.address);

    await vault.setPlugin(market.address);

    await vault.setWhitelistedToken(bnb.address);
  });

  it("validateExecution", async () => {
    await bnbPriceFeed.setLatestAnswer(parseUnits("600", 18));
    await usdc.connect(user0).mint(parseUnits("300", 18));
    await usdc.connect(user0).approve(market.address, parseUnits("300", 18));

    await market
      .connect(user0)
      .createIncreasePosition(
        bnb.address,
        parseUnits("300", 18),
        parseUnits("600", 18),
        true,
        { value: 4000 }
      );

    const requestKey = await market.getRequestKey(user0.address, 1);

    console.log("request", await market.increasePositionRequests(requestKey));

    await market.connect(executor).executeIncreasePosition(requestKey);

    const positionKey = await vault.getPositionKey(
      user0.address,
      bnb.address,
      true
    );

    console.log("vault", await vault.positions(positionKey));
  });
});
