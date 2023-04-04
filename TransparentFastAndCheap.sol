// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract TransparentFastAndCheap {
    address public owner;
    uint256 public transactionSpeed; // in gas
    uint256 public discountPercentage;
    address public tokenAddress;
    uint256 public totalTransactions;
    mapping(uint256 => Transaction) public transactions;

    struct Transaction {
        address sender;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
    }

    constructor(uint256 _transactionSpeed, uint256 _discountPercentage, address _tokenAddress) {
        owner = msg.sender;
        transactionSpeed = _transactionSpeed;
        discountPercentage = _discountPercentage;
        tokenAddress = _tokenAddress;
    }

    function setTransactionSpeed(uint256 _transactionSpeed) external {
        require(msg.sender == owner, "TransparentFastAndCheap: only owner can call this function");
        transactionSpeed = _transactionSpeed;
    }

    function setDiscountPercentage(uint256 _discountPercentage) external {
        require(msg.sender == owner, "TransparentFastAndCheap: only owner can call this function");
        discountPercentage = _discountPercentage;
    }

    function transferWithDiscountAndSpeed(address recipient, uint256 amount) external payable {
        uint256 fee = (amount * (100 - discountPercentage)) / 100;
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount + fee);
        require(IERC20(tokenAddress).approve(owner, fee), "TransparentFastAndCheap: approve failed");
        (bool success, ) = owner.call{value: msg.value, gas: transactionSpeed}("");
        require(success, "TransparentFastAndCheap: transaction failed");
        IERC20(tokenAddress).transferFrom(address(this), recipient, amount);
        IERC20(tokenAddress).transferFrom(address(this), owner, fee);

        transactions[totalTransactions] = Transaction({
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            fee: fee,
            timestamp: block.timestamp
        });
        totalTransactions++;
    }

    function getTransaction(uint256 transactionId) external view returns (Transaction memory) {
        require(transactionId < totalTransactions, "TransparentFastAndCheap: transaction not found");
        return transactions[transactionId];
    }
}