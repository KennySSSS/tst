// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @notice This contract stores and transfers NFT's or references to physical items to eligible stakers.

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract StakingVault is Ownable, ERC721Holder, ERC1155Holder {
    /// @dev Use SafeERC20 to ensure checked transfers on ERC20 tokens
    using SafeERC20 for IERC20;

    /// @notice 'admin' is the contract address of the proxy contract that initiates redeeming points
    address public admin;

    /// @dev Defines type of marketplace items. 'PHYSICAL' doesn't payout from vault and is handled off-chain.
    enum ItemType {
        PHYSICAL,
        ERC721,
        ERC1155,
        ERC20
    }

    /// @dev Store info of each colleciton added. 'ownedIds' is each ID transferred into the vault for a given collection.
    struct Collections {
        IERC721 collection721;
        IERC1155 collection1155;
        IERC20 token20;
        ItemType itemType;
        string collectionName;
        uint256[] ownedIds;
        uint256 cost;
        uint256 leagueHurdle;
        uint16 index; // 1155 ID or 721 start index
        uint16 physicalStock;
        uint16 maxClaimsPerAddr;
    }

    /// @notice Mapping of each collection and relevant info added to vault.
    mapping(uint16 => Collections) private vaultCollections;

    constructor(address _admin) {
        admin = _admin;
    }

    /// @dev Should be a contract address that can redeem points of a staker.
    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
    }

    /// @notice Set and add details for a new collection being added to the vault.
    /// @dev Can pass in the same address for all collection params (_collection721, _collection1155, _token20) when calling this function. _collectionDetails contains multiple args to overcome arg limit.
    /// @param _cost[0] = cost
    /// @param _cost[1] = leagueHurdle in points
    /// @param _collectionDetails[0] = vaultId: Must match the ID that was set in the proxy contract in setRedeemableItem().
    /// @param _collectionDetails[1] = index: If adding an ERC721 collection, use _index to store start index of collection. For ERC1155, use this for ID of token.
    /// @param _collectionDetails[2] = physicalStock
    /// @param _collectionDetails[3] = maxClaimsPerAddr
    /// @param _collection721 The address of the collection being added.
    /// @param _collection1155 The address of the collection ID being added.
    /// @param _token20 The address of the token being added.
    /// @param _type Refers to ItemType enum
    /// @param _collectionName Name of collection to match against name set in proxy
    function setVaultCollection(
        uint256[] calldata _cost,
        uint16[] calldata _collectionDetails,
        IERC721 _collection721,
        IERC1155 _collection1155,
        IERC20 _token20,
        ItemType _type,
        string calldata _collectionName
    ) external onlyOwner {
        uint16 vaultId = _collectionDetails[0];
        uint16 index = _collectionDetails[1];
        uint16 physicalStock = _collectionDetails[2];
        uint16 maxClaims = _collectionDetails[3];
        uint256 cost = _cost[0];
        uint256 leaguePoints = _cost[1];
        uint256 nameLen = bytes(vaultCollections[vaultId].collectionName)
            .length;
        string
            memory overwriteError = "Vault collection has a balance. Withdraw ID's before overwriting colleciton.";
        if (_type == ItemType.ERC721) {
            // Disallow overwitting vault collection with a balance
            if (nameLen > 0) {
                require(
                    vaultCollections[vaultId].collection721.balanceOf(
                        address(this)
                    ) < 1,
                    overwriteError
                );
            }
            vaultCollections[vaultId].collection721 = _collection721;
            vaultCollections[vaultId].itemType = ItemType.ERC721;
        }
        if (_type == ItemType.ERC1155) {
            if (nameLen > 0) {
                require(
                    vaultCollections[vaultId].collection1155.balanceOf(
                        address(this),
                        index
                    ) < 1,
                    overwriteError
                );
            }
            vaultCollections[vaultId].collection1155 = _collection1155;
            vaultCollections[vaultId].itemType = ItemType.ERC1155;
        }
        if (_type == ItemType.ERC20) {
            if (nameLen > 0) {
                require(
                    vaultCollections[vaultId].token20.balanceOf(address(this)) <
                        1,
                    overwriteError
                );
            }
            vaultCollections[vaultId].token20 = _token20;
            vaultCollections[vaultId].itemType = ItemType.ERC20;
        }
        if (_type == ItemType.PHYSICAL) {
            vaultCollections[vaultId].itemType = ItemType.PHYSICAL;
            vaultCollections[vaultId].physicalStock = physicalStock;
        }
        vaultCollections[vaultId].maxClaimsPerAddr = maxClaims;
        vaultCollections[vaultId].index = index;
        vaultCollections[vaultId].collectionName = _collectionName;
        vaultCollections[vaultId].cost = cost;
        vaultCollections[vaultId].leagueHurdle = leaguePoints;
    }

    function setCost(uint16 _vaultId, uint256 _cost) external onlyOwner {
        vaultCollections[_vaultId].cost = _cost;
    }

    function setPhysicalStock(uint16 _vaultId, uint16 physicalStock)
        external
        onlyOwner
    {
        vaultCollections[_vaultId].physicalStock = physicalStock;
    }

    /// @dev Leagues are defined at the collectoin level and can limit access to items available in store based on points
    function setLeagueHurdle(uint16 _vaultId, uint256 _points)
        external
        onlyOwner
    {
        vaultCollections[_vaultId].leagueHurdle = _points;
    }

    /// @dev Limits the total amount an item can be claimed by a particular address.
    function setMaxClaimsPerAddr(uint16 _vaultId, uint16 _max)
        external
        onlyOwner
    {
        vaultCollections[_vaultId].maxClaimsPerAddr = _max;
    }

    /// @dev Requires collection to exist before adding assets to it
    function collectionNameExists(
        uint16 _collection,
        string calldata _collectionName
    ) internal view returns (bool exists) {
        if (
            keccak256(abi.encodePacked(_collectionName)) ==
            keccak256(
                abi.encodePacked(vaultCollections[_collection].collectionName)
            )
        ) {
            return true;
        }
        return false;
    }

    /// @notice Adds ERC721 NFT's to vault for a specific colleciton.
    /// @dev Must be contract owner that owns the assets and deposits to vault.
    function addERC721ToVault(
        uint16 _collection,
        string calldata _collectionName,
        uint256[] calldata _tokenIds
    ) external onlyOwner {
        require(
            collectionNameExists(_collection, _collectionName),
            "Collection name not found"
        );
        require(
            vaultCollections[_collection].collection721.balanceOf(msg.sender) >=
                _tokenIds.length,
            "Insufficient balance (ERC721) to transfer to vault"
        );
        for (uint256 i; i < _tokenIds.length; ++i) {
            uint256 tokenId = _tokenIds[i];
            // Use ownedIds to store each ID added in an array to later iterate over
            vaultCollections[_collection].ownedIds.push(tokenId);
            vaultCollections[_collection].collection721.safeTransferFrom(
                msg.sender,
                address(this),
                tokenId
            );
        }
    }

    /// @notice Adds ERC1155 NFT's to vault for a specific ID of a colleciton.
    /// @dev Must be contract owner that owns the assets and deposits to vault.
    function addERC1155ToVault(
        uint16 _collection,
        string calldata _collectionName,
        uint256 _id,
        uint256 _amount
    ) external onlyOwner {
        require(
            collectionNameExists(_collection, _collectionName),
            "Collection name not found"
        );
        uint256 balance = vaultCollections[_collection]
            .collection1155
            .balanceOf(msg.sender, _id);
        require(
            balance >= _amount,
            "Insufficient balance (ERC1155) to transfer to vault"
        );
        vaultCollections[_collection].collection1155.safeTransferFrom(
            msg.sender,
            address(this),
            _id,
            _amount,
            ""
        );
    }

    /// @notice Adds ERC20 tokens to vault for a specific token.
    /// @dev Must be contract owner that owns the assets and deposits to vault.
    function addERC20ToVault(
        uint16 _collection,
        string calldata _collectionName,
        uint256 _amount
    ) external onlyOwner {
        require(
            collectionNameExists(_collection, _collectionName),
            "Collection name not found"
        );
        require(
            vaultCollections[_collection].token20.balanceOf(msg.sender) >=
                _amount,
            "Insufficient balance (ERC20) to transfer to vault"
        );
        vaultCollections[_collection].token20.safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    function getVaultCollectionAddress(uint16 _vaultId)
        external
        view
        returns (
            IERC721,
            IERC1155,
            IERC20
        )
    {
        return (
            vaultCollections[_vaultId].collection721,
            vaultCollections[_vaultId].collection1155,
            vaultCollections[_vaultId].token20
        );
    }

    function getVaultCollectionInfo(uint16 _vaultId)
        external
        view
        returns (
            string memory,
            uint256,
            uint256,
            uint16,
            uint16,
            uint16
        )
    {
        string memory cName = vaultCollections[_vaultId].collectionName;
        return (
            cName,
            vaultCollections[_vaultId].cost,
            vaultCollections[_vaultId].leagueHurdle,
            vaultCollections[_vaultId].index,
            vaultCollections[_vaultId].physicalStock,
            vaultCollections[_vaultId].maxClaimsPerAddr
        );
    }

    /// @dev Returns specific ID's for assets in a vault collection
    function getVaultCollectionIds(uint16 _vaultId)
        external
        view
        returns (uint256[] memory)
    {
        uint256 idsLen = vaultCollections[_vaultId].ownedIds.length;
        uint256[] memory ids = new uint256[](idsLen);
        for (uint256 i; i < idsLen; ++i) {
            ids[i] = vaultCollections[_vaultId].ownedIds[i];
        }
        return (ids);
    }

    /// @notice Returns the vault balance of a specific colleciton or token.
    /// @dev Must pass in token ID if querying for an ERC1155 collection.
    function getCollectionBalance(uint16 _collection, uint256 _erc1155Id)
        external
        view
        returns (uint256 balance)
    {
        if (vaultCollections[_collection].itemType == ItemType.ERC721) {
            return
                vaultCollections[_collection].collection721.balanceOf(
                    address(this)
                );
        }
        if (vaultCollections[_collection].itemType == ItemType.ERC1155) {
            return
                vaultCollections[_collection].collection1155.balanceOf(
                    address(this),
                    _erc1155Id
                );
        }
        if (vaultCollections[_collection].itemType == ItemType.ERC20) {
            return
                vaultCollections[_collection].token20.balanceOf(address(this));
        }
    }

    /// @dev Helper to get random ID for each item being claimed
    function getRandom(uint256 _limit, uint256 _topLevelcounter)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 internalCounter = _topLevelcounter;
        uint256 id = (uint256(
            keccak256(abi.encodePacked(internalCounter++, _limit))
        ) % _limit);
        return (id, _topLevelcounter + internalCounter);
    }

    /// @notice Vault items are issued randomly when claimed.
    function randomId(
        uint16 _vaultId,
        uint256 _limit,
        uint256 _topLevelcounter
    ) internal returns (uint256 tokenId, uint256 returnedCounter) {
        // Get random number to verify below in loop
        returnedCounter = _topLevelcounter;
        uint256 id;
        (id, returnedCounter) = getRandom(_limit, returnedCounter);

        // Check if ID exists in collection
        for (
            uint256 i;
            i < vaultCollections[_vaultId].ownedIds.length * 10;
            ++i
        ) {
            if (vaultCollections[_vaultId].ownedIds[id] > 0) {
                tokenId = vaultCollections[_vaultId].ownedIds[id];

                // If it's last ID, delete array
                if (_limit == 1) {
                    delete vaultCollections[_vaultId].ownedIds;
                } else {
                    uint256 idsLength = vaultCollections[_vaultId]
                        .ownedIds
                        .length;
                    // Move selected ID to end of array and remove it
                    vaultCollections[_vaultId].ownedIds[id] = vaultCollections[
                        _vaultId
                    ].ownedIds[idsLength - 1];
                    vaultCollections[_vaultId].ownedIds.pop();
                }

                // Break from loop and return valid id
                return (tokenId, returnedCounter);
            } else {
                // Get a new random number
                (id, returnedCounter) = getRandom(_limit, returnedCounter);
            }
        }
    }

    /// @notice After points are deducted when claiming from proxy contract, vault items are transfered here. For ERC721 items, a semi-random ID is issued.
    /// @dev Only the staking manager contract can call this function.
    function transferItems(
        address _recipient,
        uint16 _vaultId,
        uint16 _qtyToClaim,
        uint256 _points,
        uint16 _claimed
    ) external returns (uint256 totalCost, bool isPhysical) {
        require(msg.sender == admin, "Not authorized");
        require(
            bytes(vaultCollections[_vaultId].collectionName).length > 0,
            "Non-existent vault collection"
        );
        require(
            _points >= vaultCollections[_vaultId].leagueHurdle,
            "Out of league"
        );
        if (vaultCollections[_vaultId].maxClaimsPerAddr > 0) {
            require(
                _claimed + _qtyToClaim <=
                    vaultCollections[_vaultId].maxClaimsPerAddr,
                "Exceeds total allowable claims"
            );
        }

        // Calculate points required for an item * qty
        totalCost = vaultCollections[_vaultId].cost * _qtyToClaim;

        if (vaultCollections[_vaultId].itemType == ItemType.PHYSICAL) {
            require(
                vaultCollections[_vaultId].physicalStock >= _qtyToClaim,
                "Out of stock"
            );
            vaultCollections[_vaultId].physicalStock -= _qtyToClaim;
            return (totalCost, true);
        } else {
            if (vaultCollections[_vaultId].itemType == ItemType.ERC721) {
                uint256 balance = vaultCollections[_vaultId]
                    .collection721
                    .balanceOf(address(this));
                require(
                    balance >= _qtyToClaim,
                    "Insufficient tokens in vault to transfer(ERC721)"
                );
                // 'counter' increments with every loop and is then used to return a random ID
                uint256 counter;
                for (uint16 i; i < _qtyToClaim; ++i) {
                    (uint256 tokenId, uint256 counterInc) = randomId(
                        _vaultId,
                        vaultCollections[_vaultId].ownedIds.length,
                        counter
                    );
                    counter += counterInc;
                    vaultCollections[_vaultId].collection721.transferFrom(
                        address(this),
                        _recipient,
                        tokenId
                    );
                }
            }
            if (vaultCollections[_vaultId].itemType == ItemType.ERC1155) {
                uint256 balance = vaultCollections[_vaultId]
                    .collection1155
                    .balanceOf(address(this), vaultCollections[_vaultId].index);
                require(
                    balance >= _qtyToClaim,
                    "Insufficient tokens in vault (ERC1155)"
                );
                vaultCollections[_vaultId].collection1155.safeTransferFrom(
                    address(this),
                    _recipient,
                    vaultCollections[_vaultId].index,
                    _qtyToClaim,
                    ""
                );
            }
            if (vaultCollections[_vaultId].itemType == ItemType.ERC20) {
                uint256 balance = vaultCollections[_vaultId].token20.balanceOf(
                    address(this)
                );
                require(
                    balance >= _qtyToClaim,
                    "Insufficient tokens in vault (ERC20)"
                );
                vaultCollections[_vaultId].token20.safeTransfer(
                    _recipient,
                    _qtyToClaim
                );
            }
            return (totalCost, false);
        }
    }

    /// @notice Used in cases where the assets from a vault collection need to be remove altogther
    function withdrawTokens(
        address _recipient,
        uint256 _erc1155Id,
        uint16 _vaultId,
        uint16 _qty
    ) external onlyOwner {
        if (vaultCollections[_vaultId].itemType == ItemType.ERC721) {
            uint256 balance = vaultCollections[_vaultId]
                .collection721
                .balanceOf(address(this));
            for (uint16 i; i < _qty; ++i) {
                require(
                    balance >= _qty,
                    "Insufficient tokens in vault (ERC721)"
                );
                uint256 len = vaultCollections[_vaultId].ownedIds.length;
                uint256 tokenId = vaultCollections[_vaultId].ownedIds[len - 1];
                vaultCollections[_vaultId].ownedIds.pop();
                vaultCollections[_vaultId].collection721.transferFrom(
                    address(this),
                    _recipient,
                    tokenId
                );
            }
        }
        if (vaultCollections[_vaultId].itemType == ItemType.ERC1155) {
            uint256 balance = vaultCollections[_vaultId]
                .collection1155
                .balanceOf(address(this), _erc1155Id);

            require(balance > 0, "Insufficient tokens in vault (ERC1155)");

            for (uint16 i; i < _qty; ++i) {
                vaultCollections[_vaultId].collection1155.safeTransferFrom(
                    address(this),
                    _recipient,
                    _erc1155Id,
                    1,
                    ""
                );
            }
        }
        if (vaultCollections[_vaultId].itemType == ItemType.ERC20) {
            uint256 balance = vaultCollections[_vaultId].token20.balanceOf(
                address(this)
            );
            require(balance > 0, "Insufficient tokens in vault (ERC20)");
            for (uint16 i; i < _qty; ++i) {
                vaultCollections[_vaultId].token20.safeTransfer(_recipient, 1);
            }
        }
    }
}

