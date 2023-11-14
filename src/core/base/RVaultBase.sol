// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./VaultBase.sol";
import "../libs/RVaultLib.sol";
import "../libs/VaultTypeLib.sol";
import "../libs/CommonLib.sol";
import "../../interfaces/IRVault.sol";
import "../../interfaces/IPlatform.sol";

/// @notice Base rewarding vault.
///         It has a buy-back reward token and boost reward tokens.
///         Rewards are distributed smoothly by vesting with variable periods.
/// @author Alien Deployer (https://github.com/a17)
/// @author JodsMigel (https://github.com/JodsMigel)
abstract contract RVaultBase is VaultBase, IRVault {
    using SafeERC20 for IERC20;

    //region ----- Constants -----

    /// @dev Version of RVaultBase implementation
    string public constant VERSION_RVAULT_BASE = '1.0.0';

    //endregion -- Constants -----

    //region ----- Storage -----

    /// @inheritdoc IRVault
    uint public compoundRatio;

    /// @dev Total of bbToken + boost reward tokens
    uint public rewardTokensTotal;

    /// @dev A mapping of reward tokens that able to be distributed to this contract.
    ///      Token with index 0 always is bbToken.
    mapping(uint tokenIndex => address rewardToken) public rewardToken;

    /// @inheritdoc IRVault
    mapping(uint tokenIndex => uint durationSeconds) public duration;

    /// @dev Timestamp value when current period of rewards will be ended
    mapping(uint tokenIndex => uint finishTimestamp) public periodFinishForToken;

    /// @dev Reward rate in normal circumstances is distributed rewards divided on duration
    mapping(uint tokenIndex => uint rewardRate) public rewardRateForToken;

    /// @dev Last rewards snapshot time. Updated on each share movements
    mapping(uint tokenIndex => uint lastUpdateTimestamp) public lastUpdateTimeForToken;

    /// @dev Rewards snapshot calculated from rewardPerToken(rt). Updated on each share movements
    mapping(uint tokenIndex => uint rewardPerTokenStored) public rewardPerTokenStoredForToken;

    /// @dev User personal reward rate snapshot. Updated on each share movements
    mapping(uint tokenIndex => mapping(address user => uint rewardPerTokenPaid)) public userRewardPerTokenPaidForToken;

    /// @dev User personal earned reward snapshot. Updated on each share movements
    mapping(uint tokenIndex => mapping(address user => uint earned)) public rewardsForToken;

    /// @dev Receiver of rewards can be set by multisig when owner cant claim rewards himself
    mapping(address owner => address receiver) public rewardsRedirect;

    /// @dev This empty reserved space is put in place to allow future versions to add new.
    /// variables without shifting down storage in the inheritance chain.
    /// Total gap == 50 - storage slots used.
    uint[50 - 11] private __gap;

    //endregion -- Storage -----

    //region ----- Init -----

    function __RVaultBase_init(
        address platform_,
        string memory type_,
        address strategy_,
        string memory name_,
        string memory symbol_,
        uint tokenId_,
        address[] memory vaultInitAddresses,
        uint[] memory vaultInitNums
    ) internal onlyInitializing {
        __VaultBase_init(platform_, type_, strategy_, name_, symbol_, tokenId_);
        RVaultLib.baseInitCheck(platform_, vaultInitAddresses, vaultInitNums);
        uint addressesLength = vaultInitAddresses.length;
        rewardTokensTotal = addressesLength;
        for (uint i; i < addressesLength; ++i) {
            rewardToken[i] = vaultInitAddresses[i];
            duration[i] = vaultInitNums[i];
        }
        compoundRatio = vaultInitNums[vaultInitNums.length - 1];
        emit CompoundRatio(vaultInitNums[vaultInitNums.length - 1]);
    }

    //endregion -- Init -----

    //region ----- Restricted actions -----

    /// @dev All rewards for given owner could be claimed for receiver address.
    function setRewardsRedirect(address owner, address receiver) external onlyMultisig {
        rewardsRedirect[owner] = receiver;
        emit SetRewardsRedirect(owner, receiver);
    }

    //endregion -- Restricted actions ----

    //region ----- User actions -----

    /// @inheritdoc IRVault
    function getAllRewards() external {
        _getAllRewards(msg.sender, msg.sender);
    }

    /// @notice Update and Claim all rewards for given owner address. Send them to predefined receiver.
    function getAllRewardsAndRedirect(address owner) external {
        address receiver = rewardsRedirect[owner];
        if(receiver == address(0)){
            revert IControllable.IncorrectZeroArgument();
        }
        _getAllRewards(owner, receiver);
    }

    /// @notice Update and Claim all rewards for the given owner.
    ///         Sender should have allowance for push rewards for the owner.
    function getAllRewardsFor(address owner) external {
        if (owner != msg.sender) {
            // To avoid calls from any address, and possibility to cancel boosts for other addresses
            // we check approval of shares for msg.sender. Msg sender should have approval for max amount
            // As approved amount is deducted every transfer, we checks it with max / 10
            uint allowance = allowance(owner, msg.sender);
            if(allowance <= (type(uint).max / 10)){
                revert NotAllowed();
            }
        }
        _getAllRewards(owner, owner);
    }

    /// @notice Update and Claim rewards for specific token
    function getReward(uint rt) external {
        _updateReward(msg.sender, rt);
        _payRewardTo(rt, msg.sender, msg.sender);
    }

    /// @inheritdoc IRVault
    function notifyTargetRewardAmount(uint i, uint amount) external {
        _updateRewards(address(0));

        // overflow fix according to https://sips.synthetix.io/sips/sip-77
        if(amount >= type(uint).max / 1e18){
            revert IRVault.Overflow(type(uint).max / 1e18 - 1);
        }

        address _rewardToken = rewardToken[i];
        if(_rewardToken == address(0)){
            revert IRVault.RTNotFound();
        }

        uint _duration = duration[i];

        uint _oldRewardRateForToken = rewardRateForToken[i];

        if (i == 0) {
            if(address(strategy) != msg.sender){
                revert IControllable.IncorrectMsgSender();
            }
        } else {
            if(amount <= _oldRewardRateForToken * _duration / 100){
                revert IControllable.RewardIsTooSmall();
            }
        }

        IERC20(_rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        if (block.timestamp >= periodFinishForToken[i]) {
            rewardRateForToken[i] = amount / _duration;
        } else {
            uint remaining = periodFinishForToken[i] - block.timestamp;
            uint leftover = remaining * _oldRewardRateForToken;
            rewardRateForToken[i] = (amount + leftover) / _duration;
        }
        lastUpdateTimeForToken[i] = block.timestamp;
        periodFinishForToken[i] = block.timestamp + _duration;

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = IERC20(_rewardToken).balanceOf(address(this));
        if(rewardRateForToken[i] > balance / _duration){
            revert IControllable.RewardIsTooBig();
        } 
        emit RewardAdded(_rewardToken, amount);
    }

    //endregion -- User actions ----

    //region ----- View functions -----

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override (IERC165, VaultBase) returns (bool) {
        return interfaceId == type(IRVault).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IRVault
    function bbToken() public view returns(address) {
        return rewardToken[0];
    }

    
    function rewardTokens() external view returns (address[] memory) {
        uint len = rewardTokensTotal;
        address[] memory rts = new address[](len);
        for (uint i; i < len; ++i) {
            rts[i] = rewardToken[i];
        }
        return rts;
    }

    /// @notice Return reward per token ratio by reward token address
    ///                rewardPerTokenStoredForToken + (
    ///                (lastTimeRewardApplicable - lastUpdateTimeForToken)
    ///                 * rewardRateForToken * 10**18 / totalSupply)
    function rewardPerToken(uint rewardTokenIndex) external view returns (uint) {
        return _rewardPerToken(rewardTokenIndex);
    }

    /// @inheritdoc IRVault
    function earned(uint rewardTokenIndex, address account) external view returns (uint) {
        return _earned(rewardTokenIndex, account);
    }

    //endregion -- View functions -----

    //region ----- Internal logic -----

    function _getAllRewards(address owner, address receiver) internal {
        _updateRewards(owner);
        uint len = rewardTokensTotal;
        for (uint i; i < len; ++i) {
            _payRewardTo(i, owner, receiver);
        }
    }

    /// @dev Refresh reward numbers
    function _updateReward(address account, uint tokenIndex) internal {
        uint _rewardPerTokenStoredForToken = _rewardPerToken(tokenIndex);
        rewardPerTokenStoredForToken[tokenIndex] = _rewardPerTokenStoredForToken;
        lastUpdateTimeForToken[tokenIndex] = _lastTimeRewardApplicable(tokenIndex);
        if (account != address(0) && account != address(this)) {
            rewardsForToken[tokenIndex][account] = _earned(tokenIndex, account);
            userRewardPerTokenPaidForToken[tokenIndex][account] = _rewardPerTokenStoredForToken;
        }
    }

    /// @dev Use it for any underlying movements
    function _updateRewards(address account) internal {
        uint len = rewardTokensTotal;
        for (uint i; i < len; ++i) {
            _updateReward(account, i);
        }
    }

    function _earned(uint rt, address account) internal view returns (uint) {
        return balanceOf(account) * (_rewardPerToken(rt) - userRewardPerTokenPaidForToken[rt][account]) / 1e18 + rewardsForToken[rt][account];
    }

    function _rewardPerToken(uint rewardTokenIndex) internal view returns (uint) {
        uint totalSupplyWithoutItself = totalSupply() - balanceOf(address(this));
        if (totalSupplyWithoutItself == 0) {
            return rewardPerTokenStoredForToken[rewardTokenIndex];
        }
        return
            rewardPerTokenStoredForToken[rewardTokenIndex] + (
            (_lastTimeRewardApplicable(rewardTokenIndex) - lastUpdateTimeForToken[rewardTokenIndex])
            * rewardRateForToken[rewardTokenIndex]
            * 1e18
            / totalSupplyWithoutItself
        );
    }

    function _lastTimeRewardApplicable(uint rt) internal view returns (uint) {
        return Math.min(block.timestamp, periodFinishForToken[rt]);
    }

    /// @notice Transfer earned rewards to rewardsReceiver
    function _payRewardTo(uint rewardTokenIndex, address owner, address receiver) internal {
        address _rewardToken = rewardToken[rewardTokenIndex];
        uint reward = _earned(rewardTokenIndex, owner);
        if (reward > 0 && IERC20(_rewardToken).balanceOf(address(this)) >= reward) {
            rewardsForToken[rewardTokenIndex][owner] = 0;
            IERC20(_rewardToken).safeTransfer(receiver, reward);
            emit RewardPaid(owner, _rewardToken, reward);
        }
    }

    function _update(
        address from,
        address to,
        uint value
    ) internal override {
        super._update(from, to, value);
        _updateRewards(from);
        _updateRewards(to);
    }

    // function _beforeTokenTransfer(address from, address to, uint /*amount*/) internal override {
        // _updateRewards(from);
        // _updateRewards(to);
    // }

    //endregion -- Internal logic -----
}