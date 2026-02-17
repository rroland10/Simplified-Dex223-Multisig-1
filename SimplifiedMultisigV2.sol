// SPDX-License-Identifier: No License (None)
pragma solidity ^0.8.0;

contract Dex223_MultisigV2 {

    // ========================= Events =========================

    event TransactionProposed(
        uint256 indexed txId,
        address indexed proposer,
        address indexed to,
        uint256 value,
        bytes data
    );

    event TransactionApproved(
        uint256 indexed txId,
        address indexed approver
    );

    event TransactionDeclined(
        uint256 indexed txId,
        address indexed decliner
    );

    event TransactionExecuted(
        uint256 indexed txId,
        address indexed executor
    );

    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event DelayUpdated(uint256 newDelay);
    event ThresholdUpdated(uint256 newThreshold);
    event ThresholdReduced(uint256 indexed txId, uint256 newRequiredApprovals);
    event TokensReceived(address indexed from, uint256 value);

    // ========================= State =========================

    struct Tx
    {
        address to;
        uint256 value;
        bytes   data;

        uint256 proposed_timestamp;
        bool    executed;
        mapping (address => bool) signed_by;

        uint256 num_approvals;
        uint256 num_votes;
        uint256 required_approvals;
    }

    mapping (uint256 => Tx)   public txs;
    mapping (address => bool) public owner;
    uint256 public num_owners;
    uint256 public vote_pass_threshold;
    uint256 public num_TXs         = 0;
    uint256 public execution_delay = 10 hours;

    // Reentrancy guard
    bool private _locked;

    // ========================= Modifiers =========================

    modifier onlyOwner
    {
        require(owner[msg.sender], "Only owner is allowed to do this");
        _;
    }

    modifier noReentrant
    {
        require(!_locked, "Reentrant call detected");
        _locked = true;
        _;
        _locked = false;
    }

    modifier txExists(uint256 _txID)
    {
        require(_txID > 0 && _txID <= num_TXs, "Transaction does not exist");
        _;
    }

    modifier notExecuted(uint256 _txID)
    {
        require(!txs[_txID].executed, "Transaction already executed");
        _;
    }

    // ========================= Constructor =========================

    constructor (address _owner1, address _owner2, uint256 _vote_threshold) {
        require(_owner1 != address(0) && _owner2 != address(0), "Invalid owner address");
        require(_owner1 != _owner2, "Owners must be unique");
        require(_vote_threshold >= 1 && _vote_threshold <= 2, "Invalid threshold for 2 owners");

        owner[_owner1]      = true;
        owner[_owner2]      = true;
        num_owners          = 2;
        vote_pass_threshold = _vote_threshold;
    }

    // ========================= Receive =========================

    // Allow it to receive ERC223 tokens and Funds transfers.
    receive() external payable { }
    fallback() external payable { }
    function tokenReceived(address _from, uint _value, bytes memory _data) public returns (bytes4)
    {
        emit TokensReceived(_from, _value);
        return 0x8943ec02;
    }

    // ========================= Core Logic =========================

    function executeTx(uint256 _txID) public onlyOwner txExists(_txID) noReentrant
    {
        require(txAllowed(_txID), "Tx is not allowed");
        txs[_txID].executed = true;

        address _destination = txs[_txID].to;
        (bool success, ) = _destination.call{value:txs[_txID].value}(txs[_txID].data);
        require(success, "Transaction execution failed");

        emit TransactionExecuted(_txID, msg.sender);
    }

    function proposeTx(address _to, uint256 _valueInWEI, bytes calldata _data) public onlyOwner
    {
        require(_to != address(0), "Invalid destination address");

        num_TXs++;
        // Setup Tx values.
        txs[num_TXs].to    = _to;
        txs[num_TXs].value = _valueInWEI;
        txs[num_TXs].data  = _data;

        // Setup system values to keep track on Tx validity and voting.
        txs[num_TXs].proposed_timestamp    = block.timestamp;
        txs[num_TXs].signed_by[msg.sender] = true;
        txs[num_TXs].num_approvals         = 1; // The one who proposes it approves it obviously.
        txs[num_TXs].num_votes             = 1; // The one who proposes it approves it obviously.
        txs[num_TXs].required_approvals    = vote_pass_threshold; // By default the required approvals amount is equal to threshold.

        emit TransactionProposed(num_TXs, msg.sender, _to, _valueInWEI, _data);
    }

    function approveTx(uint256 _txID) public onlyOwner txExists(_txID) notExecuted(_txID)
    {
        require(!txs[_txID].signed_by[msg.sender], "This Tx is already signed by this owner");
        txs[_txID].signed_by[msg.sender] = true;
        txs[_txID].num_approvals++;
        txs[_txID].num_votes++;

        emit TransactionApproved(_txID, msg.sender);

        if(txs[_txID].num_approvals >= txs[_txID].required_approvals)
        {
            executeTx(_txID);
        }
    }

    function declineTx(uint256 _txID) public onlyOwner txExists(_txID) notExecuted(_txID)
    {
        require(!txs[_txID].signed_by[msg.sender], "This Tx is already signed by this owner");
        txs[_txID].signed_by[msg.sender] = true;
        txs[_txID].num_votes++;

        emit TransactionDeclined(_txID, msg.sender);
    }

    function txAllowed(uint256 _txID) public view returns (bool)
    {
        require(!txs[_txID].executed, "Tx already executed or rejected");
        require(txs[_txID].num_approvals >= txs[_txID].required_approvals, "Tx is not approved by enough owners or deadline expired");
        return true;
    }

    function reduceApprovalsThreshold(uint256 _txID) public onlyOwner txExists(_txID) notExecuted(_txID)
    {
        require(txs[_txID].required_approvals > 1, "Can't reduce votes threshold to 0");

        // _reductions_applied tracks how many times the threshold has already been reduced
        uint256 _reductions_applied = vote_pass_threshold - txs[_txID].required_approvals;
        uint256 _next_reduction = _reductions_applied + 1;

        require(
            num_owners - txs[_txID].num_votes >= _reductions_applied,
            "Votes against can't be withdrawn"
        );

        require(
            txs[_txID].proposed_timestamp + _next_reduction * execution_delay < block.timestamp,
            "Can't reduce votes threshold yet - time lock not elapsed"
        );

        txs[_txID].required_approvals--;

        emit ThresholdReduced(_txID, txs[_txID].required_approvals);
    }

    // ========================= Admin (Internal Only) =========================

    function addOwner(address _owner) public
    {
        require(msg.sender == address(this), "Only internal voting can introduce new owners");
        require(_owner != address(0), "Cannot add zero address as owner");
        require(!owner[_owner], "Address is already an owner");
        owner[_owner] = true;
        num_owners++;

        emit OwnerAdded(_owner);
    }

    function removeOwner(address _owner) public
    {
        require(msg.sender == address(this), "Only internal voting can remove existing owners");
        require(owner[_owner], "Address is not an owner");
        require(num_owners - 1 >= vote_pass_threshold, "Cannot reduce owners below vote threshold");
        owner[_owner] = false;
        num_owners--;

        emit OwnerRemoved(_owner);
    }

    function setupDelay(uint256 _newDelayInSeconds) public
    {
        require(msg.sender == address(this), "Only internal voting can adjust the delay");
        require(_newDelayInSeconds >= 1 hours, "Delay must be at least 1 hour");
        execution_delay = _newDelayInSeconds;

        emit DelayUpdated(_newDelayInSeconds);
    }

    function setupThreshold(uint256 _newThreshold) public
    {
        require(msg.sender == address(this), "Only internal voting can adjust the threshold");
        require(_newThreshold >= 2, "Threshold must be at least 2");
        require(_newThreshold <= num_owners, "Threshold cannot exceed number of owners");
        vote_pass_threshold = _newThreshold;

        emit ThresholdUpdated(_newThreshold);
    }

    // ========================= Helpers =========================

    function getTokenTransferData(address _destination, uint256 _amount) public pure returns (bytes memory)
    {
        bytes memory _data = abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), _destination, _amount);
        return _data;
    }
}
