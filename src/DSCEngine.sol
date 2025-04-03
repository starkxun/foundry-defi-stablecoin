// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @author  starkxun
 * @title   DSCEngine
 * @dev     .
 * @notice  .
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // Errors     //
    ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine_TransfermFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSC_Engine__HealthFactorNotImproved();

    ///////////////////////
    // Type   //
    ///////////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    // state variables   //
    ///////////////////////
    // 用于调整 Chainlink 价格预言机返回的价格精度
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    // 用于处理 Solidity 中的小数计算（Solidity 不支持浮点数）
    uint256 private constant PRECISION = 1e18;
    // 用于计算清算阈值（例如 50%）
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    // 健康因子的最小阈值，低于此值时用户可能会被清算
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    // 存储每个抵押品代币对应的价格预言机地址
    mapping(address token => address priceFeed) private s_priceFeeds;
    // 存储每个用户存入的每种抵押品的数量
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // 存储每个用户铸造的 DSC 数量
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    // 存储所有允许的抵押品代币地址
    address[] private s_collateralTokens;

    // 稳定币合约的实例，用于与 DSC 合约交互
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    // Modifiers  //
    ////////////////
    // 确保存入的抵押品数量大于零
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    // 确保传入的代币地址是系统允许的抵押品类型

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // tokenAddress 抵押品的地址数组
    // priceFeedAddress 抵押品对应的价格预言机地址数组
    // dscAddress DSC 稳定币合约地址
    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        // 每个抵押品代币都需要一个对应的价格预言机地址
        // 因此这两个数组的长度必须相同
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // 将每个抵押品代币的地址与其对应的价格预言机地址关联起来
        // 并存储在状态变量 s_priceFeeds 中
        // 后续可以通过 s_priceFeeds 获取抵押品的实时价格，用于计算抵押品的价值和健康因子
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        // 将传入的 dscAddress 转换为 DecentralizedStableCoin 合约实例
        // 并存储在状态变量 i_dsc 中
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////
    // Events     //
    ///////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 mount
    );

    // 允许用户一次性存入抵押品并铸造 DSC
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral) public {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountCollateral);
    }

    // 允许用户存入抵押品，但不立即铸造 DSC
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // 将用户存入的抵押品数量记录到合约的状态变量 s_collateralDeposited 中
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        // 触发一个事件，通知外部应用（如前端或监控工具）用户已经存入抵押品
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // 用户存入的抵押品从用户钱包转移到合约地址
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransfermFailed();
        }
    }

    // 允许用户销毁 DSC 并赎回抵押品
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // 允许用户直接赎回抵押品，而不需要销毁 DSC
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        // emit CollateralRedeemed(msg.sender,tokenCollateralAddress,amountCollateral);

        // bool success = IERC20(tokenCollateralAddress).transfer(msg.sender,amountCollateral);
        // if(!success){
        //     revert DSCEngine_TransfermFailed();
        // }
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 允许用户铸造 DSC
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // 检查用户的健康因子，确保铸造后不会导致健康因子低于阈值
        _revertIfHealthFactorIsBroken(msg.sender);
        // 调用稳定币合约的 mint 方法，铸造 DSC 并发送给用户
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    // 允许用户销毁 DSC
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 清算功能，当用户的抵押品价值低于某个阈值时，其他用户可以清算该用户的抵押品
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingGetHealthFactor = _healthFactor(user);
        if (endingGetHealthFactor <= startingUserHealthFactor) {
            revert DSC_Engine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    // 计算用户的健康因子（Health Factor），用于评估用户的抵押品是否足够
    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal View Functions //
    ///////////////////////////////////////

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransfermFailed();
        }
        // 调用稳定币合约的 burn 方法，销毁用户的 DSC
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransfermFailed();
        }
    }

    // 获取用户的 DSC 铸造数量和抵押品总价值
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    // 计算用户的健康因子
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForshold * PRECISION) / totalDscMinted;
        // return (collateralValueInUsd  / totalDscMinted);
    }

    // 检查用户的健康因子，如果低于阈值则回滚交易
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External View Functions  //
    ///////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stableChecklastestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // 计算用户所有抵押品的总价值（以 USD 计价）
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralVlaueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralVlaueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralVlaueInUsd;
    }

    // 根据价格预言机获取抵押品的 USD 价值
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stableChecklastestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
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

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
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

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
