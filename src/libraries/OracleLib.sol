//SPDX-License-Identifier: MIT

//- let go to https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1, click on Show more details to view the Heartbeat which is time when a new price feed price should show ETH/USD is 3600s == 3600seconds
//we want to write a check to make sure that the price of pricefeed is updating every 3600 seconds

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
* @title OracleLib
* @author Adebara Khadijat
* @notice This library is used to check the Chainlink Oracle for stale data or out of date date.
* If a price is stale or out of date, the function will revert, and render the DSCEngine unusable - this by design
* We want the DSCEngine to freeze if prices become stale.
* 
* So if the Chainlink network explodes and you have a lot of money locked in the protocol... too bad.
*/
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours; //3 * 60 * 60 = 10800 seconds //the 3600seconds is 1 hour

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleLib__StalePrice();
        }

        uint256 secondsSince = block.timestamp - updatedAt; //return seconds in which the priceFeed is being updated
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        //else
        return (roundId, answer, startedAt, updatedAt, answeredInRound);

        //- back to DSCEngine contract to change (, int256 price,,,)=priceFeed.latestRoundData() to (, int256 price,,,)=priceFeed.staleCheckLatestRoundData()
    }
}
