//SPDX-Licence-Identifier: MIT
//Handler is going to narrow dow the way we call function this way we don't waste runs
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

//- let handle other contracts that we interact with, which are
//Price Feed
//WETH Token
//WBTC Token

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; //the maximum value of uint96 will be the value

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }
    //call redeemCollateral when you have collateral

    // function depositCollateral(address collateral, uint256 amountCollateral) public {
    //     dsce.depositCollateral(collateral, amountCollateral); //collateral has some random invalid contract address that will failed
    // }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); //bound() is a method from StdInvariant contract

        //its cut down reverts to 0 like this
        //[PASS] invariant_protocolMustHaveMoreValueThanTotalSupply() (runs: 128, calls: 16384, reverts: 0)
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral); //address(collateral) is a valid contract address that will go through
        vm.stopPrank();
        //double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    //to update the collateral price if their is change in chainlink price feed
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPrice = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPrice);
    // }

    //Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    //put all the getter functions in this function
    function invariant_gettersShouldNotRevert() public view {
        dsce.getLiquidationBonus();
        dsce.getPrecision();
        dsce.getAdditionalFeedPrecision();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getHealthFactor();
    }

    //- let run this command to view all the functions with their function selector in DSCEngine contract
    //adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-defi-stablecoin-f23$ forge inspect DSCEngine methods
}

//- create libraries/OracleLib.sol file in src folder
//- let build a Uiversal Upgradable Smart Contract in order to implement contract upgrade.
// adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-defi-stablecoin-f23$ cd ..
// adduser@LAPTOP-EM3P6O44:~/foundry-f23$ mkdir foundry-upgrades-f23
// adduser@LAPTOP-EM3P6O44:~/foundry-f23$ cd foundry-upgrades-f23
// adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-upgrades-f23$ code .
//- go to docs.openzeppelin.com/contracts/4.x/api/proxy/#transparent, scroll down to Transparent vs UUPS Proxies
//- UUPS Proxies eventuall remove the upgrade that we have in a centralize entity that
//enable upgrade, so that the code is truely immutable.
//- UUPS proxies is technically cheaper to deploy.
//- let runforge init like this
//adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-upgrades-f23$ forge init
//- remove the following file:
//* remove Counter.s.sol from script folder
//* remove Counter.sol from src folder
//* remove Counter.t.sol from test folder
//- create BoxV1.sol file inside src folder
//- create BoxV2.sol file inside src folder
//- let install openzeppelin contrats upgradeable like this
//adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-upgrades-f23$ forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-commit
//- open foundry.toml file to add this
//remappings = ["@openzeppelin/contracts-upgradeable=lib/openzeppelin-contracts-upgradeable/contracts"]
