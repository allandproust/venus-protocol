pragma solidity ^0.5.16;
import "../Utils/SafeMath.sol";
import "../Utils/IBEP20.sol";

contract XVSVaultAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of XVS Vault
    */
    address public xvsVaultImplementation;

    /**
    * @notice Pending brains of XVS Vault
    */
    address public pendingXVSVaultImplementation;
}

contract XVSVaultStorage is XVSVaultAdminStorage {
    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice The reward token store
    address public xvsStore;

    /// @notice The xvs token address
    address public xvsAddress;

    // Reward tokens created per block indentified by reward token address.
    mapping(address => uint256) public rewardTokenAmountsPerBlock;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 token;             // Address of token contract to stake.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardBlock; // Last block number that reward tokens distribution occurs.
        uint256 accRewardPerShare;   // Accumulated per share, times 1e12. See below.
    }

    // Info of each user that stakes tokens.
    mapping(address => mapping(uint256 => mapping(address => UserInfo))) userInfos;

    // Info of each pool.
    mapping(address => PoolInfo[]) public poolInfos;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    mapping(address => uint256) public totalAllocPoints;
}
