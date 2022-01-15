// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


contract BCAMarket is Context, Ownable, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    // struct OrderHistory {
    //     uint256 order_uuid;
    // }

    struct TransactionInput {
        uint256 transactionId;//order_uuid
        address seller;
        address nftAddress;
        uint256 tokenId;
        address erc20Address;
        uint256 price;
        uint8 status;
        // uint256 salt; //
    }

    struct Detail {
        address seller;
        address buyer;
        address nftAddress;
        uint256 tokenId;
        address erc20Address;
        uint256 price;
        uint256 timeStamp;
        uint8 status;
    }

    // BNB or ETH
    // TODO: add USDT/USDC
    address private constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint32 public constant BASE = 1e6;
    uint32 public constant DEFAULT_FEE_PCT = 3 * 1e4;   // 3%, 30000/BASE = 0.03

    //use enum?
    uint8 private constant STATUS_NOT_EXIST = 0;//default, order not exist
    uint8 private constant STATUS_OPEN = 1;
    uint8 private constant STATUS_CANCELED = 2;
    uint8 private constant STATUS_FINISHED = 3;

    bool public _isMarketPaused = false; // default market open
    uint32 public _fee_pct = DEFAULT_FEE_PCT; //pct: percent
    // signer
    address private _validator;
    address private _cfo;

    // nftAddress is added to the market or not
    mapping(address => bool) private _nftAvailable;
    // erc20Address is available or not
    mapping(address => bool) private _erc20Available;
    // transactionId => Detail
    mapping(uint256 => Detail) private _historyDetail;

    event BuyNFT(TransactionInput tx_input);
    event CancelOrder(uint256 indexed transactionId, address indexed nftAddress, uint256 tokenId, address seller, address erc20Address, uint256 salePrice);

    constructor (address cfo, address validator) {
        _erc20Available[NATIVE_ADDRESS] = true;
        _cfo = cfo;
        _validator = validator;
    }

    modifier marketNotPaused() {
        require(!_isMarketPaused, "market is paused now, try later");
        _;
    }

    function setCFOAddress(address _newCFO) public onlyOwner {
        require(_newCFO != address(0));
        _cfo = _newCFO;
    }

    function getCFOAddress() public view returns (address){
        return _cfo;
    }

    function pauseMarket(bool is_pause) external onlyOwner {
        _isMarketPaused = is_pause;
    }

    function setFee(uint32 newFee) external onlyOwner {
        _fee_pct = newFee;
    }

    function setValidator(address newValidator) external onlyOwner {
        _validator = newValidator;
    }

    function setAvailableNft(address nftAddress, bool newState) external onlyOwner {
        _nftAvailable[nftAddress] = newState;
    }

    function setAvailableERC20(address erc20Address, bool newState) external onlyOwner {
        _erc20Available[erc20Address] = newState;
    }

    //No need withdrawBNB?
    function withdrawBNB(address payable to) external onlyOwner {
        uint256 balance = address(this).balance;
        to.transfer(balance);
    }

    //No need withdrawERC20?
    function withdrawERC20(address erc20Address, address to) external onlyOwner {
        IERC20 erc20Token = IERC20(erc20Address);
        uint256 balance = erc20Token.balanceOf(address(this));
        erc20Token.safeTransfer(to, balance);
    }

    // recover
    function withdrawERC721(address nftAddress, uint256 tokenId, address to) external onlyOwner {
        IERC721 nft = IERC721(nftAddress);
        require(nft.ownerOf(tokenId) == address(this), "this contract is not the owner");
        nft.safeTransferFrom(address(this), to, tokenId);
    }

    //TODO: add ERC721 support

    function isNftAvailable(address nftAddress) public view returns (bool) {
        return _nftAvailable[nftAddress];
    }

    function isERC20Support(address erc20Address) public view returns (bool) {
        return _erc20Available[erc20Address];
    }

    function getHistoryDetail(uint256 transactionId) public view returns (Detail memory) {
        //if transactionId not exist in _historyDetail, should return Detail with all zero
        //WARNING: caller should check the result
        return _historyDetail[transactionId];
    }

    function isOrderOpen(uint256 txid) public view returns (bool) {
        return _historyDetail[txid].status == STATUS_OPEN;
    }

    function isOrderFinal(uint8 status) public pure returns (bool) {
        return status == STATUS_CANCELED || status == STATUS_FINISHED;
    }

    function isOrderBuyable(uint256 txid, uint8 input_kind) public view returns (bool) {
        //Not exist or not finished
        uint8 status =_historyDetail[txid].status;
        return input_kind == STATUS_OPEN && 
            (status == STATUS_NOT_EXIST || !isOrderFinal(status));
    }

    // if this NFT traded by ERC20 token, buyer must be approve to this contract
    // Seller must "setApprovalForAll" this contract as the operator
    function buyNFT(TransactionInput calldata input,
                    bytes calldata sellerSig,
                    bytes calldata validatorSig) public payable nonReentrant marketNotPaused {
        
        uint256 txid = input.transactionId;
        //TODO: check other input params
        require(isOrderBuyable(txid, input.status), "Invalid: transactionId is not buyable");

        require(_nftAvailable[input.nftAddress], "Invalid: this NFT address is not available");
        require(_erc20Available[input.erc20Address], "Invalid: this erc20 token is not available");
        IERC721 nft = IERC721(input.nftAddress);
        address currentOwner = nft.ownerOf(input.tokenId);
        require(_msgSender() != currentOwner , "owner can not be the buyer");

        // check validator signature
        bytes32 validatorHash = keccak256(abi.encodePacked(txid, input.seller, input.nftAddress, input.tokenId, input.erc20Address, input.price));
        require(isSignatureValid(validatorSig, validatorHash, _validator), "validator signature error");
        // check seller signature
        bytes32 sellerHash = keccak256(abi.encodePacked(input.seller, input.nftAddress, input.tokenId, input.erc20Address, input.price, input.status));
        require(isSignatureValid(sellerSig, ECDSA.toEthSignedMessageHash(sellerHash), currentOwner), "seller signature error");

        _transferToken(input.price, input.erc20Address, input.seller, _msgSender());
        nft.safeTransferFrom(input.seller, _msgSender(), input.tokenId);

        _historyDetail[txid] = Detail({
            seller: input.seller,
            buyer: _msgSender(),
            nftAddress: input.nftAddress,
            tokenId: input.tokenId,
            erc20Address: input.erc20Address, 
            price: input.price, 
            timeStamp: block.timestamp, 
            status: STATUS_FINISHED
        });

        emit BuyNFT(input);// too much data
    }

    function cancelOrder(TransactionInput calldata input,
                         bytes calldata sellerSig) public nonReentrant marketNotPaused {
        require(isOrderOpen(input.transactionId), "Invalid: transactionId is not open");

        IERC721 nft = IERC721(input.nftAddress);
        address currentOwner = nft.ownerOf(input.tokenId);
        require(_msgSender() == currentOwner , "msg.sender must be the current owner");
        require(_msgSender() == input.seller , "msg.sender must be the seller");

        // check seller signature
        bytes32 sellerHash = keccak256(abi.encodePacked(input.seller, input.nftAddress, input.tokenId, input.erc20Address, input.price, input.status));
        require(isSignatureValid(sellerSig, ECDSA.toEthSignedMessageHash(sellerHash), currentOwner), "seller signature error");

        _historyDetail[input.transactionId].status = STATUS_CANCELED;
        
        emit CancelOrder(input.transactionId, input.nftAddress, input.tokenId, input.seller, input.erc20Address, input.price);
    }

    function isSignatureValid(bytes memory signature, bytes32 hashCode, address signer) public pure returns (bool) {
        address recoveredSigner = ECDSA.recover(hashCode, signature);
        return signer == recoveredSigner;
    }

    function _transferToken(uint256 totalPayment, address erc20Address, address seller, address buyer) internal {
        uint256 totalFee = totalPayment * _fee_pct / BASE;
        uint256 remaining = totalPayment - totalFee;
        if (erc20Address == NATIVE_ADDRESS) {   // BNB payment
            //BNB/ETH will pay first to contract address, pay remaining to seller, 
            //left totalFee to contract address
            require(msg.value >= totalPayment, "not enough BNB balance to buy");
            payable(seller).transfer(remaining);
        } else {     // ERC20 token payment
            IERC20 erc20Token = IERC20(erc20Address);
            require(erc20Token.balanceOf(buyer) >= totalPayment, "not enough ERC20 token balance to buy");
            erc20Token.safeTransferFrom(buyer, seller, remaining);
            erc20Token.safeTransferFrom(buyer, address(this), totalFee);
        }
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(address, address, uint256, bytes memory) public pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}