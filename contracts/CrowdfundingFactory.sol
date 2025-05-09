// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Crowdfunding.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CrowdfundingFactory is ReentrancyGuard, Ownable {
    // User roles
    enum UserRole { CREATOR, CONTRIBUTOR, INFLUENCER }
    
    struct User {
        UserRole role;
        bool isRegistered;
        uint256 registrationTime;
    }
    
    struct InfluencerProfile {
        string name;
        string description;
        string[] specialties;
        uint256 rate;
        bool forDonations;
        bool isActive;
    }
    
    struct InfluencerCampaign {
        address campaignAddress;
        address influencerAddress;
        bool isPaid;
        bool isActive;
        uint256 engagementTimestamp;
    }
    
    struct CampaignNotification {
        string title;
        string message;
        uint256 timestamp;
        address campaignAddress;
    }

    // State variables
    mapping(address => User) public users;
    mapping(address => address[]) public creatorCampaigns;
    mapping(address => address[]) public contributorCampaigns;
    mapping(address => InfluencerProfile) public influencerProfiles;
    mapping(address => InfluencerCampaign[]) public influencerPromotions;
    mapping(address => mapping(address => bool)) public campaignSubscriptions;
    mapping(address => CampaignNotification[]) public userNotifications;
    mapping(address => uint256) public lastActionTimestamp;
    
    address[] public allCampaigns;
    uint256 public campaignCount;
    
    // Security parameters
    uint256 public constant COOLDOWN_PERIOD = 3 minutes;
    uint256 public constant MAX_BATCH_SIZE = 50;

    // Events
    event UserRegistered(address indexed user, UserRole role);
    event CampaignCreated(address indexed creator, address campaignAddress, string title);
    event InfluencerRegistered(address indexed influencer, string name);
    event InfluencerCampaignStarted(address indexed influencer, address indexed campaign);
    event NotificationCreated(address indexed campaignAddress, string title);
    event SubscribedToCampaign(address indexed user, address indexed campaign);
    event UnsubscribedFromCampaign(address indexed user, address indexed campaign);

    // Modifiers
    modifier onlyRegistered() {
        require(users[msg.sender].isRegistered, "User not registered");
        _;
    }
    
    modifier onlyRole(UserRole _role) {
        require(users[msg.sender].isRegistered, "User not registered");
        require(users[msg.sender].role == _role, "Incorrect user role");
        _;
    }
    
    modifier rateLimited() {
        require(
            block.timestamp > lastActionTimestamp[msg.sender] + COOLDOWN_PERIOD, 
            "Please wait before performing another action"
        );
        lastActionTimestamp[msg.sender] = block.timestamp;
        _;
    }
    
    constructor() Ownable() {
        campaignCount = 0;
    }

    // User registration
    function registerUser(UserRole _role) external {
        require(!users[msg.sender].isRegistered, "User already registered");
        require(_role == UserRole.CREATOR || _role == UserRole.CONTRIBUTOR || _role == UserRole.INFLUENCER,
                "Invalid role selected");
        
        users[msg.sender] = User({
            role: _role,
            isRegistered: true,
            registrationTime: block.timestamp
        });
        
        lastActionTimestamp[msg.sender] = block.timestamp;
        
        emit UserRegistered(msg.sender, _role);
    }

    // Creator functions
    function createCampaign(
        string memory _title,
        string memory _description,
        uint256 _goal,
        uint256 _durationInDays,
        Crowdfunding.CampaignType _campaignType,
        uint256 _approvalThreshold,
        string[3] memory _tierNames,
        uint256[3] memory _tierAmounts,
        string[3] memory _tierDescriptions
    ) external onlyRole(UserRole.CREATOR) rateLimited nonReentrant returns (address) {
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(_goal > 0, "Goal must be greater than 0");
        require(_durationInDays > 0 && _durationInDays <= 365, "Duration must be between 1 and 365 days");
        require(_approvalThreshold > 0, "Approval threshold must be greater than 0");
        
        // Deploy a new crowdfunding contract
        Crowdfunding newCampaign = new Crowdfunding(
            msg.sender,
            _title,
            _description,
            _goal,
            _durationInDays,
            _campaignType,
            _approvalThreshold,
            _tierNames,
            _tierAmounts,
            _tierDescriptions
        );
        
        address campaignAddress = address(newCampaign);
        
        creatorCampaigns[msg.sender].push(campaignAddress);
        allCampaigns.push(campaignAddress);
        campaignCount++;
        
        // Auto-subscribe the creator to their campaign
        campaignSubscriptions[msg.sender][campaignAddress] = true;
        
        emit CampaignCreated(msg.sender, campaignAddress, _title);
        
        return campaignAddress;
    }
    
    function createCampaignNotification(
        address _campaignAddress, 
        string memory _title, 
        string memory _message
    ) external onlyRole(UserRole.CREATOR) nonReentrant {
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_message).length > 0, "Message cannot be empty");
        
        bool isCreator = false;
        for (uint256 i = 0; i < creatorCampaigns[msg.sender].length; i++) {
            if (creatorCampaigns[msg.sender][i] == _campaignAddress) {
                isCreator = true;
                break;
            }
        }
        require(isCreator, "Not the creator of this campaign");
        
        CampaignNotification memory notification = CampaignNotification({
            title: _title,
            message: _message,
            timestamp: block.timestamp,
            campaignAddress: _campaignAddress
        });
        
        // Send notifications to all subscribers
        for (uint256 i = 0; i < allCampaigns.length; i++) {
            address user = allCampaigns[i];
            if (campaignSubscriptions[user][_campaignAddress]) {
                userNotifications[user].push(notification);
            }
        }
        
        emit NotificationCreated(_campaignAddress, _title);
    }

    // Influencer functions
    function createInfluencerProfile(
        string memory _name,
        string memory _description,
        string[] memory _specialties,
        uint256 _rate,
        bool _forDonations
    ) external onlyRole(UserRole.INFLUENCER) nonReentrant {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(_specialties.length > 0, "Must specify at least one specialty");
        
        influencerProfiles[msg.sender] = InfluencerProfile({
            name: _name,
            description: _description,
            specialties: _specialties,
            rate: _rate,
            forDonations: _forDonations,
            isActive: true
        });
        
        emit InfluencerRegistered(msg.sender, _name);
    }
    
    function promoteStartupCampaign(address _campaignAddress, address _influencerAddress) 
        external 
        payable 
        onlyRole(UserRole.CREATOR) 
        nonReentrant 
    {
        require(influencerProfiles[_influencerAddress].isActive, "Influencer profile is not active");
        require(msg.value >= influencerProfiles[_influencerAddress].rate, "Insufficient payment for influencer");
        
        // Find the campaign and check if it's owned by the creator
        bool foundCampaign = false;
        for (uint i = 0; i < creatorCampaigns[msg.sender].length; i++) {
            if (creatorCampaigns[msg.sender][i] == _campaignAddress) {
                foundCampaign = true;
                break;
            }
        }
        
        require(foundCampaign, "Campaign not found or not owned by creator");
        
        // Create the promotion
        InfluencerCampaign memory newPromotion = InfluencerCampaign({
            campaignAddress: _campaignAddress,
            influencerAddress: _influencerAddress,
            isPaid: true,
            isActive: true,
            engagementTimestamp: block.timestamp
        });
        
        influencerPromotions[_influencerAddress].push(newPromotion);
        
        // Transfer payment to influencer
        payable(_influencerAddress).transfer(msg.value);
        
        emit InfluencerCampaignStarted(_influencerAddress, _campaignAddress);
    }
    
    function promoteDonationCampaign(address _campaignAddress, address _influencerAddress) 
        external 
        onlyRole(UserRole.CREATOR) 
        nonReentrant 
    {
        require(influencerProfiles[_influencerAddress].isActive, "Influencer profile is not active");
        require(influencerProfiles[_influencerAddress].forDonations, "Influencer does not promote donations");
        
        // Find the campaign and check if it's owned by the creator
        bool foundCampaign = false;
        for (uint i = 0; i < creatorCampaigns[msg.sender].length; i++) {
            if (creatorCampaigns[msg.sender][i] == _campaignAddress) {
                foundCampaign = true;
                break;
            }
        }
        
        require(foundCampaign, "Campaign not found or not owned by creator");
        
        // Create the promotion request
        InfluencerCampaign memory newPromotion = InfluencerCampaign({
            campaignAddress: _campaignAddress,
            influencerAddress: _influencerAddress,
            isPaid: false,
            isActive: false,  // Needs to be accepted by the influencer
            engagementTimestamp: block.timestamp
        });
        
        influencerPromotions[_influencerAddress].push(newPromotion);
    }
    
    // Contributor functions
    function subscribeToCampaign(address _campaignAddress) external onlyRole(UserRole.CONTRIBUTOR) {
        require(_campaignAddress != address(0), "Invalid campaign address");
        
        // Check if the campaign exists
        bool campaignExists = false;
        for (uint i = 0; i < allCampaigns.length; i++) {
            if (allCampaigns[i] == _campaignAddress) {
                campaignExists = true;
                break;
            }
        }
        require(campaignExists, "Campaign does not exist");
        
        campaignSubscriptions[msg.sender][_campaignAddress] = true;
        
        // Add to contributor's campaigns list if not already there
        bool alreadyAdded = false;
        for (uint i = 0; i < contributorCampaigns[msg.sender].length; i++) {
            if (contributorCampaigns[msg.sender][i] == _campaignAddress) {
                alreadyAdded = true;
                break;
            }
        }
        
        if (!alreadyAdded) {
            contributorCampaigns[msg.sender].push(_campaignAddress);
        }
        
        emit SubscribedToCampaign(msg.sender, _campaignAddress);
    }
    
    function unsubscribeFromCampaign(address _campaignAddress) external onlyRegistered {
        require(campaignSubscriptions[msg.sender][_campaignAddress], "Not subscribed to this campaign");
        
        campaignSubscriptions[msg.sender][_campaignAddress] = false;
        
        emit UnsubscribedFromCampaign(msg.sender, _campaignAddress);
    }

    // Utility functions
    function getUserRole(address _user) external view returns (UserRole) {
        require(users[_user].isRegistered, "User not registered");
        return users[_user].role;
    }
    
    function getUserCampaigns(address _user) external view returns (address[] memory) {
        if (users[_user].role == UserRole.CREATOR) {
            return creatorCampaigns[_user];
        } else if (users[_user].role == UserRole.CONTRIBUTOR) {
            return contributorCampaigns[_user];
        }
        
        address[] memory emptyCampaigns = new address[](0);
        return emptyCampaigns;
    }
    
    function getAllCampaigns() external view returns (address[] memory) {
        return allCampaigns;
    }
    
    function getCampaignsCount() external view returns (uint256) {
        return campaignCount;
    }
    
    function getUserNotifications(address _user) 
        external 
        view 
        returns (CampaignNotification[] memory) 
    {
        return userNotifications[_user];
    }
    
    function getNotificationCount(address _user) external view returns (uint256) {
        return userNotifications[_user].length;
    }
    
    // Batch operations (with size limits to prevent DOS attacks)
    function batchGetCampaigns(uint256 _startIndex, uint256 _count) 
        external 
        view 
        returns (address[] memory) 
    {
        require(_count <= MAX_BATCH_SIZE, "Requested batch size too large");
        require(_startIndex < allCampaigns.length, "Start index out of bounds");
        
        uint256 endIndex = _startIndex + _count;
        if (endIndex > allCampaigns.length) {
            endIndex = allCampaigns.length;
        }
        
        uint256 resultSize = endIndex - _startIndex;
        address[] memory result = new address[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = allCampaigns[_startIndex + i];
        }
        
        return result;
    }
    
    // Admin functions
    function removeCampaign(address _campaignAddress) external onlyOwner {
        for (uint256 i = 0; i < allCampaigns.length; i++) {
            if (allCampaigns[i] == _campaignAddress) {
                allCampaigns[i] = allCampaigns[allCampaigns.length - 1];
                allCampaigns.pop();
                campaignCount--;
                break;
            }
        }
    }
    
    // Prevent direct ETH transfers to the contract
    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }
}
