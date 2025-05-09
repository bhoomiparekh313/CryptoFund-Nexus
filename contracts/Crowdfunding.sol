
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract Crowdfunding is ReentrancyGuard {
    using Address for address payable;

    // Campaign State
    enum CampaignType { STARTUP, DONATION }
    enum CampaignState { ACTIVE, SUCCESSFUL, FAILED, CLOSED }

    struct Tier {
        string name;
        uint256 amount;
        string description;
    }

    struct Campaign {
        address creator;
        string title;
        string description;
        uint256 goal;
        uint256 deadline;
        uint256 amountRaised;
        CampaignType campaignType;
        CampaignState state;
        uint256 approvalThreshold;
    }

    Campaign public campaign;
    Tier[3] public tiers;
    mapping(address => uint256) public contributions;
    address[] public contributors;
    mapping(address => bool) public approvers;
    mapping(address => bool) public hasApproved;
    uint256 public approvalCount;
    uint256 public contributorsCount;
    
    // Added variables for security and tracking
    bool private _locked;
    uint256 public lastWithdrawalTime;

    // Events
    event ContributionMade(address indexed contributor, uint256 amount, uint256 tier);
    event FundsWithdrawn(address indexed creator, uint256 amount);
    event CampaignStateChanged(CampaignState newState);
    event ApprovalGranted(address indexed approver);

    // Modifiers
    modifier onlyCreator() {
        require(msg.sender == campaign.creator, "Only the campaign creator can call this function");
        _;
    }

    modifier campaignActive() {
        require(campaign.state == CampaignState.ACTIVE, "Campaign is not active");
        require(block.timestamp < campaign.deadline, "Campaign has ended");
        _;
    }

    modifier pastDeadline() {
        require(block.timestamp >= campaign.deadline, "Campaign is still active");
        _;
    }
    
    // Rate limiting to prevent flash loan attacks
    modifier rateLimited() {
        require(block.timestamp > lastWithdrawalTime + 1 hours, "Withdrawal too soon");
        _;
    }

    // Constructor
    constructor(
        address _creator,
        string memory _title,
        string memory _description,
        uint256 _goal,
        uint256 _durationInDays,
        CampaignType _campaignType,
        uint256 _approvalThreshold,
        string[3] memory _tierNames,
        uint256[3] memory _tierAmounts,
        string[3] memory _tierDescriptions
    ) {
        require(_creator != address(0), "Invalid creator address");
        require(_goal > 0, "Goal must be greater than 0");
        require(_durationInDays > 0, "Duration must be greater than 0");
        require(_approvalThreshold > 0, "Approval threshold must be greater than 0");
        
        campaign.creator = _creator;
        campaign.title = _title;
        campaign.description = _description;
        campaign.goal = _goal;
        campaign.deadline = block.timestamp + (_durationInDays * 1 days);
        campaign.amountRaised = 0;
        campaign.campaignType = _campaignType;
        campaign.state = CampaignState.ACTIVE;
        campaign.approvalThreshold = _approvalThreshold;

        // Set up the three tiers with additional validation
        for (uint8 i = 0; i < 3; i++) {
            require(bytes(_tierNames[i]).length > 0, "Tier name cannot be empty");
            require(_tierAmounts[i] > 0, "Tier amount must be greater than 0");
            
            // Ensure tiers are in ascending order
            if (i > 0) {
                require(_tierAmounts[i] > _tierAmounts[i-1], "Tiers must be in ascending order");
            }
            
            tiers[i] = Tier({
                name: _tierNames[i],
                amount: _tierAmounts[i],
                description: _tierDescriptions[i]
            });
        }
    }

    // Helper function to verify tierAmounts are valid (thirdweb compatibility)
    function validateTierAmounts(uint256[3] memory _tierAmounts) public pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (_tierAmounts[i] <= 0) return false;
            if (i > 0 && _tierAmounts[i] <= _tierAmounts[i-1]) return false;
        }
        return true;
    }

    // Core functions
    function contribute(uint8 _tierIndex) external payable campaignActive nonReentrant {
        require(_tierIndex >= 0 && _tierIndex < 3, "Invalid tier index");
        require(msg.value == tiers[_tierIndex].amount, "Contribution must match tier amount");
        require(msg.value > 0, "Cannot contribute 0 or negative value");

        if (contributions[msg.sender] == 0) {
            contributors.push(msg.sender);
            contributorsCount++;
        }

        contributions[msg.sender] += msg.value;
        campaign.amountRaised += msg.value;

        // Check if contributor qualifies as an approver
        if (contributions[msg.sender] >= campaign.approvalThreshold && !approvers[msg.sender]) {
            approvers[msg.sender] = true;
        }

        emit ContributionMade(msg.sender, msg.value, _tierIndex);
        
        // Check if campaign goal has been reached
        if (campaign.amountRaised >= campaign.goal && campaign.state == CampaignState.ACTIVE) {
            campaign.state = CampaignState.SUCCESSFUL;
            emit CampaignStateChanged(CampaignState.SUCCESSFUL);
        }
    }

    function approveWithdrawal() external nonReentrant {
        require(approvers[msg.sender], "Only approvers can approve withdrawals");
        require(!hasApproved[msg.sender], "You have already approved");
        require(campaign.state == CampaignState.SUCCESSFUL || campaign.state == CampaignState.ACTIVE, "Campaign is not active or successful");

        hasApproved[msg.sender] = true;
        approvalCount++;
        
        emit ApprovalGranted(msg.sender);
    }

    function withdrawFunds() external onlyCreator nonReentrant rateLimited {
        uint approverCount = getApproverCount();
        require(approverCount > 0, "No approvers yet");
        require(approvalCount > 0, "No approvals yet");
        require(approvalCount >= (approverCount / 2), "Need approval from at least 50% of approvers");
        
        // State checks
        require(campaign.state == CampaignState.SUCCESSFUL || 
                (campaign.state == CampaignState.ACTIVE && campaign.amountRaised >= campaign.goal),
                "Campaign must be successful to withdraw");

        uint256 amountToWithdraw = campaign.amountRaised;
        require(amountToWithdraw > 0, "No funds to withdraw");
        
        // Set state before transfer to prevent reentrancy
        campaign.amountRaised = 0;
        campaign.state = CampaignState.CLOSED;
        lastWithdrawalTime = block.timestamp;
        
        // Use safe transfer pattern
        payable(campaign.creator).sendValue(amountToWithdraw);
        
        emit FundsWithdrawn(campaign.creator, amountToWithdraw);
        emit CampaignStateChanged(CampaignState.CLOSED);
    }

    function checkStatus() external pastDeadline {
        if (campaign.state == CampaignState.ACTIVE) {
            if (campaign.amountRaised >= campaign.goal) {
                campaign.state = CampaignState.SUCCESSFUL;
            } else {
                campaign.state = CampaignState.FAILED;
            }
            emit CampaignStateChanged(campaign.state);
        }
    }

    function refund() external pastDeadline nonReentrant {
        require(campaign.state == CampaignState.FAILED, "Campaign has not failed");
        require(contributions[msg.sender] > 0, "No contributions to refund");
        
        uint256 refundAmount = contributions[msg.sender];
        contributions[msg.sender] = 0;
        
        // Use safe transfer pattern
        payable(msg.sender).sendValue(refundAmount);
    }

    // View functions
    function getCampaignDetails() external view returns (
        address creator,
        string memory title,
        string memory description,
        uint256 goal,
        uint256 deadline,
        uint256 amountRaised,
        CampaignType campaignType,
        CampaignState state,
        uint256 approvalThreshold
    ) {
        return (
            campaign.creator,
            campaign.title,
            campaign.description,
            campaign.goal,
            campaign.deadline,
            campaign.amountRaised,
            campaign.campaignType,
            campaign.state,
            campaign.approvalThreshold
        );
    }

    function getTier(uint8 _index) external view returns (
        string memory name,
        uint256 amount,
        string memory description
    ) {
        require(_index >= 0 && _index < 3, "Invalid tier index");
        return (
            tiers[_index].name,
            tiers[_index].amount,
            tiers[_index].description
        );
    }

    function getContributorCount() external view returns (uint256) {
        return contributorsCount;
    }

    function getApproverCount() public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < contributors.length; i++) {
            if (approvers[contributors[i]]) {
                count++;
            }
        }
        return count;
    }
    
    // Emergency functions
    function emergencyStop() external onlyCreator {
        require(campaign.state == CampaignState.ACTIVE, "Campaign is not active");
        campaign.state = CampaignState.FAILED;
        emit CampaignStateChanged(CampaignState.FAILED);
    }
    
    receive() external payable {
        revert("Direct contributions are not allowed, use the contribute function");
    }
    
    fallback() external payable {
        revert("Function not found");
    }
}

