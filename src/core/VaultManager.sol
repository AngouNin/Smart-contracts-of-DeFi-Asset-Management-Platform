// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "./base/Controllable.sol";
import "./libs/VaultManagerLib.sol";
import "./libs/VaultTypeLib.sol";
import "../interfaces/IVaultManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IRVault.sol";
import "../interfaces/IManagedVault.sol";

/// @notice The vaults are assembled at the factory by users through UI.
///         Deployment rights of a vault are tokenized in VaultManager NFT.
///         The holders of these tokens receive a share of the vault revenue and can manage vault if possible.
/// @dev Rewards transfers to token owner or revenue receiver address managed by token owner.
/// @author Alien Deployer (https://github.com/a17)
/// @author Jude (https://github.com/iammrjude)
/// @author JodsMigel (https://github.com/JodsMigel)
contract VaultManager is Controllable, ERC721EnumerableUpgradeable, IVaultManager {

    /// @inheritdoc IControllable
    string public constant VERSION = '1.0.0';

    /// @inheritdoc IVaultManager
    mapping (uint tokenId => address vault) public tokenVault;

    mapping (uint tokenId => address account) internal _revenueReceiver;

    /// @dev This empty reserved space is put in place to allow future versions to add new.
    /// variables without shifting down storage in the inheritance chain.
    /// Total gap == 50 - storage slots used.
    uint[50 - 2] private __gap;

    function init(address platform_) external initializer {
        __Controllable_init(platform_);
        __ERC721_init("Stability Vault", "VAULT");
    }

    /// @inheritdoc IVaultManager
    function changeVaultParams(uint tokenId, address[] memory addresses, uint[] memory nums) external {
        _requireOwner(tokenId);
        address vault = tokenVault[tokenId];
        IManagedVault(vault).changeParams(addresses, nums);
        emit ChangeVaultParams(tokenId, addresses, nums);
    }

    /// @inheritdoc IVaultManager
    function mint(address to, address vault) external onlyFactory returns (uint tokenId) {
        tokenId = totalSupply();
        tokenVault[tokenId] = vault;
        _mint(to, tokenId);
    }

    /// @inheritdoc IVaultManager
    function setRevenueReceiver(uint tokenId, address receiver) external {
        _requireOwner(tokenId);
        _revenueReceiver[tokenId] = receiver;
        emit SetRevenueReceiver(tokenId, receiver);
    }

    /// @dev Returns current token URI metadata
    /// @param tokenId Token ID to fetch URI for.
    function tokenURI(uint tokenId) public view override (ERC721Upgradeable, IERC721Metadata) returns (string memory) {
        if(_ownerOf(tokenId) == address(0)){
            revert NotExist();
        }

        VaultData memory vaultData;
        IPlatform _platform = IPlatform(platform());
        IFactory factory = IFactory(_platform.factory());
        vaultData.vault = tokenVault[tokenId];
        IVault vault = IVault(vaultData.vault);
        IStrategy strategy = vault.strategy();
        //slither-disable-next-line unused-return
        (vaultData.sharePrice,) = vault.price();
        //slither-disable-next-line unused-return
        (vaultData.tvl,) = vault.tvl();
        //slither-disable-next-line unused-return
        (vaultData.totalApr,vaultData.strategyApr,,) = vault.getApr();
        vaultData.vaultType = vault.VAULT_TYPE();
        vaultData.name = IERC20Metadata(vaultData.vault).name();
        vaultData.vaultExtra = vault.extra();
        vaultData.strategyExtra = strategy.extra();

        address bbAsset = address(0);
        if (keccak256(bytes(vaultData.vaultType)) == keccak256(bytes(VaultTypeLib.REWARDING))) {
            address[] memory rts = IRVault(vaultData.vault).rewardTokens();
            vaultData.rewardAssetsSymbols = CommonLib.getSymbols(rts);
            bbAsset = rts[0];
        }

        (
            vaultData.strategyId,,
            vaultData.assetsSymbols,
            vaultData.strategySpecific,
            vaultData.symbol
        ) = factory.getStrategyData(vaultData.vaultType, address(strategy), bbAsset);

        (,,,,,vaultData.strategyTokenId) = factory.strategyLogicConfig(keccak256(bytes(vaultData.strategyId)));

        return VaultManagerLib.tokenURI(vaultData, _platform.PLATFORM_VERSION(), _platform.getPlatformSettings());
    }

    /// @inheritdoc IVaultManager
    function vaults() external view returns(
        address[] memory vaultAddress,
        string[] memory symbol,
        string[] memory vaultType,
        string[] memory strategyId,
        uint[] memory sharePrice,
        uint[] memory tvl
    ) {
        uint len = totalSupply();
        vaultAddress = new address[](len);
        symbol = new string[](len);
        vaultType = new string[](len);
        strategyId = new string[](len);
        sharePrice = new uint[](len);
        tvl = new uint[](len);
        for (uint i; i < len; ++i) {
            vaultAddress[i] = tokenVault[i];
            symbol[i] = IERC20Metadata(vaultAddress[i]).symbol();
            vaultType[i] = IVault(vaultAddress[i]).VAULT_TYPE();
            strategyId[i] = IVault(vaultAddress[i]).strategy().STRATEGY_LOGIC_ID();
            //slither-disable-next-line unused-return
            (sharePrice[i],) = IVault(vaultAddress[i]).price();
            //slither-disable-next-line unused-return
            (tvl[i],) = IVault(vaultAddress[i]).tvl();
        }
    }

    /// @inheritdoc IVaultManager
    function vaultAddresses() external view returns(address[] memory vaultAddress) {
        uint len = totalSupply();
        vaultAddress = new address[](len);
        for (uint i; i < len; ++i) {
            vaultAddress[i] = tokenVault[i];
        }
    }

    /// @inheritdoc IVaultManager
    function getRevenueReceiver(uint tokenId) external view returns (address receiver) {
        receiver = _revenueReceiver[tokenId];
        if (receiver == address(0)) {
            receiver = _ownerOf(tokenId);
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override (ERC721EnumerableUpgradeable, IERC165, Controllable) returns (bool) {
        return 
            interfaceId == type(IVaultManager).interfaceId
            || interfaceId == type(IControllable).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _requireOwner(uint tokenId) internal view {
        if(_ownerOf(tokenId) != msg.sender){
            revert NotTheOwner();
        }
    }
}