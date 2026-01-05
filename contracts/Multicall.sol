// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IContent} from "./interfaces/IContent.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {ICore} from "./interfaces/ICore.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title Multicall
 * @author heesho
 * @notice Helper contract for batched operations and aggregated view functions.
 * @dev Provides ETH wrapping for collecting content and comprehensive state queries.
 */
contract Multicall {
    using SafeERC20 for IERC20;

    error Multicall__ZeroAddress();

    /*----------  IMMUTABLES  -------------------------------------------*/

    address public immutable core;
    address public immutable weth;
    address public immutable donut;

    /*----------  STRUCTS  ----------------------------------------------*/

    /**
     * @notice Aggregated state for a Content contract.
     */
    struct ContentState {
        address rewarder;
        address unit;
        address treasury;
        string uri;
        bool isModerated;
        uint256 totalSupply;
        uint256 minInitPrice;
        uint256 unitPrice;
        uint256 ethBalance;
        uint256 wethBalance;
        uint256 donutBalance;
        uint256 unitBalance;
    }

    /**
     * @notice State for a single content token.
     */
    struct TokenState {
        uint256 tokenId;
        address owner;
        address creator;
        bool isApproved;
        uint256 stake;
        uint256 epochId;
        uint256 initPrice;
        uint256 startTime;
        uint256 price;
        string tokenUri;
    }

    /**
     * @notice Aggregated state for a Minter contract.
     */
    struct MinterState {
        uint256 activePeriod;
        uint256 weeklyEmission;
        uint256 currentUps;
        uint256 initialUps;
        uint256 tailUps;
        uint256 halvingPeriod;
        uint256 startTime;
    }

    /**
     * @notice Aggregated state for a Rewarder contract.
     */
    struct RewarderState {
        uint256 totalSupply;
        uint256 accountBalance;
        uint256 earnedUnit;
        uint256 earnedQuote;
        uint256 leftUnit;
        uint256 leftQuote;
    }

    /**
     * @notice Aggregated state for an Auction contract.
     */
    struct AuctionState {
        uint256 epochId;
        uint256 initPrice;
        uint256 startTime;
        address paymentToken;
        uint256 price;
        uint256 paymentTokenPrice;
        uint256 wethAccumulated;
        uint256 wethBalance;
        uint256 donutBalance;
        uint256 paymentTokenBalance;
    }

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    /**
     * @notice Deploy the Multicall helper contract.
     * @param _core Core contract address
     * @param _weth Wrapped ETH address
     * @param _donut DONUT token address
     */
    constructor(address _core, address _weth, address _donut) {
        if (_core == address(0) || _weth == address(0) || _donut == address(0)) revert Multicall__ZeroAddress();
        core = _core;
        weth = _weth;
        donut = _donut;
    }

    /*----------  EXTERNAL FUNCTIONS  -----------------------------------*/

    /**
     * @notice Collect content using ETH (wraps to WETH automatically).
     * @dev Wraps sent ETH to WETH, approves the content, and calls collect(). Refunds excess.
     * @param content Content contract address
     * @param tokenId Token ID to collect
     * @param epochId Expected epoch ID
     * @param deadline Transaction deadline
     * @param maxPrice Maximum price willing to pay
     */
    function collect(
        address content,
        uint256 tokenId,
        uint256 epochId,
        uint256 deadline,
        uint256 maxPrice
    ) external payable {
        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).safeApprove(content, 0);
        IERC20(weth).safeApprove(content, msg.value);
        IContent(content).collect(msg.sender, tokenId, epochId, deadline, maxPrice);

        // Refund unused WETH
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));
        if (wethBalance > 0) {
            IERC20(weth).safeTransfer(msg.sender, wethBalance);
        }
    }

    /**
     * @notice Buy from an auction using LP tokens.
     * @dev Transfers LP tokens from caller, approves auction, and executes buy.
     * @param content Content contract address (used to look up auction)
     * @param epochId Expected epoch ID
     * @param deadline Transaction deadline
     * @param maxPaymentTokenAmount Maximum LP tokens willing to pay
     */
    function buy(address content, uint256 epochId, uint256 deadline, uint256 maxPaymentTokenAmount) external {
        address auction = ICore(core).contentToAuction(content);
        address paymentToken = IAuction(auction).paymentToken();
        uint256 price = IAuction(auction).getPrice();
        address[] memory assets = new address[](1);
        assets[0] = weth;

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
        IERC20(paymentToken).safeApprove(auction, 0);
        IERC20(paymentToken).safeApprove(auction, price);
        IAuction(auction).buy(assets, msg.sender, epochId, deadline, maxPaymentTokenAmount);
    }

    /**
     * @notice Launch a new content engine via Core.
     * @dev Transfers DONUT from caller, approves Core, and calls launch with caller as launcher.
     * @param params Launch parameters (launcher field is overwritten with msg.sender)
     */
    function launch(ICore.LaunchParams calldata params)
        external
        returns (
            address unit,
            address content,
            address minter,
            address rewarder,
            address auction,
            address lpToken
        )
    {
        // Transfer DONUT from user
        IERC20(donut).safeTransferFrom(msg.sender, address(this), params.donutAmount);
        IERC20(donut).safeApprove(core, 0);
        IERC20(donut).safeApprove(core, params.donutAmount);

        // Build params with msg.sender as launcher
        ICore.LaunchParams memory launchParams = ICore.LaunchParams({
            launcher: msg.sender,
            tokenName: params.tokenName,
            tokenSymbol: params.tokenSymbol,
            uri: params.uri,
            donutAmount: params.donutAmount,
            unitAmount: params.unitAmount,
            initialUps: params.initialUps,
            tailUps: params.tailUps,
            halvingPeriod: params.halvingPeriod,
            contentMinInitPrice: params.contentMinInitPrice,
            contentIsModerated: params.contentIsModerated,
            auctionInitPrice: params.auctionInitPrice,
            auctionEpochPeriod: params.auctionEpochPeriod,
            auctionPriceMultiplier: params.auctionPriceMultiplier,
            auctionMinInitPrice: params.auctionMinInitPrice
        });

        return ICore(core).launch(launchParams);
    }

    /**
     * @notice Update the minter period (trigger weekly emission).
     * @param content Content contract address
     */
    function updateMinterPeriod(address content) external {
        address minter = ICore(core).contentToMinter(content);
        IMinter(minter).updatePeriod();
    }

    /**
     * @notice Claim rewards from a rewarder.
     * @param content Content contract address
     */
    function claimRewards(address content) external {
        address rewarder = ICore(core).contentToRewarder(content);
        IRewarder(rewarder).getReward(msg.sender);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    /**
     * @notice Get aggregated state for a Content contract.
     * @param content Content contract address
     * @param account User address (or address(0) to skip balance queries)
     * @return state Aggregated content state
     */
    function getContent(address content, address account) external view returns (ContentState memory state) {
        state.rewarder = IContent(content).rewarder();
        state.unit = IContent(content).unit();
        state.treasury = IContent(content).treasury();
        state.uri = IContent(content).uri();
        state.isModerated = IContent(content).isModerated();
        state.totalSupply = IContent(content).totalSupply();
        state.minInitPrice = IContent(content).minInitPrice();

        // Calculate Unit price in DONUT from LP reserves
        address auction = ICore(core).contentToAuction(content);
        if (auction != address(0)) {
            address lpToken = IAuction(auction).paymentToken();
            uint256 donutInLP = IERC20(donut).balanceOf(lpToken);
            uint256 unitInLP = IERC20(state.unit).balanceOf(lpToken);
            state.unitPrice = unitInLP == 0 ? 0 : donutInLP * 1e18 / unitInLP;
        }

        // User balances
        state.ethBalance = account == address(0) ? 0 : account.balance;
        state.wethBalance = account == address(0) ? 0 : IERC20(weth).balanceOf(account);
        state.donutBalance = account == address(0) ? 0 : IERC20(donut).balanceOf(account);
        state.unitBalance = account == address(0) ? 0 : IERC20(state.unit).balanceOf(account);

        return state;
    }

    /**
     * @notice Get state for a specific content token.
     * @param content Content contract address
     * @param tokenId Token ID
     * @return state Token state
     */
    function getToken(address content, uint256 tokenId) external view returns (TokenState memory state) {
        state.tokenId = tokenId;
        state.owner = IContent(content).ownerOf(tokenId);
        state.creator = IContent(content).id_Creator(tokenId);
        state.isApproved = IContent(content).id_IsApproved(tokenId);
        state.stake = IContent(content).id_Stake(tokenId);

        IContent.Auction memory auction = IContent(content).getAuction(tokenId);
        state.epochId = auction.epochId;
        state.initPrice = auction.initPrice;
        state.startTime = auction.startTime;
        state.price = IContent(content).getPrice(tokenId);
        state.tokenUri = IContent(content).tokenURI(tokenId);

        return state;
    }

    /**
     * @notice Get aggregated state for a Minter contract.
     * @param content Content contract address
     * @return state Minter state
     */
    function getMinter(address content) external view returns (MinterState memory state) {
        address minter = ICore(core).contentToMinter(content);

        state.activePeriod = IMinter(minter).activePeriod();
        state.weeklyEmission = IMinter(minter).weeklyEmission();
        state.currentUps = IMinter(minter).getUps();
        state.initialUps = IMinter(minter).initialUps();
        state.tailUps = IMinter(minter).tailUps();
        state.halvingPeriod = IMinter(minter).halvingPeriod();
        state.startTime = IMinter(minter).startTime();

        return state;
    }

    /**
     * @notice Get aggregated state for a Rewarder contract.
     * @param content Content contract address
     * @param account User address
     * @return state Rewarder state
     */
    function getRewarder(address content, address account) external view returns (RewarderState memory state) {
        address rewarder = ICore(core).contentToRewarder(content);
        address unitToken = IContent(content).unit();
        address quoteToken = IContent(content).quote();

        state.totalSupply = IRewarder(rewarder).totalSupply();
        state.accountBalance = account == address(0) ? 0 : IRewarder(rewarder).account_Balance(account);
        state.earnedUnit = account == address(0) ? 0 : IRewarder(rewarder).earned(account, unitToken);
        state.earnedQuote = account == address(0) ? 0 : IRewarder(rewarder).earned(account, quoteToken);
        state.leftUnit = IRewarder(rewarder).left(unitToken);
        state.leftQuote = IRewarder(rewarder).left(quoteToken);

        return state;
    }

    /**
     * @notice Get aggregated state for an Auction contract.
     * @param content Content contract address
     * @param account User address (or address(0) to skip balance queries)
     * @return state Auction state
     */
    function getAuction(address content, address account) external view returns (AuctionState memory state) {
        address auction = ICore(core).contentToAuction(content);

        state.epochId = IAuction(auction).epochId();
        state.initPrice = IAuction(auction).initPrice();
        state.startTime = IAuction(auction).startTime();
        state.paymentToken = IAuction(auction).paymentToken();
        state.price = IAuction(auction).getPrice();

        // LP price in DONUT = (DONUT in LP * 2) / LP total supply
        uint256 lpTotalSupply = IERC20(state.paymentToken).totalSupply();
        state.paymentTokenPrice =
            lpTotalSupply == 0 ? 0 : IERC20(donut).balanceOf(state.paymentToken) * 2e18 / lpTotalSupply;

        state.wethAccumulated = IERC20(weth).balanceOf(auction);
        state.wethBalance = account == address(0) ? 0 : IERC20(weth).balanceOf(account);
        state.donutBalance = account == address(0) ? 0 : IERC20(donut).balanceOf(account);
        state.paymentTokenBalance = account == address(0) ? 0 : IERC20(state.paymentToken).balanceOf(account);

        return state;
    }
}
