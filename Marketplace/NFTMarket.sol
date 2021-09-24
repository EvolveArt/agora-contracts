// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract NFTMarket is ReentrancyGuard, Ownable, IERC721Receiver {
  using Counters for Counters.Counter;
  Counters.Counter private _itemIds;
  Counters.Counter private _itemsSold;
  
  // PLATFORM ROYALTIES
  uint256 private MAX_SALE_FEE = 250;
  uint256 public saleFee = 250;
  
  uint256 private MAX_CREATOR_FEE = 1000;
  
  mapping (address => bool) private contractsAuthorized;
  
  // NFT COLLECTION MAPPINGS 
  // address = collection contract
  
  mapping (address => uint256) private contractVolume;
  
  mapping (address => uint256) private creatorFee;
  
  mapping (address => address payable) private creatorAddress;
  
  //////////////////////////// END
  
  mapping (address => uint256) private creatorRoyalties;
  
  uint256 totalFees = 0;

  struct MarketItem {
    uint itemId;
    address nftContract;
    uint256 tokenId;
    address payable seller;
    address payable owner;
    uint256 price;
    bool sold;
  }

  mapping(uint256 => MarketItem) private idToMarketItem;

  event MarketItemCreated (
    uint indexed itemId,
    address indexed nftContract,
    uint256 indexed tokenId,
    address seller,
    address owner,
    uint256 price,
    bool sold
  );
  
  event MarketItemSale (
      uint indexed itemId,
      address indexed nftContract,
      uint256 indexed tokenId,
      address seller,
      address newOwner,
      uint256 price
      );
      
  event MarketItemDelist(
      uint indexed itemId,
      address indexed nftContract,
      address seller
      );
      
  event WithdrawRoyalties(
      address indexed nftContract,
      address creator,
      uint royalties
      );
  
  modifier isAuthorized(address _nftContract) {
      require(contractsAuthorized[_nftContract]);
      _;
  }
  
  function setSaleFee(uint256 _fee) public onlyOwner {
      require(_fee <= MAX_SALE_FEE, "Fee can't be greater than MAX_SALE_FEE");
      saleFee = _fee;
  }
  
  function getNumberItemsSold() public view returns (uint256) {
      return _itemsSold.current();
  }
  
  function getContractVolume(address _nftContract) public view returns (uint256) {
      return contractVolume[_nftContract];
  }
  
  function getCreatorFee(address _nftContract) public view returns (uint256) {
      return creatorFee[_nftContract];
  }
  
  function addCollection(address _nftContract, uint256 _creatorFee, address _creatorAddress) public onlyOwner {
      contractsAuthorized[_nftContract] = true;
      creatorFee[_nftContract] = _creatorFee;
      creatorAddress[_nftContract] = payable(_creatorAddress);
  }
  
  function isContractAuthorized(address _nftContract) public view returns (bool) {
      return contractsAuthorized[_nftContract];
  }
  
  function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }


  /* LISTING FUNCTION */
  function createMarketItem(
    address nftContract,
    uint256 tokenId,
    uint256 price
  ) public payable nonReentrant isAuthorized(nftContract) {
    require(price > 0, "Price must be at least 1 wei");

    _itemIds.increment();
    uint256 itemId = _itemIds.current();
  
    idToMarketItem[itemId] =  MarketItem(
      itemId,
      nftContract,
      tokenId,
      payable(msg.sender),
      payable(address(0)), // SET OWNER TO 0x0
      price,
      false // NOT SOLD
    );

    IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

    emit MarketItemCreated(
      itemId,
      nftContract,
      tokenId,
      msg.sender,
      address(0),
      price,
      false
    );
  }

  /* BUY ITEM */
  function createMarketSale(
    address nftContract,
    uint256 itemId
    ) public payable nonReentrant isAuthorized(nftContract) {
    uint price = idToMarketItem[itemId].price;
    uint tokenId = idToMarketItem[itemId].tokenId;
    require(msg.value == price, "Please submit the asking price in order to complete the purchase");
    require(idToMarketItem[itemId].seller != msg.sender, "Can't buy your own NFT");
    require(idToMarketItem[itemId].sold == false, "Item already sold");

    // AGORA FEES
    uint256 _fee = price * saleFee / 10000;
    totalFees += _fee;
    // CREATOR FEES
    uint256 _creatorFee = price * creatorFee[nftContract] / 10000;
    creatorRoyalties[creatorAddress[nftContract]] += _creatorFee;
    // PAY THE REST TO THE SELLER
    (bool success, ) = idToMarketItem[itemId].seller.call{value : (price - (_fee + _creatorFee))}("");
    require(success, "Pay Seller Failed");
    // UPDATE THE VOLUME OF THE COLLECTION
    contractVolume[nftContract] += msg.value;
    // TRANSFER THE NFT TO THE BUYER
    IERC721(nftContract).safeTransferFrom(address(this), msg.sender, tokenId);
    // SET THE OWNER OF THE ITEM TO BE THE BUYER
    idToMarketItem[itemId].owner = payable(msg.sender);
    // SET THE ITEM TO BE SOLD
    idToMarketItem[itemId].sold = true;
    // INCREASE THE NUMBER OF ITEMS SOLD
    _itemsSold.increment();
    
    emit MarketItemSale(itemId, nftContract, tokenId, idToMarketItem[itemId].seller, msg.sender, price);
  }

  function fetchMarketItem(uint itemId) public view returns (MarketItem memory) {
    MarketItem memory item = idToMarketItem[itemId];
    return item;
  }
  
  function delistMarketItem(address _nftContract, uint256 _itemId) external nonReentrant isAuthorized(_nftContract) {
      uint tokenId = idToMarketItem[_itemId].tokenId;
      require(idToMarketItem[_itemId].seller == msg.sender, "Only the seller can delist.");
      // SEND BACK THE NFT TO THE SELLER
      IERC721(_nftContract).safeTransferFrom(address(this), msg.sender, tokenId);
      idToMarketItem[_itemId].owner = payable(msg.sender);
      
      emit MarketItemDelist(_itemId, _nftContract, msg.sender);
  }

  function fetchMarketItems() public view returns (MarketItem[] memory) {
    uint itemCount = _itemIds.current();
    uint unsoldItemCount = _itemIds.current() - _itemsSold.current();
    uint currentIndex = 0;

    MarketItem[] memory items = new MarketItem[](unsoldItemCount);
    for (uint i = 0; i < itemCount; i++) {
      if (idToMarketItem[i + 1].owner == address(0)) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  function fetchAllMarketItems() public view returns (MarketItem[] memory) {
    uint itemCount = _itemIds.current();
    uint currentIndex = 0;

    MarketItem[] memory items = new MarketItem[](itemCount);
    for (uint i = 0; i < itemCount; i++) {
      if (idToMarketItem[i + 1].owner != idToMarketItem[i + 1].seller) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  function fetchMarketItems(address _nftContract) public view returns (MarketItem[] memory) {
    uint itemCount = _itemIds.current();
    uint unsoldItemCount = _itemIds.current() - _itemsSold.current();
    uint currentIndex = 0;

    MarketItem[] memory items = new MarketItem[](unsoldItemCount);
    for (uint i = 0; i < itemCount; i++) {
      if (idToMarketItem[i + 1].owner == address(0) && idToMarketItem[i+1].nftContract == _nftContract) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  /* Returns NFTs a user has sold */
  function fetchMyNFTsSold() public view returns (MarketItem[] memory) {
    uint totalItemCount = _itemIds.current();
    uint itemCount = 0;
    uint currentIndex = 0;

    for (uint i = 0; i < totalItemCount; i++) {
      if (idToMarketItem[i + 1].seller == msg.sender && idToMarketItem[i + 1].owner != msg.sender && idToMarketItem[i + 1].owner != address(0)) {
        itemCount += 1;
      }
    }

    MarketItem[] memory items = new MarketItem[](itemCount);
    for (uint i = 0; i < totalItemCount; i++) {
        // SELLER IS CALLER + OWNER IS NOT SELLER + OWNER IS NOT 0x0 (NFT SOLD)
      if (idToMarketItem[i + 1].seller == msg.sender && idToMarketItem[i + 1].owner != msg.sender && idToMarketItem[i + 1].owner != address(0)) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  /* Returns NFTs a user has purchase */
  function fetchMyNFTs() public view returns (MarketItem[] memory) {
    uint totalItemCount = _itemIds.current();
    uint itemCount = 0;
    uint currentIndex = 0;

    for (uint i = 0; i < totalItemCount; i++) {
      if (idToMarketItem[i + 1].owner == msg.sender) {
        itemCount += 1;
      }
    }

    MarketItem[] memory items = new MarketItem[](itemCount);
    for (uint i = 0; i < totalItemCount; i++) {
      if (idToMarketItem[i + 1].owner == msg.sender) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  /* Return NFTs a user has on sale */
  function fetchMyNFTsOnSale() public view returns (MarketItem[] memory) {
    uint totalItemCount = _itemIds.current();
    uint itemCount = 0;
    uint currentIndex = 0;

    for (uint i = 0; i < totalItemCount; i++) {
      if (idToMarketItem[i + 1].owner == address(0) && idToMarketItem[i+1].seller == msg.sender) {
        itemCount += 1;
      }
    }

    MarketItem[] memory items = new MarketItem[](itemCount);
    for (uint i = 0; i < totalItemCount; i++) {
      if (idToMarketItem[i + 1].owner == address(0) && idToMarketItem[i+1].seller == msg.sender) {
        uint currentId = idToMarketItem[i + 1].itemId;
        MarketItem storage currentItem = idToMarketItem[currentId];
        items[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
   
    return items;
  }
  
  function withdrawRoyalties(address _nftContract) public payable {
      require(msg.sender == creatorAddress[_nftContract], "Only the creator of the collection can withdraw the royalties.");
      (bool success, ) = creatorAddress[_nftContract].call{ value : creatorRoyalties[creatorAddress[_nftContract]] }("");
      require(success, "WithdrawRoyalties Failed");
      
      emit WithdrawRoyalties(_nftContract, msg.sender, creatorRoyalties[creatorAddress[_nftContract]]);
  }
  
  
  function withdrawFees() public payable onlyOwner {
        (bool success, ) = payable(msg.sender).call{value:totalFees}("");
        require(success);
    }
}