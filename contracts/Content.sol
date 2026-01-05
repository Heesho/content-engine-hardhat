// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC721, ERC721Enumerable, IERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRewarderFactory} from "./interfaces/IRewarderFactory.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";
import {ICore} from "./interfaces/ICore.sol";

/**
 * @title Content
 * @author heesho
 * @notice NFT collection where collectors can "steal" content by paying a dutch auction price.
 *         The purchase price determines the owner's stake in the Rewarder, earning them Unit rewards.
 * @dev Each content has a dutch auction that resets after collection with a 2x price multiplier.
 *      Fees: 80% to previous owner, 15% to treasury, 2% to creator, 2% to team, 1% to protocol.
 */
contract Content is ERC721, ERC721Enumerable, ERC721URIStorage, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*----------  CONSTANTS  --------------------------------------------*/

    uint256 public constant PREVIOUS_OWNER_FEE = 8_000; // 80% to previous owner
    uint256 public constant TREASURY_FEE = 1_500; // 15% to treasury (auction)
    uint256 public constant CREATOR_FEE = 200; // 2% to creator
    uint256 public constant TEAM_FEE = 200; // 2% to team
    uint256 public constant PROTOCOL_FEE = 100; // 1% to protocol
    uint256 public constant DIVISOR = 10_000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant EPOCH_PERIOD = 30 days;
    uint256 public constant PRICE_MULTIPLIER = 2e18;
    uint256 public constant ABS_MAX_INIT_PRICE = type(uint192).max;

    /*----------  IMMUTABLES  -------------------------------------------*/

    address public immutable rewarder;
    address public immutable unit;
    address public immutable quote;
    address public immutable core;
    uint256 public immutable minInitPrice;

    /*----------  STATE  ------------------------------------------------*/

    string public uri;
    address public treasury;
    address public team;

    bool public isModerated;
    mapping(address => bool) public account_IsModerator;

    uint256 public nextTokenId;

    mapping(uint256 => uint256) public id_Stake;
    mapping(uint256 => address) public id_Creator;
    mapping(uint256 => bool) public id_IsApproved;
    mapping(uint256 => Auction) public id_Auction;

    /*----------  STRUCTS  ----------------------------------------------*/

    struct Auction {
        uint256 epochId;
        uint256 initPrice;
        uint256 startTime;
    }

    /*----------  ERRORS  -----------------------------------------------*/

    error Content__ZeroTo();
    error Content__ZeroLengthUri();
    error Content__ZeroMinPrice();
    error Content__Expired();
    error Content__EpochIdMismatch();
    error Content__MaxPriceExceeded();
    error Content__TransferDisabled();
    error Content__NotApproved();
    error Content__AlreadyApproved();
    error Content__NotModerator();
    error Content__InvalidTreasury();
    error Content__InvalidTeam();
    error Content__InvalidCore();
    error Content__InvalidUnit();
    error Content__InvalidQuote();

    /*----------  EVENTS  -----------------------------------------------*/

    event Content__Created(address indexed who, address indexed to, uint256 indexed tokenId, string uri);
    event Content__Collected(
        address indexed who,
        address indexed to,
        uint256 indexed tokenId,
        uint256 epochId,
        uint256 price
    );
    event Content__Distributed(uint256 quoteAmount, uint256 unitAmount);
    event Content__UriSet(string uri);
    event Content__TreasurySet(address indexed treasury);
    event Content__TeamSet(address indexed team);
    event Content__IsModeratedSet(bool isModerated);
    event Content__ModeratorsSet(address indexed account, bool isModerator);
    event Content__Approved(address indexed moderator, uint256 indexed tokenId);
    event Content__RewardAdded(address indexed rewardToken);

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    /**
     * @notice Deploy a new Content NFT collection.
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _uri Metadata URI
     * @param _unit Unit token address
     * @param _quote Quote token (WETH) address
     * @param _treasury Treasury (Auction) address for fee collection
     * @param _team Team address for fee collection
     * @param _core Core contract address
     * @param _rewarderFactory RewarderFactory address
     * @param _minInitPrice Minimum starting auction price
     * @param _isModerated Whether content requires moderator approval
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _uri,
        address _unit,
        address _quote,
        address _treasury,
        address _team,
        address _core,
        address _rewarderFactory,
        uint256 _minInitPrice,
        bool _isModerated
    ) ERC721(_name, _symbol) {
        if (_minInitPrice == 0) revert Content__ZeroMinPrice();
        if (bytes(_uri).length == 0) revert Content__ZeroLengthUri();
        if (_unit == address(0)) revert Content__InvalidUnit();
        if (_quote == address(0)) revert Content__InvalidQuote();
        if (_treasury == address(0)) revert Content__InvalidTreasury();
        if (_team == address(0)) revert Content__InvalidTeam();
        if (_core == address(0)) revert Content__InvalidCore();

        uri = _uri;
        unit = _unit;
        quote = _quote;
        treasury = _treasury;
        team = _team;
        core = _core;
        minInitPrice = _minInitPrice;
        isModerated = _isModerated;

        rewarder = IRewarderFactory(_rewarderFactory).deploy(address(this));
        IRewarder(rewarder).addReward(_quote);
        IRewarder(rewarder).addReward(_unit);
    }

    /*----------  EXTERNAL FUNCTIONS  -----------------------------------*/

    /**
     * @notice Create new content NFT.
     * @param to Recipient address (becomes creator)
     * @param tokenUri Metadata URI for the content
     * @return tokenId The ID of the created token
     */
    function create(address to, string memory tokenUri) external nonReentrant returns (uint256 tokenId) {
        if (to == address(0)) revert Content__ZeroTo();
        if (bytes(tokenUri).length == 0) revert Content__ZeroLengthUri();

        tokenId = ++nextTokenId;
        id_Creator[tokenId] = to;
        if (!isModerated) id_IsApproved[tokenId] = true;

        id_Auction[tokenId] = Auction({
            epochId: 0,
            initPrice: minInitPrice,
            startTime: block.timestamp
        });

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenUri);

        emit Content__Created(msg.sender, to, tokenId, tokenUri);
    }

    /**
     * @notice Collect (steal) content by paying the dutch auction price.
     * @param to Address to receive the content
     * @param tokenId Token ID to collect
     * @param epochId Expected epoch ID (frontrun protection)
     * @param deadline Transaction deadline
     * @param maxPrice Maximum price willing to pay (slippage protection)
     * @return price Actual price paid
     */
    function collect(
        address to,
        uint256 tokenId,
        uint256 epochId,
        uint256 deadline,
        uint256 maxPrice
    ) external nonReentrant returns (uint256 price) {
        if (to == address(0)) revert Content__ZeroTo();
        if (!id_IsApproved[tokenId]) revert Content__NotApproved();
        if (block.timestamp > deadline) revert Content__Expired();

        Auction memory auction = id_Auction[tokenId];
        if (epochId != auction.epochId) revert Content__EpochIdMismatch();

        price = getPriceFromCache(auction);
        if (price > maxPrice) revert Content__MaxPriceExceeded();

        address creator = id_Creator[tokenId];
        address prevOwner = ownerOf(tokenId);
        uint256 prevStake = id_Stake[tokenId];

        // Calculate next epoch's starting price
        uint256 newInitPrice = price * PRICE_MULTIPLIER / PRECISION;
        if (newInitPrice > ABS_MAX_INIT_PRICE) {
            newInitPrice = ABS_MAX_INIT_PRICE;
        } else if (newInitPrice < minInitPrice) {
            newInitPrice = minInitPrice;
        }

        // Update auction state
        unchecked {
            auction.epochId++;
        }
        auction.initPrice = newInitPrice;
        auction.startTime = block.timestamp;

        id_Auction[tokenId] = auction;
        id_Stake[tokenId] = price;

        // Transfer NFT
        _transfer(prevOwner, to, tokenId);

        // Handle payments
        if (price > 0) {
            IERC20(quote).safeTransferFrom(msg.sender, address(this), price);

            // Calculate fees
            address protocolFeeAddr = ICore(core).protocolFeeAddress();
            uint256 prevOwnerAmount = price * PREVIOUS_OWNER_FEE / DIVISOR;
            uint256 creatorAmount = price * CREATOR_FEE / DIVISOR;
            uint256 teamAmount = price * TEAM_FEE / DIVISOR;
            uint256 protocolAmount = protocolFeeAddr != address(0) ? price * PROTOCOL_FEE / DIVISOR : 0;
            uint256 treasuryAmount = price - prevOwnerAmount - creatorAmount - teamAmount - protocolAmount;

            // Distribute fees
            IERC20(quote).safeTransfer(prevOwner, prevOwnerAmount);
            IERC20(quote).safeTransfer(creator, creatorAmount);
            IERC20(quote).safeTransfer(team, teamAmount);
            IERC20(quote).safeTransfer(treasury, treasuryAmount);

            if (protocolAmount > 0) {
                IERC20(quote).safeTransfer(protocolFeeAddr, protocolAmount);
            }

            // Update stake in rewarder
            IRewarder(rewarder).deposit(to, price);
        }

        // Withdraw previous owner's stake
        if (prevStake > 0) {
            IRewarder(rewarder).withdraw(prevOwner, prevStake);
        }

        emit Content__Collected(msg.sender, to, tokenId, epochId, price);

        return price;
    }

    /**
     * @notice Distribute any accumulated tokens to the rewarder.
     * @dev Can be called by anyone to distribute accumulated rewards.
     */
    function distribute() external {
        uint256 duration = IRewarder(rewarder).DURATION();

        uint256 quoteDistributed = 0;
        uint256 balanceQuote = IERC20(quote).balanceOf(address(this));
        uint256 leftQuote = IRewarder(rewarder).left(quote);
        if (balanceQuote > leftQuote && balanceQuote > duration) {
            IERC20(quote).safeApprove(rewarder, 0);
            IERC20(quote).safeApprove(rewarder, balanceQuote);
            IRewarder(rewarder).notifyRewardAmount(quote, balanceQuote);
            quoteDistributed = balanceQuote;
        }

        uint256 unitDistributed = 0;
        uint256 balanceUnit = IERC20(unit).balanceOf(address(this));
        uint256 leftUnit = IRewarder(rewarder).left(unit);
        if (balanceUnit > leftUnit && balanceUnit > duration) {
            IERC20(unit).safeApprove(rewarder, 0);
            IERC20(unit).safeApprove(rewarder, balanceUnit);
            IRewarder(rewarder).notifyRewardAmount(unit, balanceUnit);
            unitDistributed = balanceUnit;
        }

        if (quoteDistributed > 0 || unitDistributed > 0) {
            emit Content__Distributed(quoteDistributed, unitDistributed);
        }
    }

    /*----------  DISABLED TRANSFERS  -----------------------------------*/

    function approve(address, uint256) public virtual override(ERC721, IERC721) {
        revert Content__TransferDisabled();
    }

    function setApprovalForAll(address, bool) public virtual override(ERC721, IERC721) {
        revert Content__TransferDisabled();
    }

    function transferFrom(address, address, uint256) public virtual override(ERC721, IERC721) {
        revert Content__TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256) public virtual override(ERC721, IERC721) {
        revert Content__TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public virtual override(ERC721, IERC721) {
        revert Content__TransferDisabled();
    }

    /*----------  RESTRICTED FUNCTIONS  ---------------------------------*/

    /**
     * @notice Update the metadata URI.
     * @param _uri New metadata URI
     */
    function setUri(string memory _uri) external onlyOwner {
        uri = _uri;
        emit Content__UriSet(_uri);
    }

    /**
     * @notice Update the treasury address.
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Content__InvalidTreasury();
        treasury = _treasury;
        emit Content__TreasurySet(_treasury);
    }

    /**
     * @notice Update the team address.
     * @param _team New team address
     */
    function setTeam(address _team) external onlyOwner {
        if (_team == address(0)) revert Content__InvalidTeam();
        team = _team;
        emit Content__TeamSet(_team);
    }

    /**
     * @notice Toggle moderation mode.
     * @param _isModerated Whether to enable moderation
     */
    function setIsModerated(bool _isModerated) external onlyOwner {
        isModerated = _isModerated;
        emit Content__IsModeratedSet(_isModerated);
    }

    /**
     * @notice Set moderator status for accounts.
     * @param accounts Array of accounts to update
     * @param isModerator Whether to grant moderator status
     */
    function setModerators(address[] calldata accounts, bool isModerator) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            account_IsModerator[accounts[i]] = isModerator;
            emit Content__ModeratorsSet(accounts[i], isModerator);
        }
    }

    /**
     * @notice Approve content for collection (moderators only).
     * @param tokenIds Array of token IDs to approve
     */
    function approveContents(uint256[] calldata tokenIds) external {
        if (msg.sender != owner() && !account_IsModerator[msg.sender]) revert Content__NotModerator();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (id_IsApproved[tokenIds[i]]) revert Content__AlreadyApproved();
            ownerOf(tokenIds[i]); // Reverts if token doesn't exist
            id_IsApproved[tokenIds[i]] = true;
            emit Content__Approved(msg.sender, tokenIds[i]);
        }
    }

    /**
     * @notice Add a new reward token to the rewarder.
     * @param rewardToken Reward token address
     */
    function addReward(address rewardToken) external onlyOwner {
        IRewarder(rewarder).addReward(rewardToken);
        emit Content__RewardAdded(rewardToken);
    }

    /*----------  INTERNAL OVERRIDES  -----------------------------------*/

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    /**
     * @notice Get the current price for a token from cached auction data.
     * @param auction Auction struct
     * @return Current dutch auction price
     */
    function getPriceFromCache(Auction memory auction) public view returns (uint256) {
        uint256 timePassed = block.timestamp - auction.startTime;
        if (timePassed > EPOCH_PERIOD) return 0;
        return auction.initPrice - auction.initPrice * timePassed / EPOCH_PERIOD;
    }

    /**
     * @notice Get the auction data for a token.
     * @param tokenId Token ID
     * @return Auction struct
     */
    function getAuction(uint256 tokenId) external view returns (Auction memory) {
        return id_Auction[tokenId];
    }

    /**
     * @notice Get the current price for a token.
     * @param tokenId Token ID
     * @return Current dutch auction price
     */
    function getPrice(uint256 tokenId) external view returns (uint256) {
        return getPriceFromCache(id_Auction[tokenId]);
    }
}
