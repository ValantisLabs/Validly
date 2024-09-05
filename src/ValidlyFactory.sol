// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolFactory} from "@valantis-core/protocol-factory/interfaces/IProtocolFactory.sol";
import {SovereignPoolConstructorArgs} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";

import {Validly} from "src/Validly.sol";

contract ValidlyFactory {
    using SafeERC20 for IERC20;

    /**
     *  EVENTS
     */
    event FeesClaimed(address indexed pool);
    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, bool isStable);
    event PoolManagerFeeBipsSet(address indexed pool, uint256 feeBips);
    event TokenClaimed(address indexed token, address indexed recipient, uint256 amount);

    /**
     *  ERRORS
     */
    error ValidlyFactory__onlyProtocolManager();
    error ValidlyFactory__claimTokens_invalidRecipient();
    error ValidlyFactory__claimTokens_invalidToken();
    error ValidlyFactory__constructor_invalidFeeBips();
    error ValidlyFactory__createPair_alreadyDeployed();
    error ValidlyFactory__setPoolManagerFees_unauthorized();

    /**
     *  IMMUTABLES
     */

    /**
     * @notice The protocol factory contract used for deploying pools.
     * @dev This is set in the constructor and cannot be changed.
     */
    IProtocolFactory public immutable protocolFactory;

    /**
     * @notice The fee percentage for the Validly pool.
     * @dev This is set in the constructor and cannot be changed.
     * @dev If new pool fee tiers are required, one can deploy new Validly factories.
     */
    uint256 public immutable feeBips;

    /**
     *  STORAGE
     */

    /**
     * @notice Mapping from pool keys to pool addresses.
     */
    mapping(bytes32 key => address pool) public pools;

    /**
     *  CONSTRUCTOR
     */
    constructor(address _protocolFactory, uint256 _feeBips) {
        protocolFactory = IProtocolFactory(_protocolFactory);

        if (_feeBips == 0 || _feeBips > 10000) {
            revert ValidlyFactory__constructor_invalidFeeBips();
        }

        feeBips = _feeBips;
    }

    /**
     *
     *  MODIFIERS
     *
     */
    modifier onlyProtocolManager() {
        if (msg.sender != protocolFactory.protocolManager()) {
            revert ValidlyFactory__onlyProtocolManager();
        }
        _;
    }

    /**
     *  EXTERNAL FUNCTIONS
     */

    /**
     * @notice Deploys a new Validly pool for a given token pair.
     * @dev Tokens are sorted internally to ensure consistent pool keys.
     * @param _token0 The address of the first token in the pair.
     * @param _token1 The address of the second token in the pair.
     * @param _isStable Boolean indicating if the pool should be stable or volatile.
     * @custom:error ValidlyFactory__createPair_alreadyDeployed Thrown if a pool for the given token pair and stability type already exists.
     * @custom:error ValidlyFactory__createPair_failedDeployment Thrown if the Validly contract deployment fails.
     * @custom:error ValidlyFactory__createPair_invalidFeeBips Thrown if the feeBips is not between 0 and 10000.
     */
    function createPair(address _token0, address _token1, bool _isStable) external returns (address) {
        (_token0, _token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);

        bytes32 poolKey = _poolKey(_token0, _token1, _isStable);

        if (pools[poolKey] != address(0)) {
            revert ValidlyFactory__createPair_alreadyDeployed();
        }

        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs(
            _token0,
            _token1,
            address(protocolFactory),
            address(this),
            address(0),
            address(0),
            false,
            false,
            0,
            0,
            feeBips
        );

        address pool = protocolFactory.deploySovereignPool(args);

        Validly validly = new Validly(pool, _isStable);

        ISovereignPool(pool).setALM(address(validly));

        pools[poolKey] = pool;

        emit PoolCreated(pool, _token0, _token1, _isStable);

        return address(validly);
    }

    /**
     * @notice Creates a new Validly pool, mostly for rebase tokens, which is not indexed in pools mapping.
     * @dev This function is used to create a pool given the SovereignPool constructor arguments.
     * @param _args The constructor arguments for the SovereignPool.
     * @param _isStable Boolean indicating if the pool should be stable or volatile.
     * @custom:error ValidlyFactory__createPool_failedDeployment Thrown if the Validly contract deployment fails.
     */
    function createPool(SovereignPoolConstructorArgs memory _args, bool _isStable) external returns (address validly) {
        _args.poolManager = address(this);

        address pool = protocolFactory.deploySovereignPool(_args);

        validly = address(new Validly(pool, _isStable));

        ISovereignPool(pool).setALM(address(validly));

        emit PoolCreated(pool, _args.token0, _args.token1, _isStable);
    }

    /**
     * @notice Sets the pool manager fees for a given pool.
     * @dev This function is used to set the pool manager fees for a given pool.
     * @param _pool The address of the pool to set the pool manager fees for.
     * @param _feeBips The fee percentage for the pool manager.
     * @custom:error ValidlyFactory__setPoolManagerFees_unauthorized Thrown if the caller is not the protocol manager.
     */
    function setPoolManagerFeeBips(address _pool, uint256 _feeBips) external onlyProtocolManager {
        ISovereignPool(_pool).setPoolManagerFeeBips(_feeBips);

        emit PoolManagerFeeBipsSet(_pool, _feeBips);
    }

    /**
     * @notice Claims rebase token fees accumulated in this contract.
     * @dev By design of Sovereign Pools, manager fees for rebase tokens
     *      get transferred on every swap to its manager (this contract).
     * @param _token The address of the token to claim.
     * @param _recipient The address of the recipient.
     */
    function claimTokens(address _token, address _recipient) external onlyProtocolManager {
        if (_token == address(0)) {
            revert ValidlyFactory__claimTokens_invalidToken();
        }
        if (_recipient == address(0)) {
            revert ValidlyFactory__claimTokens_invalidRecipient();
        }

        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));

        if (balance > 0) {
            token.safeTransfer(_recipient, balance);

            emit TokenClaimed(_token, _recipient, balance);
        }
    }

    /**
     * @notice Claims the pool manager fees for a given pool.
     * @dev This function is used to claim the pool manager fees for a given pool.
     * @param _pool The address of the pool to claim the pool manager fees for.
     */
    function claimFees(address _pool) external {
        // It marks all fees as protocol fees to be used by gauge
        ISovereignPool(_pool).claimPoolManagerFees(10_000, 10_000);

        emit FeesClaimed(_pool);
    }

    /**
     *  PRIVATE FUNCTIONS
     */
    function _poolKey(address token0, address token1, bool isStable) private pure returns (bytes32 key) {
        key = keccak256(abi.encode(token0, token1, isStable));
    }
}
