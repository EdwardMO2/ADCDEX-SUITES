// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title INFTMarketplace
/// @author ADCDEX
/// @notice Shared types, events, and errors for the NFT marketplace module.
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
}
