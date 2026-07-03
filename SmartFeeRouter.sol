// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

contract SmartFeeRouter is AccessControl, ReentrancyGuard, Pausable, Multicall {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ROUTER_ADMIN_ROLE = keccak256("ROUTER_ADMIN_ROLE");
    bytes32 public constant RESCUE_ROLE = keccak256("RESCUE_ROLE");

    IERC20 public immutable token;
    uint256 public constant MAX_FEE_OPTIONS = 30;
    uint256 public totalTransactions;

    uint256 public maxTransferLimit;
    mapping(address => bool) public isRateLimitExempt;
    mapping(address => uint256) public lastTransfer;
    uint256 public constant COOLDOWN_PERIOD = 5 seconds;

    uint8 public constant FLAG_ACTIVE = 1 << 0;
    uint8 public constant FLAG_DEDUCT = 1 << 1;

    error TokenZeroAddress();
    error CollectorZeroAddress();
    error RecipientZeroAddress();
    error AmountZero();
    error FeeTooLarge();
    error IndexOutOfBounds();
    error MaxOptionsReached();
    error OptionNotActive();
    error NoActiveOption();
    error CannotRescueMainToken();
    error InvalidReceivedAmount();
    error RecipientAmountZero();
    error TransactionExpired();
    error RateLimitExceeded();
    error MaxLimitExceeded();
    error SlippageExceeded();

    struct FeeOption {
        address collector;    
        uint16 feeBps;         
        uint8 flags;          
    }

    struct RouteStats {
        uint64 totalTransfers;
        uint128 totalFeesAccumulated;
    }

    FeeOption[] public feeOptions;
    mapping(uint256 => RouteStats) public routeStats;

    event FeeOptionAdded(uint256 indexed idx, address collector, uint16 feeBps, uint8 flags);
    event FeeOptionUpdated(uint256 indexed idx, address collector, uint16 feeBps, uint8 flags);
    event MaxTransferLimitUpdated(uint256 newLimit);
    event RateLimitExemptUpdated(address indexed account, bool isExempt);
    
    event TransferRouted(
        uint256 indexed txId, 
        address indexed sender, 
        address indexed recipient, 
        address collector,
        uint256 amount, 
        uint256 fee, 
        uint256 optionIdx,
        uint256 gasUsed
    );

    constructor(address _token, address admin, uint256 _maxTransferLimit) {
        if (_token == address(0)) revert TokenZeroAddress();
        if (admin == address(0)) revert RecipientZeroAddress();
        
        token = IERC20(_token);
        maxTransferLimit = _maxTransferLimit;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROUTER_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(RESCUE_ROLE, admin);
    }

    function addFeeOption(address collector, uint16 feeBps, bool deductFromRecipient) external onlyRole(ROUTER_ADMIN_ROLE) {
        if (feeOptions.length >= MAX_FEE_OPTIONS) revert MaxOptionsReached();
        if (collector == address(0)) revert CollectorZeroAddress();
        if (feeBps >= 10000) revert FeeTooLarge();

        uint8 flags = FLAG_ACTIVE;
        if (deductFromRecipient) flags |= FLAG_DEDUCT;

        feeOptions.push(FeeOption({collector: collector, feeBps: feeBps, flags: flags}));
        emit FeeOptionAdded(feeOptions.length - 1, collector, feeBps, flags);
    }

    function updateFeeOption(uint256 idx, address collector, uint16 feeBps, bool deductFromRecipient, bool active) external onlyRole(ROUTER_ADMIN_ROLE) {
        if (idx >= feeOptions.length) revert IndexOutOfBounds();
        if (collector == address(0)) revert CollectorZeroAddress();
        if (feeBps >= 10000) revert FeeTooLarge();

        uint8 flags = 0;
        if (active) flags |= FLAG_ACTIVE;
        if (deductFromRecipient) flags |= FLAG_DEDUCT;

        feeOptions[idx] = FeeOption({collector: collector, feeBps: feeBps, flags: flags});
        emit FeeOptionUpdated(idx, collector, feeBps, flags);
    }

    function setMaxTransferLimit(uint256 newLimit) external onlyRole(ROUTER_ADMIN_ROLE) {
        maxTransferLimit = newLimit;
        emit MaxTransferLimitUpdated(newLimit);
    }

    function setRateLimitExempt(address account, bool isExempt) external onlyRole(ROUTER_ADMIN_ROLE) {
        isRateLimitExempt[account] = isExempt;
        emit RateLimitExemptUpdated(account, isExempt);
    }

    function setPaused(bool pause) external onlyRole(PAUSER_ROLE) {
        if (pause) _pause(); else _unpause();
    }

    function feeOptionsCount() external view returns (uint256) {
        return feeOptions.length;
    }

    function computeFeeForOption(uint256 idx, uint256 amount) public view returns (uint256 fee, uint256 effectiveRecipientAmount, uint256 totalSenderCost) {
        if (idx >= feeOptions.length) revert IndexOutOfBounds();
        FeeOption memory opt = feeOptions[idx];
        if ((opt.flags & FLAG_ACTIVE) == 0) revert OptionNotActive();
        
        return _calculateFee(opt, amount);
    }

    function _calculateFee(FeeOption memory opt, uint256 amount) internal pure returns (uint256 fee, uint256 effectiveRecipientAmount, uint256 totalSenderCost) {
        uint256 _fee = (amount * opt.feeBps) / 10000;

        if ((opt.flags & FLAG_DEDUCT) != 0) {
            fee = _fee;
            effectiveRecipientAmount = amount > _fee ? amount - _fee : 0;
            totalSenderCost = amount;
        } else {
            fee = _fee;
            effectiveRecipientAmount = amount;
            totalSenderCost = amount + _fee;
        }
    }

    function _chooseBestOption(uint256 amount) internal view returns (uint256 bestIdx, uint256 bestFee, uint256 bestRecipientAmount, uint256 bestSenderCost) {
        uint256 length = feeOptions.length;
        if (length == 0) revert NoActiveOption();
        
        bool found = false;
        uint256 chosenIdx;
        uint256 chosenFee;
        uint256 chosenRecipient;
        uint256 chosenCost;

        for (uint256 i; i < length; ) {
            FeeOption memory opt = feeOptions[i];
            
            if ((opt.flags & FLAG_ACTIVE) == 0) {
                unchecked { ++i; }
                continue;
            }
            
            (uint256 f, uint256 recAmt, uint256 senderCost) = _calculateFee(opt, amount);
            
            if (!found || senderCost < chosenCost || (senderCost == chosenCost && f < chosenFee)) {
                found = true;
                chosenCost = senderCost;
                chosenIdx = i;
                chosenFee = f;
                chosenRecipient = recAmt;
            }

            unchecked { ++i; }
        }

        if (!found) revert NoActiveOption();
        return (chosenIdx, chosenFee, chosenRecipient, chosenCost);
    }

    function transferBestRoute(
        address recipient, 
        uint256 amount, 
        uint256 minRecipientAmount, // Tani mbron nga Sandwich/Slippage real
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _executeTransfer(msg.sender, recipient, amount, minRecipientAmount, deadline);
    }

    function transferBestRouteWithPermit(
        address recipient,
        uint256 amount,
        uint256 minRecipientAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        (, , , uint256 senderCost) = _chooseBestOption(amount);

        try IERC20Permit(address(token)).permit(msg.sender, address(this), senderCost, deadline, v, r, s) {} catch {}
        
        _executeTransfer(msg.sender, recipient, amount, minRecipientAmount, deadline);
    }

    function _executeTransfer(
        address sender,
        address recipient,
        uint256 amount,
        uint256 minRecipientAmount,
        uint256 deadline
    ) internal {
        if (block.timestamp > deadline) revert TransactionExpired();
        if (recipient == address(0)) revert RecipientZeroAddress();
        if (amount > maxTransferLimit) revert MaxLimitExceeded();

        if (!isRateLimitExempt[sender]) {
            if (block.timestamp < lastTransfer[sender] + COOLDOWN_PERIOD) revert RateLimitExceeded();
            lastTransfer[sender] = block.timestamp;
        }

        uint256 gasStart = gasleft();

        (uint256 optIdx, , , uint256 senderCost) = _chooseBestOption(amount);
        FeeOption memory opt = feeOptions[optIdx];

        bool isDeduct = (opt.flags & FLAG_DEDUCT) != 0;
        uint256 pullAmount = isDeduct ? amount : senderCost;

        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(sender, address(this), pullAmount);
        uint256 afterBal = token.balanceOf(address(this));
        
        if (afterBal <= beforeBal) revert InvalidReceivedAmount();
        uint256 received = afterBal - beforeBal;

        uint256 fee = (received * opt.feeBps) / 10000;
        if (received <= fee) revert InvalidReceivedAmount();
        uint256 recipientAmount = received - fee;

        if (recipientAmount < minRecipientAmount) revert SlippageExceeded();
        if (recipientAmount == 0) revert RecipientAmountZero();

        token.safeTransfer(recipient, recipientAmount);
        if (fee > 0) {
            token.safeTransfer(opt.collector, fee);

            RouteStats storage stats = routeStats[optIdx];
            unchecked {
                stats.totalFeesAccumulated = uint128(stats.totalFeesAccumulated + fee);
            }
        }

        unchecked {
            routeStats[optIdx].totalTransfers++;
            ++totalTransactions;
        }

        emit TransferRouted(
            totalTransactions, 
            sender, 
            recipient, 
            opt.collector, 
            recipientAmount, 
            fee, 
            optIdx, 
            gasStart - gasleft()
        );
    }

    function rescueERC20(address _token, address to, uint256 amount) external onlyRole(RESCUE_ROLE) whenPaused {
        if (_token == address(token)) revert CannotRescueMainToken();
        if (to == address(0)) revert RecipientZeroAddress();
        
        IERC20(_token).safeTransfer(to, amount);
    }
}
