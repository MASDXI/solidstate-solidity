// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './ITimelock.sol';
import './TimelockStorage.sol';

contract Timelock is ITimelock {
    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewDelay(uint indexed newDelay);
    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature,  bytes data, uint eta);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature,  bytes data, uint eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature, bytes data, uint eta);

    // function GRACE_PERIOD () override virtual public view returns (uint) {
    //     return TimelockStorage.layout().GRACE_PERIOD;
    // }

    // function MINIMUM_DELAY () override virtual public view returns (uint) {
    //     return TimelockStorage.layout().MINIMUM_DELAY;
    // }

    // function MAXIMUM_DELAY () override virtual public view returns (uint) {
    //     return TimelockStorage.layout().MAXIMUM_DELAY;
    // }

    uint public override constant GRACE_PERIOD = 14 days;
    uint public constant MINIMUM_DELAY = 2 days;
    uint public constant MAXIMUM_DELAY = 30 days;


    function admin () virtual public view returns (address) {
        return TimelockStorage.layout().admin;
    }

    function pendingAdmin () virtual public view returns (address) {
        return TimelockStorage.layout().pendingAdmin;
    }

    function delay () override virtual public view returns (uint) {
        return TimelockStorage.layout().delay;
    }

    function queuedTransactions (bytes32 hash) virtual public override view returns (bool) {
        return TimelockStorage.layout().queuedTransactions[hash];
    }


    constructor(address admin_, uint delay_) public {
        require(delay_ >= MINIMUM_DELAY, "Timelock::constructor: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "Timelock::setDelay: Delay must not exceed maximum delay.");

        TimelockStorage.Layout storage l = TimelockStorage.layout();

        l.admin = admin_;
        l.delay = delay_;
    }

    // function () external payable { }

    function setDelay(uint delay_) public {
        require(msg.sender == address(this), "Timelock::setDelay: Call must come from Timelock.");
        require(delay_ >= MINIMUM_DELAY, "Timelock::setDelay: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "Timelock::setDelay: Delay must not exceed maximum delay.");
        
        TimelockStorage.Layout storage l = TimelockStorage.layout();

        l.delay = delay_;

        emit NewDelay(delay_);
    }

    function acceptAdmin() public override {
        require(msg.sender == pendingAdmin(), "Timelock::acceptAdmin: Call must come from pendingAdmin.");

        TimelockStorage.Layout storage l = TimelockStorage.layout();

        l.admin = msg.sender;
        l.pendingAdmin = address(0);

        emit NewAdmin(msg.sender);
    }

    function setPendingAdmin(address pendingAdmin_) public {
        require(msg.sender == address(this), "Timelock::setPendingAdmin: Call must come from Timelock.");
        
        TimelockStorage.Layout storage l = TimelockStorage.layout();

        l.pendingAdmin = pendingAdmin_;

        emit NewPendingAdmin(pendingAdmin_);
    }

    function queueTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public override returns (bytes32) {
        require(msg.sender == admin(), "Timelock::queueTransaction: Call must come from admin.");
        require(eta >= getBlockTimestamp() + delay(), "Timelock::queueTransaction: Estimated execution block must satisfy delay.");

        TimelockStorage.Layout storage l = TimelockStorage.layout();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        l.queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public override {
        require(msg.sender == admin(), "Timelock::cancelTransaction: Call must come from admin.");

        TimelockStorage.Layout storage l = TimelockStorage.layout();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        l.queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public override payable returns (bytes memory) {
        require(msg.sender == admin(), "Timelock::executeTransaction: Call must come from admin.");

        TimelockStorage.Layout storage l = TimelockStorage.layout();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(l.queuedTransactions[txHash], "Timelock::executeTransaction: Transaction hasn't been queued.");
        require(getBlockTimestamp() >= eta, "Timelock::executeTransaction: Transaction hasn't surpassed time lock.");
        require(getBlockTimestamp() <= eta + GRACE_PERIOD, "Timelock::executeTransaction: Transaction is stale.");

        l.queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    function getBlockTimestamp() internal view returns (uint) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp;
    }
}