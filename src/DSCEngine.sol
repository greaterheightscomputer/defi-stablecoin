//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// import {OracleLib} from "./libraries/OracleLib.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Adebara Khadijat
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a
 * 1 token == $1 peg
 * This stablecoin has the properties:
 * - Exogenous Collateral -> backing by WETH and WBTC
 * - Dollar Pegged
 * - Algorithmic Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all
 *    collateral <= the value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY lossely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////
    // error      //
    ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddreessesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////
    // Type    //
    /////////////

    using OracleLib for AggregatorV3Interface;

    //////////////////////
    // State Variables  //
    /////////////////////
    // @dev Mapping of token address to price feed address
    mapping(address token => address priceFeeds) private s_priceFeeds;
    //in order for this system to work let go to data.chain.link in order to know the value of ETH and BTC in US Dollar
    // @dev Amount of collateral deposited by user
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //keep track of user collateral deposit
    // @dev Amount of DSC minted by user
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; //keep track of amount mint by users
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //you need to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means a 10% bonus

    /////////////////
    //  Events     //
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /////////////////
    // Modifiers  //
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    // Functions  //
    ////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress //address of DecentralizedStableCoin contract in order to know when to call burn and mint function
    ) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddreessesAndPriceFeedAddressesMustBeSameLength();
        }
        //For example ETH/USD, BTC/USD, MKR/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice This function will deposit your collateral and mint DSC in one transaction
    */
    //deposit ETH & BTC to mint DSC token
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice we are following CEI (Check Effects Interactions) pattern or convention
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral) //check
        isAllowedToken(tokenCollateralAddress) //check
        nonReentrant //check
    {
        //Effects
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; //we are update the state variable so let emit event
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        //Interactions
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * @notice This function burns DSC and redeems underlying collateral in one transaction
    */

    //deposit DSC token to get back their initial deposit ETH or BTC
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    //in order to redeem collateral:
    //1. health factor must be over 1 After collateral pulled out
    //A concept in computer science called DRY: Don't Repeat Yourself
    //We shall be using CEI -> Check, Effects, Interactions
    //CEIB violated -> when I need to check something after a token is transfer.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral) //check
        nonReentrant //check
    {
        //Effects
        // s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral; //we are relying on solidity compiler to throw an error if they want to withdraw more than the collateral they have
        // //since we are updating state variable, we need to emit an event like this
        // emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        // bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        // if (!success) {
        //     revert DSCEngine__TransferFailed();
        // }
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //Check if the collateral value > DSC amount
    /*
    * @notice follows CEI (Check Effect Interaction)
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice they must have more collateral value than the minimum threshold 
    * 
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much DSC stablecoin revert e.g (minted -> 150DCS, deposted -> 100ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint); //if health factor is over-collateralized minted DSCs
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //destroy DSC token in order to get back collateral token
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // s_DSCMinted[msg.sender] -= amount;
        // bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // if (!success) {
        //     revert DSCEngine__TransferFailed();
        // }
        // i_dsc.burn(amount);
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //liquidate occur when DSC stablecoin is below or close to undercollateralized of asset.
    //If we do start nearing undercollaterlization, we need someone to liquidate positions.
    //$100 ETH backing $50 DSC
    //$20 ETH backing $50 DSC <- DSC isn't work $1 this is where liquidation set-in.

    //$75 backing $50 DSC
    //Liquidator take $75 backing and burns off the $50 DSC in order to make sure our protocol stall collaterized.
    //Liquidator get $25 liquidation bonus after burning off $50 DSC
    //If someone is almost undercollateralized, we will pay you to liquidate them!
    /*
    * @param collateral The erc20 collateral address to liquidate from the user.
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor.
    * @notice You can partially liquidate a user.
    * @notice You will get a liquidation bonus for taking the users funds.
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
    * CEI convention: Check Effects Interactions
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //We want to burn their DSC "debt" and allow them take their initial collateral out of the system
        //Bad User: $140 ETH, $100 DSC
        //debtToCover = $100 DSC
        //how much of $100 of DSC = $???ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        //Give them a 10% bonus
        //So we are giving the liquidator $110 of WETH for $100 DSC
        //We should implement a feature of liquidate in the event the protocol is insolvent.
        //insolvent = when a protocol is undercollateralized.
        //And sweep extra amounts into a treasury
        //(0.05 * 10)/100 = 0.005. Getting bonus of 0.005
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);
        //check health factor
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        //if call liquidate function hurt Liquidator then revert
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //this function allow us to see how healthy people are.
    function getHealthFactor() external view {}

    //////////////////////////////////////
    // Public & External View Functions //
    /////////////////////////////////////
    //- let install chainlink in order to get the pricefeed like this
    //adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-defi-stablecoin-f23$ forge install smartcontractkit/chainlink-brownie-contracts@0.6.1 --no-commit
    //- import AggregatorV3Interface onto this contract like this
    //import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
    //- foundry.toml to remapp chainlink
    //remappings=["@chainlink/contracts=lib/chainlink-brownie-contracts/contracts/","@openzeppelin/contracts=lib/openzeppelin-contracts/contracts"]
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // (, int256 price,,,) = priceFeed.latestRoundData(); //return the US dollar equivanlent of crytocoin which are ETH & BTC
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // 1ETH = $1000
        //The returned value from chainlink will be 1000 * 1e8
        //how do I know that ETH/USD has 8 decimal - let go to docs.chain.link/data-feeds/price-feeds/addresses, scroll down, click on Show more details, Search for ETH/USD you will see that its has 8 Dec
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000 * 1e8) * 1000 * 1e18 wei //priceFeed most has the same precision or decimal with 1e18wei like this (1000 * 1e8 * 1e10) * 1000 * 1e18 wei
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, to get the amount they have deposited and map it to the priceFeed, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i]; //return the token collateral address
            uint256 amount = s_collateralDeposited[user][token]; //return collateral in cryptocoin
            totalCollateralValueInUsd += getUsdValue(token, amount); //return the USD value of each token in the array
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH (token)
        //usdAmountInWei / price = ETH
        //$1000 / $2000 = 0.5ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // (, int256 price,,,) = priceFeed.latestRoundData();
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValuelueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValuelueInUsd);
    }

    ///////////////////////////////////////
    // Private & Internal View Functions //
    /////////////////////////////////////

    //to allow anybody to burn DSC
    /*
    * @dev Low-level internal function, do not call unless the function calling it is
    checking for health factors being broken
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    //to allow anybody to be a liquidator or third-party
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
    * Returns how close a user is to liquidation 
    * If a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // return (collateralValueInUsd / totalDscMinted); //liquidate ratio if less 1 = under-collaterized || if greater 1 = over-collaterized
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        //deposited=150ETH / minted=100DSC
        //150 * 50 = 7500 / 100 = (75/100) < 1
        //deposited=1000ETH / minted=100DSC
        //1000 * 50 = 50000 / 100 = (500/100) < 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; //its return true health factor
    }

    //_ before the function name means the function as internal visibility
    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor (do user have enough collateral?)
        //2. Revert if they don't
        //- let check health factor by going to view how to calculate health factor https://docs.aave.com/risk/asset-risk/risk-parameters#health-factor
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
//- let create DeployDSC.s.sol file inside script folder in order to deploy the contract
//- HelperConfig.s.sol file inside script to setup configurations
//- DSCEngineTest.t.sol file inside test folder for the purpose of unit test
//- let do coverage like this
//adduser@LAPTOP-EM3P6O44:~/foundry-f23/foundry-defi-stablecoin-f23$ forge coverage
