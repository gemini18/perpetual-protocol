// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

contract MockPriceFeed {
    int256 public answer;
    uint80 public roundId;
    uint8 public decimals;

    address public gov;

    mapping(uint80 => int256) public answers;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function latestAnswer() public view returns (int256) {
        return answer;
    }

    function latestRound() public view returns (uint80) {
        return roundId;
    }

    function setLatestAnswer(int256 _answer) public {
        roundId = roundId + 1;
        answer = _answer;
        answers[roundId] = _answer;
    }

    // returns roundId, answer, startedAt, updatedAt, answeredInRound
    function getRoundData(uint80 _roundId)
        public
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (_roundId, answers[_roundId], 0, 0, 0);
    }
}