interface VaultInterface {
    function transferItems(
        address _recipient,
        uint16 _vaultId,
        uint16 _qtyToClaim,
        uint256 _points,
        uint16 _claimed
    ) external returns (uint256 pointsToRedeem, bool isPhysical);
}

contract StakingManager is Ownable {
    using MerkleProof for bytes32[];

    /// @notice If set to 'Archived', users will not be able to stake, claim or unstake
    enum State {
        Archived,
        Public
    }
    State private _activeState;

    /// @notice A reference to the vault contract that holds store items to claim.
    /// @dev Vault interface contains one funciton that transfers items to eligible claimer upon redeeming points.
    VaultInterface public vault;

    /// @dev Used for comparisons
    enum StakeType {
        ERC721,
        ERC1155,
        ERC20
    }

    /// @dev premiumLevel and secondaryLevel are index references of multipliers for _collections[x].premiumMultipliers[y] and _collections[x].secondaryMultipliers[y]. Uses + 1 for zero comparisons.
    struct PremiumTraitLevels {
        uint16 premiumLevel;
        uint16 secondaryLevel;
    }

    /// @dev Stores staked token ID references on a wallet basis
    struct StakingInfo {
        uint16[] ids;
        uint256 amount; // 1155 or ERC20 balance
        mapping(uint16 => uint256) timestamp;
    }

    /// @dev Collection based info stored with this data structure.
    /// @notice Staker will benefit from additional points if they own an ID with a trait that has been defined as premium. Premium traits are predefined and verified using Merkle Proofs.
    struct CollectionInfo {
        bool isSet;
        IERC721 collection721;
        IERC1155 collection1155;
        IERC20 token20;
        StakeType stakeType;
        uint16 index; // 1155 ID or 721 start index
        bytes32 rootHash;
        uint16 pointMultiplier; // The multiplier for how many points accrued each day.
        mapping(uint16 => PremiumTraitLevels) premiumTrait;
        uint16[] premiumMultipliers; // The multiplier for premium traits added on top 'pointMultiplier'
        uint16[] secondaryMultipliers; // Stackable multiplier like 'Zombie' or others traits
        mapping(address => StakingInfo) stakingInfo;
    }
    mapping(uint16 => CollectionInfo) private _collections;

    /// @notice Claiming address is stored every time a 'PHYSICAL' store item is claimed. Enables iteration of items off chain to award items IRL.
    struct RedeemedInfo {
        address[] redeemer;
        uint16[] qty;
        //uint256[] timestamp;
    }
    /// @dev Mapping key is reference to vault ID
    mapping(uint16 => RedeemedInfo) private _redeemedPhysical;

    /// @dev Points are not stored on-chain but calculated based on a timestamp when staked. When items are claimed, redeemed points are stored in 'pointsRedeemed'. pointsAddOns is used by team to adjust points to stakers. An item ID will be pushed to 'totalItemsClaimed' for every item claimed. Used to limit total amount of store items claimed from a particular vault ID.
    struct UserItems {
        uint256 pointsRedeemed;
        uint256 pointsAfterUnstake;
        uint256 pointsAddOns;
        mapping(uint16 => uint16) totalItemsClaimed; // Vault id/qty
    }
    mapping(address => UserItems) private _userItems;

    // TODO: need final value from team before deployment
    uint256 private _ownerPointsLimit = 50000;

    /// @dev '_pointsAdmin' is an assigned wallet with permissions to add a limited amount of points.
    address private _pointsAdmin;

    /// @dev The limit of points a points admin can add
    uint256 private _maxAddablePoints = 5000;

    constructor() {
        _activeState = State.Archived;
    }

    /// @notice Allows owner to update which vault to use.
    /// @param _vault Is the contract address of the new vault to set.
    function setVault(VaultInterface _vault) external onlyOwner {
        vault = _vault;
    }

    /// @dev Stakable collections set here. isSet created to later turn on/off collection if needed.
    function setERC721Collection(
        uint16 _cid,
        IERC721 _collection721,
        StakeType _type,
        uint16 _index
    ) external onlyOwner {
        _collections[_cid].isSet = true;
        _collections[_cid].collection721 = _collection721;
        _collections[_cid].stakeType = _type;
        _collections[_cid].index = _index;
    }

    function setERC1155Collection(
        uint16 _cid,
        IERC1155 _collection1155,
        StakeType _type,
        uint16 _index
    ) external onlyOwner {
        _collections[_cid].isSet = true;
        _collections[_cid].collection1155 = _collection1155;
        _collections[_cid].stakeType = _type;
        _collections[_cid].index = _index;
    }

    function setERC20Collection(
        uint16 _cid,
        IERC20 _token20,
        StakeType _type
    ) external onlyOwner {
        _collections[_cid].isSet = true;
        _collections[_cid].token20 = _token20;
        _collections[_cid].stakeType = _type;
    }

    /// @dev Combined setter for multipliers/hurdles on a collection basis
    function setPointsMultipliers(
        uint16 _cid,
        uint16 _pointMultiplier,
        uint16[] calldata _premiumMultipliers,
        uint16[] calldata _secondaryMultipliers
    ) external onlyOwner {
        _collections[_cid].pointMultiplier = _pointMultiplier;
        delete _collections[_cid].premiumMultipliers;
        delete _collections[_cid].secondaryMultipliers;
        for (uint16 i; i < _premiumMultipliers.length; ++i) {
            _collections[_cid].premiumMultipliers.push(_premiumMultipliers[i]);
        }
        for (uint16 i; i < _secondaryMultipliers.length; ++i) {
            _collections[_cid].secondaryMultipliers.push(
                _secondaryMultipliers[i]
            );
        }
    }

    /// @dev Defined at the collection level. Also used when periodic updates needed to sets of premium traits.
    function setRootHash(uint16 _cid, bytes32 _rootHash) external onlyOwner {
        _collections[_cid].rootHash = _rootHash;
    }

    /// @dev Override premium traits on an individual basis. Root hash needs to be updated after this has been set.
    function overridePremiumIds(
        uint16 _cid,
        uint16[] calldata _tokenIds,
        uint16[] calldata _premiumMultipliers,
        uint16[] calldata _secondaryMultipliers,
        bytes32 _rootHash
    ) external onlyOwner {
        _collections[_cid].rootHash = _rootHash;
        for (uint16 i; i < _tokenIds.length; ++i) {
            _collections[_cid]
                .premiumTrait[_tokenIds[i]]
                .premiumLevel = _premiumMultipliers[i];
            _collections[_cid]
                .premiumTrait[_tokenIds[i]]
                .secondaryLevel = _secondaryMultipliers[i];
        }
    }

    /// @dev The sole points administrator assigned by the staking system owner. _maxAddablePoints limits points at the staker level.
    function setPointsAdmin(address _newPointsAdmin, uint256 _maxPoints)
        external
        onlyOwner
    {
        _pointsAdmin = _newPointsAdmin;
        _maxAddablePoints = _maxPoints;
    }

    function addPoints(address _staker, uint256 _pointsToAdd) external {
        require(_activeState == State.Public, "Staking system inactive");
        require(msg.sender == _pointsAdmin, "Not authorized");
        require(
            _pointsToAdd + _userItems[_staker].pointsAddOns <=
                _maxAddablePoints,
            "Exceeds max points addable to this address"
        );
        _userItems[_staker].pointsAddOns += _pointsToAdd;
    }

    /// @dev Owner fn to add points to staker on pointsAddOns
    function ownerAddPoints(
        address[] calldata _staker,
        uint256[] calldata _pointsToAdd
    ) external onlyOwner {
        for (uint16 i; i < _staker.length; ++i) {
            require(
                _pointsToAdd[i] <= _ownerPointsLimit,
                "Exceeds points added per tx"
            );
            _userItems[_staker[i]].pointsAddOns += _pointsToAdd[i];
        }
    }

    /// @notice Used by owner in case of error after adding points to pointsAddOns
    function removePointsAddOns(address _staker, uint256 _pointsToRemove)
        external
        onlyOwner
    {
        require(
            _pointsToRemove <= _userItems[_staker].pointsAddOns,
            "Exceeds points currently in pointsAddOns"
        );
        _userItems[_staker].pointsAddOns -= _pointsToRemove;
    }

    /// @notice Used by owner in case of error or migration
    function removePoints(address _staker, uint256 _pointsToRemove)
        external
        onlyOwner
    {
        require(
            _pointsToRemove <= _ownerPointsLimit,
            "Exceeds points removed per tx"
        );
        _userItems[_staker].pointsRedeemed += _pointsToRemove;
    }

    function verifyTrait(
        bytes32 _rootHash,
        uint16 _tokenId,
        uint16 _premiumLevel,
        uint16 _secondaryLevel,
        bytes32[] calldata _proofs
    ) internal pure returns (bool) {
        return
            _proofs.verifyCalldata(
                _rootHash,
                keccak256(
                    abi.encodePacked(
                        uint256(_tokenId),
                        uint256(_premiumLevel),
                        uint256(_secondaryLevel)
                    )
                )
            );
    }

    /// @notice Staking function for multiple collections.
    function stakeMultiple(
        uint16[] calldata _collectionIds,
        uint16[][] calldata _tokenIds,
        uint16[][] calldata _premiumMultipliers,
        uint16[][] calldata _secondaryMultipliers,
        bytes32[][][] calldata _proofs
    ) external {
        require(_activeState == State.Public, "Staking system inactive");
        for (uint16 i; i < _collectionIds.length; ++i) {
            uint16 cid = _collectionIds[i];
            StakeType stakeType = _collections[cid].stakeType;
            if (
                (_collections[cid].isSet && stakeType == StakeType.ERC1155) ||
                (_collections[cid].isSet && stakeType == StakeType.ERC20)
            ) {
                uint256 balance;
                uint256 amount = _tokenIds[i][0];

                if (stakeType == StakeType.ERC1155) {
                    balance = _collections[cid].collection1155.balanceOf(
                        msg.sender,
                        _collections[cid].index
                    );
                } else {
                    balance = _collections[cid].token20.balanceOf(msg.sender);
                }
                require(balance >= amount, "Not owner (non 721)");
                require(
                    _collections[cid].stakingInfo[msg.sender].timestamp[0] == 0,
                    "Already staked (non 721)"
                );
                _collections[cid].stakingInfo[msg.sender].amount = amount;
                _collections[cid].stakingInfo[msg.sender].timestamp[0] = block
                    .timestamp;
            }
            if (_collections[cid].isSet && stakeType == StakeType.ERC721) {
                for (uint16 j; j < _tokenIds[i].length; ++j) {
                    uint16 tokenId = _tokenIds[i][j];
                    require(
                        _collections[cid].stakingInfo[msg.sender].timestamp[
                            tokenId
                        ] == 0,
                        "Already staked (721)"
                    );
                    require(
                        _collections[cid].collection721.ownerOf(tokenId) ==
                            msg.sender,
                        "Not owner (721)"
                    );
                    if (
                        _proofs[i].length != 0 &&
                        verifyTrait(
                            _collections[cid].rootHash,
                            tokenId,
                            _premiumMultipliers[i][j],
                            _secondaryMultipliers[i][j],
                            _proofs[i][j]
                        )
                    ) {
                        _collections[cid]
                            .premiumTrait[tokenId]
                            .premiumLevel = _premiumMultipliers[i][j];
                        _collections[cid]
                            .premiumTrait[tokenId]
                            .secondaryLevel = _secondaryMultipliers[i][j];
                    }

                    _collections[cid].stakingInfo[msg.sender].ids.push(tokenId);
                    _collections[cid].stakingInfo[msg.sender].timestamp[
                        tokenId
                    ] = block.timestamp;
                }
            }
        }
    }

    /// @notice _unStake and _adminUnstake use this fn to unstake.
    function unstakeTokens(
        address _staker,
        uint16[] calldata _collectionIds,
        uint16[][] calldata _idsToUnstake
    ) internal {
        require(_activeState == State.Public, "Staking system inactive");
        for (uint16 i; i < _collectionIds.length; ++i) {
            uint16 cid = _collectionIds[i];
            if (
                _collections[cid].isSet &&
                _collections[cid].stakeType == StakeType.ERC721
            ) {
                uint256 idsLength = _collections[cid]
                    .stakingInfo[_staker]
                    .ids
                    .length;
                uint256 unstakeLength = _idsToUnstake[i].length;
                require(
                    unstakeLength <= idsLength,
                    "Unstaking more ID's than staker owns"
                );
                for (uint16 j; j < unstakeLength; ++j) {
                    uint16 tokenId = _idsToUnstake[i][j];
                    for (uint16 k; k < idsLength; ++k) {
                        // Check if ID is still in staker's ID's array
                        if (
                            _collections[cid].stakingInfo[_staker].ids[k] ==
                            tokenId
                        ) {
                            // Check if staker is original owner since mapping key is token ID
                            require(
                                _collections[cid]
                                    .stakingInfo[_staker]
                                    .timestamp[tokenId] > 1666000000,
                                "Not owner of token (unstake)"
                            );
                            _userItems[_staker].pointsAfterUnstake += getPoint(
                                _staker,
                                cid,
                                tokenId
                            );
                            delete _collections[cid]
                                .stakingInfo[_staker]
                                .timestamp[tokenId];
                            if (unstakeLength == idsLength && idsLength == 1) {
                                delete _collections[cid]
                                    .stakingInfo[_staker]
                                    .ids;
                            } else if (j < idsLength) {
                                // Move selected ID to end of array and remove it
                                _collections[cid].stakingInfo[_staker].ids[
                                        j
                                    ] = _collections[cid]
                                    .stakingInfo[_staker]
                                    .ids[idsLength - 1];
                                _collections[cid].stakingInfo[_staker].ids.pop();
                            }
                            // Decrement length of loop for every token unstaked
                            idsLength--;
                        }
                    }
                }
            }
            if (
                (_collections[cid].isSet &&
                    _collections[cid].stakeType == StakeType.ERC1155) ||
                (_collections[cid].isSet &&
                    _collections[cid].stakeType == StakeType.ERC20)
            ) {
                require(
                    _collections[cid].stakingInfo[_staker].amount > 0,
                    "Not staked (non 721)"
                );
                _userItems[_staker].pointsAfterUnstake += getNon721Points(
                    _staker,
                    cid
                );
                _collections[cid].stakingInfo[_staker].amount = 0;
                _collections[cid].stakingInfo[_staker].timestamp[0] = 0;
            }
        }
    }

    /// @notice Allows staker to unstake their assets.
    function unStake(
        uint16[] calldata _collectionIds,
        uint16[][] calldata _tokenIds
    ) external {
        unstakeTokens(msg.sender, _collectionIds, _tokenIds);
    }

    /// @dev Used in the event of migration
    function adminUnstake(
        address _staker,
        uint16[] calldata _collectionIds,
        uint16[][] calldata _tokenIds
    ) external onlyOwner {
        unstakeTokens(_staker, _collectionIds, _tokenIds);
    }

    function getCollectionInfo(uint16 _cid)
        external
        view
        returns (
            bool,
            StakeType,
            bytes32,
            uint16[] memory,
            uint16[] memory,
            uint16[] memory
        )
    {
        uint16[] memory grouped = new uint16[](2);
        grouped[0] = _collections[_cid].index;
        grouped[1] = _collections[_cid].pointMultiplier;
        return (
            _collections[_cid].isSet,
            _collections[_cid].stakeType,
            _collections[_cid].rootHash,
            _collections[_cid].premiumMultipliers,
            _collections[_cid].secondaryMultipliers,
            grouped
        );
    }

    function getCollectionAddresses(uint16 _cid)
        external
        view
        returns (
            IERC721,
            IERC1155,
            IERC20
        )
    {
        return (
            _collections[_cid].collection721,
            _collections[_cid].collection1155,
            _collections[_cid].token20
        );
    }

    function getTokenIdLevels(uint16 _cid, uint16 _tokenId)
        external
        view
        returns (
            //uint256,
            uint16,
            uint16
        )
    {
        return (
            // _collections[_cid].stakingInfo[_tokenId].timestamp,
            _collections[_cid].premiumTrait[_tokenId].premiumLevel,
            _collections[_cid].premiumTrait[_tokenId].secondaryLevel
        );
    }

    function getStakingInfo(uint16 _cid, address _staker)
        external
        view
        returns (
            uint256 pointsAfterUnstake,
            uint16[] memory ids,
            uint256 amount,
            uint256[] memory
        )
    {
        uint256 idsLength = _collections[_cid].stakingInfo[_staker].ids.length;
        uint256[] memory timestamps = new uint256[](idsLength);
        for (uint16 i; i < idsLength; ++i) {
            uint16 tokenId = _collections[_cid].stakingInfo[_staker].ids[i];
            timestamps[i] = _collections[_cid].stakingInfo[_staker].timestamp[
                tokenId
            ];
        }
        return (
            _userItems[_staker].pointsAfterUnstake,
            _collections[_cid].stakingInfo[_staker].ids,
            _collections[_cid].stakingInfo[_staker].amount,
            timestamps
        );
    }

    function getTotalItemsClaimed(address _staker, uint16 _vid)
        external
        view
        returns (uint16)
    {
        return _userItems[_staker].totalItemsClaimed[_vid];
    }

    function getRedeemedPhysical(uint16 _vid)
        external
        view
        returns (
            address[] memory redeemer,
            uint16[] memory qty /*,
            uint256[] memory timestamp*/
        )
    {
        return (
            _redeemedPhysical[_vid].redeemer,
            _redeemedPhysical[_vid].qty /*,
            _redeemedPhysical[_vid].timestamp*/
        );
    }

    function getPointsAdmin()
        external
        view
        onlyOwner
        returns (address, uint256)
    {
        return (_pointsAdmin, _maxAddablePoints);
    }

    /// @notice Called when user with staked assets (Staker) intends to claim an item from the store (vault). Points used here are stored in _userItems.pointsRedeemed and later deducted from future points calculations.
    /// @dev Staker can claim multiple items from multiple collections at once.
    /// @param _vaultCollectionIds Array of collection indexes.
    /// @param _qtysToClaim Amount of a particular vault item a staker wishes to claim. Index of this array must match index of '_vaultCollectionIds' array.
    /// @param _collectionIds Stakabale collections to calculate points from
    function claimItems(
        uint16[] calldata _vaultCollectionIds,
        uint16[] calldata _qtysToClaim,
        uint16[] calldata _collectionIds
    ) external {
        require(_activeState == State.Public, "Staking system inactive");
        require(_qtysToClaim.length > 0, "Must claim more than 0 qty");
        // Use pointsToRedeem to calculate required points to claim total requested items from marketpalce.
        uint256 pointsToRedeem;
        uint256 points = getPoints(msg.sender, _collectionIds, true);
        require(points > 0, "No points");

        // Loop through each vault collection user wants to claim from.
        for (uint16 i; i < _vaultCollectionIds.length; ++i) {
            uint16 q = _qtysToClaim[i];
            require(
                q > 0 && _qtysToClaim.length > 0,
                "Must claim more than 0 qty"
            );
            uint16 vc = _vaultCollectionIds[i];
            bool isPhysical;
            uint256 usedPoints;
            uint16 totalClaimed = _userItems[msg.sender].totalItemsClaimed[vc];
            _userItems[msg.sender].totalItemsClaimed[vc] += q;

            (usedPoints, isPhysical) = vault.transferItems(
                msg.sender,
                vc,
                q,
                points,
                totalClaimed
            );
            pointsToRedeem += usedPoints;

            // If item is physical/virtual, use _redeemedPhysical to access data off chain
            if (isPhysical) {
                _redeemedPhysical[vc].redeemer.push(msg.sender);
                _redeemedPhysical[vc].qty.push(_qtysToClaim[i]);
                //_redeemedPhysical[vc].timestamp.push(block.timestamp);
            }
        }
        require(pointsToRedeem <= points, "Insufficient points");
        // Store points redeemed from claiming to subtract from further points calculations
        _userItems[msg.sender].pointsRedeemed += pointsToRedeem;
    }

    /// @dev Get points for specific token ID and called when getting all points for a staker
    function getPoint(
        address _staker,
        uint16 _cid,
        uint16 _tokenId
    ) internal view returns (uint256 points) {
        uint256 pointsDiff;
        if (
            _collections[_cid].stakingInfo[_staker].timestamp[_tokenId] >
            1672560000
        ) {
            pointsDiff =
                (block.timestamp -
                    _collections[_cid].stakingInfo[_staker].timestamp[
                        _tokenId
                    ]) /
                1 days;

            // Used to suppress multiplication on result of a division warning
            uint256 pointsDiffCalc = 0 + pointsDiff;
            uint16 premiumBonus;
            uint16 secondaryBonus;

            if (_collections[_cid].premiumTrait[_tokenId].premiumLevel > 0) {
                uint16 level = _collections[_cid]
                    .premiumTrait[_tokenId]
                    .premiumLevel - 1;
                premiumBonus = _collections[_cid].premiumMultipliers[level];
            }

            if (_collections[_cid].premiumTrait[_tokenId].secondaryLevel > 0) {
                uint16 level = _collections[_cid]
                    .premiumTrait[_tokenId]
                    .secondaryLevel - 1;
                secondaryBonus = _collections[_cid].secondaryMultipliers[level];
            }

            // If premium trait found, add the premium point multiplier to the original multiplier before calculating the daily total
            points +=
                pointsDiffCalc *
                (_collections[_cid].pointMultiplier +
                    premiumBonus +
                    secondaryBonus);
        }
        return points;
    }

    function getNon721Points(address _staker, uint16 _cid)
        internal
        view
        returns (uint256 points)
    {
        if (_collections[_cid].stakingInfo[_staker].timestamp[0] > 1666000000) {
            uint256 pointsDiff = (block.timestamp -
                _collections[_cid].stakingInfo[_staker].timestamp[0]) / 1 days;

            // Used to suppress multiplication on result of a division warning
            uint256 pointsDiffCalc = 0 + pointsDiff;

            return
                (pointsDiffCalc * _collections[_cid].pointMultiplier) *
                _collections[_cid].stakingInfo[_staker].amount;
        }
        return 0;
    }

    /// @notice Returns points calculated for specified collections for a particular user.
    function getPoints(
        address _staker,
        uint16[] calldata _collectionIds,
        bool _verifyOwnership
    ) public view returns (uint256 points) {
        for (uint16 i; i < _collectionIds.length; ++i) {
            uint16 cid = _collectionIds[i];
            if (
                _collections[cid].isSet &&
                _collections[cid].stakeType == StakeType.ERC721 &&
                _collections[cid].stakingInfo[_staker].ids.length > 0
            ) {
                for (
                    uint256 j;
                    j < _collections[cid].stakingInfo[_staker].ids.length;
                    ++j
                ) {
                    uint16 tokenId = _collections[cid].stakingInfo[_staker].ids[
                        j
                    ];

                    if (_verifyOwnership) {
                        address tokenOwner = _collections[cid]
                            .collection721
                            .ownerOf(tokenId);
                        require(tokenOwner == _staker, "Not owner (ERC721)");
                    }
                    //if (tokenOwner == _staker) {
                    points += getPoint(_staker, cid, tokenId);
                    //}
                }
            }
            if (
                _collections[cid].isSet &&
                _collections[cid].stakeType == StakeType.ERC1155 &&
                _collections[cid].stakingInfo[_staker].amount > 0
            ) {
                if (_verifyOwnership) {
                    require(
                        (_collections[cid].collection1155.balanceOf(
                            _staker,
                            _collections[cid].index
                        ) >= _collections[cid].stakingInfo[_staker].amount),
                        "Not owner (ERC1155)"
                    );
                }
                points += getNon721Points(_staker, cid);
            }
            if (
                _collections[cid].isSet &&
                _collections[cid].stakeType == StakeType.ERC20 &&
                _collections[cid].stakingInfo[_staker].amount > 0
            ) {
                if (_verifyOwnership) {
                    require(
                        (_collections[cid].token20.balanceOf(_staker) >=
                            _collections[cid].stakingInfo[_staker].amount),
                        "Not owner (ERC20)"
                    );
                }
                points += getNon721Points(_staker, cid);
            }
        }
        points += _userItems[_staker].pointsAddOns;
        points += _userItems[_staker].pointsAfterUnstake;
        if (points < _userItems[_staker].pointsRedeemed) {
            return 0;
        } else {
            return points - _userItems[_staker].pointsRedeemed;
        }
    }

    function getState() external view returns (State) {
        return _activeState;
    }

    function setStateToPublic() external onlyOwner {
        _activeState = State.Public;
    }

    function setStateToArchived() external onlyOwner {
        _activeState = State.Archived;
    }
}
