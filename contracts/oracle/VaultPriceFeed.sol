// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/AggregatorV3Interface.sol";

contract VaultPriceFeed is Ownable {
    struct TokenConfig {
        address chainlinkFeed;
        /// @dev 10 ^ token decimals
        uint256 baseUnit;
        /// @dev 10 ^ price decmials
        uint256 priceUnit;
    }

    uint8 public constant CALCULATE_ROUND = 3; // number of rounds to calculate

    mapping(address => TokenConfig) public tokenConfigs;

    event TokenConfigChanged(address indexed token, address chainlinkFeed);

    function getPrice(address _token, bool _maximise)
        external
        view
        returns (uint256)
    {
        TokenConfig storage config = tokenConfigs[address(_token)];
        AggregatorV3Interface feed = AggregatorV3Interface(
            config.chainlinkFeed
        );
        uint256 price = uint256(feed.latestAnswer());
        uint80 roundId = feed.latestRound();
        for (uint80 i = 0; i < CALCULATE_ROUND; i++) {
            if (roundId <= i) {
                break;
            }
            uint256 p;
            (, int256 _p, , , ) = feed.getRoundData(roundId - i);
            require(_p > 0, "VaultPriceFeed::getPrice invalid price");
            p = uint256(_p);

            if (_maximise && p > price) {
                price = p;
                continue;
            }

            if (!_maximise && p < price) {
                price = p;
            }
        }

        return (1e36 * price) / config.priceUnit / config.baseUnit;
    }

    /**
     * @notice config token
     * @param _token address of token
     * @param _chainlinkPriceFeed address of Chainlink compatible price feed
     */
    function configToken(address _token, address _chainlinkPriceFeed)
        external
        onlyOwner
    {
        require(_chainlinkPriceFeed != address(0), "priceFeedRequired");
        uint256 _priceDecimals = AggregatorV3Interface(_chainlinkPriceFeed)
            .decimals();

        uint256 underlyingDecimals = ERC20(_token).decimals();

        TokenConfig memory config = TokenConfig({
            chainlinkFeed: _chainlinkPriceFeed,
            baseUnit: 10**underlyingDecimals,
            priceUnit: 10**_priceDecimals
        });

        tokenConfigs[_token] = config;
        emit TokenConfigChanged(_token, _chainlinkPriceFeed);
    }
}
