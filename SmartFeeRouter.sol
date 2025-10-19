// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SmartFeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;

    struct FeeOption {
        address collector;
        uint256 feeBps;
        bool deductFromRecipient;
        bool active;
    }

    FeeOption[] public feeOptions;

    event FeeOptionAdded(uint256 indexed idx, address collector, uint256 feeBps, bool deductFromRecipient);
    event FeeOptionUpdated(uint256 indexed idx, address collector, uint256 feeBps, bool deductFromRecipient, bool active);
    event TransferRouted(uint256 indexed txId, address indexed sender, address indexed recipient, uint256 amount, uint256 fee, uint256 optionIdx);

    uint256 public totalTransactions;
    struct Transaction {
        address sender;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
        uint256 optionIdx;
    }
    mapping(uint256 => Transaction) public transactions;

    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "token zero");
        token = IERC20(_token);
    }

    function addFeeOption(address collector, uint256 feeBps, bool deductFromRecipient) external onlyOwner {
        require(collector != address(0), "collector zero");
        require(feeBps <= 10000, "fee too large");
        feeOptions.push(FeeOption({collector: collector, feeBps: feeBps, deductFromRecipient: deductFromRecipient, active: true}));
        emit FeeOptionAdded(feeOptions.length - 1, collector, feeBps, deductFromRecipient);
    }

    function updateFeeOption(uint256 idx, address collector, uint256 feeBps, bool deductFromRecipient, bool active) external onlyOwner {
        require(idx < feeOptions.length, "idx OOB");
        require(collector != address(0), "collector zero");
        require(feeBps <= 10000, "fee too large");
        feeOptions[idx] = FeeOption({collector: collector, feeBps: feeBps, deductFromRecipient: deductFromRecipient, active: active});
        emit FeeOptionUpdated(idx, collector, feeBps, deductFromRecipient, active);
    }

    function feeOptionsCount() external view returns (uint256) {
        return feeOptions.length;
    }

    function computeFeeForOption(uint256 idx, uint256 amount) public view returns (uint256 fee, uint256 effectiveRecipientAmount, uint256 totalSenderCost) {
        require(idx < feeOptions.length, "idx OOB");
        FeeOption memory opt = feeOptions[idx];
        require(opt.active, "not active");

        uint256 _fee = (amount * opt.feeBps) / 10000;

        if (opt.deductFromRecipient) {
            fee = _fee;
            effectiveRecipientAmount = amount > _fee ? amount - _fee : 0;
            totalSenderCost = amount; // sender gives exactly `amount`
        } else {
            fee = _fee;
            effectiveRecipientAmount = amount;
            totalSenderCost = amount + _fee;
        }
    }

    function _chooseBestOption(uint256 amount) internal view returns (uint256 bestIdx, uint256 bestFee, uint256 bestRecipientAmount, uint256 bestSenderCost) {
        require(feeOptions.length > 0, "no options");
        bool found = false;
        uint256 minCost = type(uint256).max;
        uint256 chosenFee;
        uint256 chosenRecipient;
        uint256 chosenIdx = 0;

        for (uint256 i = 0; i < feeOptions.length; i++) {
            if (!feeOptions[i].active) continue;
            (uint256 f, uint256 recAmt, uint256 senderCost) = computeFeeForOption(i, amount);
            if (!found || senderCost < minCost) {
                found = true;
                minCost = senderCost;
                chosenIdx = i;
                chosenFee = f;
                chosenRecipient = recAmt;
            }
        }

        require(found, "no active option");
        return (chosenIdx, chosenFee, chosenRecipient, minCost);
    }

    function transferBestRoute(address recipient, uint256 amount) external nonReentrant {
        require(recipient != address(0), "recipient zero");
        require(amount > 0, "amount zero");

        (uint256 optIdx, uint256 fee, uint256 recipientAmount, uint256 senderCost) = _chooseBestOption(amount);
        FeeOption memory opt = feeOptions[optIdx];

        if (opt.deductFromRecipient) {
            token.safeTransferFrom(msg.sender, address(this), amount);
            if (recipientAmount > 0) token.safeTransfer(recipient, recipientAmount);
            if (fee > 0) token.safeTransfer(opt.collector, fee);
        } else {
            token.safeTransferFrom(msg.sender, address(this), senderCost);
            if (amount > 0) token.safeTransfer(recipient, amount);
            if (fee > 0) token.safeTransfer(opt.collector, fee);
        }

        transactions[totalTransactions] = Transaction({
            sender: msg.sender,
            recipient: recipient,
            amount: recipientAmount,
            fee: fee,
            timestamp: block.timestamp,
            optionIdx: optIdx
        });

        emit TransferRouted(totalTransactions, msg.sender, recipient, recipientAmount, fee, optIdx);
        totalTransactions++;
    }

    function rescueERC20(address _token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to zero");
        IERC20(_token).safeTransfer(to, amount);
    }
}
