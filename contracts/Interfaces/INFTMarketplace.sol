// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title INFTMarketplace
/// @author ADCDEX
/// @notice Shared types, events, errors, and function signatures for the NFT marketplace module.
interface INFTMarketplace {
    // =========================================================================
    //                              STRUCTS
    // =========================================================================

    /// @notice A fixed-price NFT listing.
    /// @param listingId    Unique listing identifier.
    /// @param seller       Address that listed the NFT.
    /// @param nftContract  ERC-721 contract address.
    /// @param tokenId      Token ID within `nftContract`.
    /// @param paymentToken ERC-20 token accepted for payment (address(0) = native).
    /// @param price        Fixed sale price in `paymentToken` units.
    /// @param active       Whether the listing can still be purchased.
    struct Listing {
        uint256 listingId;
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 price;
        bool active;
    }

    /// @notice An English-style auction for an NFT.
    /// @param auctionId     Unique auction identifier.
    /// @param seller        Address that created the auction.
    /// @param nftContract   ERC-721 contract address.
    /// @param tokenId       Token ID within `nftContract`.
    /// @param paymentToken  ERC-20 token accepted for bids.
    /// @param startPrice    Minimum opening bid.
    /// @param currentBid    Highest bid received so far.
    /// @param currentBidder Address that placed the current highest bid.
    /// @param endTime       Unix timestamp after which no new bids are accepted.
    /// @param settled       Whether the auction has been finalised.
    struct Auction {
        uint256 auctionId;
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 startPrice;
        uint256 currentBid;
        address currentBidder;
        uint256 endTime;
        bool settled;
    }

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    /// @notice Emitted when an NFT is listed for a fixed price.
    event NFTListed(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 price
    );

    /// @notice Emitted when a fixed-price listing is purchased.
    event NFTSold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 price
    );

    /// @notice Emitted when a seller cancels their listing.
    event ListingCancelled(uint256 indexed listingId, address indexed seller);

    /// @notice Emitted when an auction is created.
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endTime
    );

    /// @notice Emitted when a new bid is placed on an auction.
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bidAmount
    );

    /// @notice Emitted when an auction is settled.
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 finalPrice
    );

    /// @notice Emitted when a royalty payment is made.
    event RoyaltyPaid(
        address indexed nftContract,
        address indexed recipient,
        uint256 amount
    );

    // =========================================================================
    //                          CUSTOM ERRORS
    // =========================================================================

    /// @notice Listing ID does not exist or is no longer active.
    error ListingNotFound(uint256 listingId);

    /// @notice Auction ID does not exist.
    error AuctionNotFound(uint256 auctionId);

    /// @notice Payment amount is below the required price or minimum bid.
    error InsufficientPayment(uint256 required, uint256 provided);

    /// @notice Action requires the auction to have ended.
    error AuctionNotEnded(uint256 auctionId);

    /// @notice Auction has already been settled.
    error AuctionAlreadyEnded(uint256 auctionId);

    /// @notice Caller is not the seller / listing owner.
    error NotSeller(uint256 id, address caller);

    /// @notice Bid amount must exceed the current highest bid.
    error BidTooLow(uint256 auctionId, uint256 currentBid, uint256 newBid);

    // =========================================================================
    //                       LISTING FUNCTIONS
    // =========================================================================

    /// @notice Create a fixed-price listing for an NFT.
    /// @dev The seller must have approved this contract to transfer the NFT.
    ///      Emits {NFTListed}.
    /// @param nftContract  Address of the ERC-721 contract.
    /// @param tokenId      Token ID to list.
    /// @param paymentToken ERC-20 token for payment (address(0) for native ETH).
    /// @param price        Sale price in `paymentToken` units.
    /// @return listingId   The unique identifier of the new listing.
    function createListing(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 price
    ) external returns (uint256 listingId);

    /// @notice Cancel an active listing and return the NFT to the seller.
    /// @dev Can only be called by the original seller. Emits {ListingCancelled}.
    /// @param listingId Listing to cancel.
    function cancelListing(uint256 listingId) external;

    /// @notice Purchase an NFT from a fixed-price listing.
    /// @dev Transfers payment from buyer to seller and NFT to buyer.
    ///      Emits {NFTSold}. May emit {RoyaltyPaid} if royalties apply.
    /// @param listingId Listing to purchase.
    function buyNFT(uint256 listingId) external payable;

    // =========================================================================
    //                       AUCTION FUNCTIONS
    // =========================================================================

    /// @notice Create an English-style auction for an NFT.
    /// @dev The seller must have approved this contract to transfer the NFT.
    ///      Emits {AuctionCreated}.
    /// @param nftContract  Address of the ERC-721 contract.
    /// @param tokenId      Token ID to auction.
    /// @param paymentToken ERC-20 token for bids (address(0) for native ETH).
    /// @param startPrice   Minimum opening bid.
    /// @param duration     Auction duration in seconds from creation time.
    /// @return auctionId   The unique identifier of the new auction.
    function createAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 startPrice,
        uint256 duration
    ) external returns (uint256 auctionId);

    /// @notice Place a bid on an active auction.
    /// @dev Bid must exceed current highest bid. Previous bidder is refunded.
    ///      Emits {BidPlaced}.
    /// @param auctionId Auction to bid on.
    /// @param bidAmount Amount to bid (in `paymentToken` units). For native
    ///                  ETH auctions, this should match `msg.value`.
    function placeBid(uint256 auctionId, uint256 bidAmount) external payable;

    /// @notice Settle a completed auction — transfer NFT to winner, payment to seller.
    /// @dev Can only be called after the auction's `endTime` has passed.
    ///      Emits {AuctionSettled}. May emit {RoyaltyPaid} if royalties apply.
    /// @param auctionId Auction to settle.
    function settleAuction(uint256 auctionId) external;

    // =========================================================================
    //                         VIEW FUNCTIONS
    // =========================================================================

    /// @notice Get details of a specific listing.
    /// @param listingId Listing to query.
    /// @return The full Listing struct.
    function getListing(uint256 listingId) external view returns (Listing memory);

    /// @notice Get details of a specific auction.
    /// @param auctionId Auction to query.
    /// @return The full Auction struct.
    function getAuction(uint256 auctionId) external view returns (Auction memory);
}
