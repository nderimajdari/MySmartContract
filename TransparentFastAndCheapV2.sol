// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TransparentFastAndCheapV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public feeBps;
    IERC20 public token;
    address public feeCollector;
    uint256 public totalTransactions;

    struct Transaction {
        address sender;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
    }

    mapping(uint256 => Transaction) public transactions;

    event TransferExecuted(uint256 indexed txId, address indexed sender, address indexed recipient, uint256 amount, uint256 fee);
    event FeeCollectorChanged(address indexed oldCollector, address indexed newCollector);
    event FeeBpsChanged(uint256 oldBps, uint256 newBps);

    constructor(address _token, address _feeCollector, uint256 _feeBps)
        Ownable(msg.sender)
    {
        require(_token != address(0), "token zero");
        require(_feeCollector != address(0), "collector zero");
        require(_feeBps <= 10000, "fee too large");

        token = IERC20(_token);
        feeCollector = _feeCollector;
        feeBps = _feeBps;
    }

    function setFeeCollector(address _collector) external onlyOwner {
        require(_collector != address(0), "collector zero");
        address old = feeCollector;
        feeCollector = _collector;
        emit FeeCollectorChanged(old, _collector);
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 10000, "fee too large");
        uint256 old = feeBps;
        feeBps = _feeBps;
        emit FeeBpsChanged(old, _feeBps);
    }

    function transferWithFee(address recipient, uint256 amount) external nonReentrant {
        require(recipient != address(0), "recipient zero");
        require(amount > 0, "amount zero");

        uint256 fee = (amount * feeBps) / 10000;
        uint256 total = amount + fee;

        token.safeTransferFrom(msg.sender, address(this), total);
        if (amount > 0) token.safeTransfer(recipient, amount);
        if (fee > 0) token.safeTransfer(feeCollector, fee);

        transactions[totalTransactions] = Transaction({
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            fee: fee,
            timestamp: block.timestamp
        });

        emit TransferExecuted(totalTransactions, msg.sender, recipient, amount, fee);
        totalTransactions++;
    }

    function rescueERC20(address _token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to zero");
        IERC20(_token).safeTransfer(to, amount);
    }

    function getTransaction(uint256 txId) external view returns (Transaction memory) {
        require(txId < totalTransactions, "tx not found");
        return transactions[txId];
    }
}
