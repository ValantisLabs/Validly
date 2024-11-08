// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISovereignALM} from "@valantis-core/ALM/interfaces/ISovereignALM.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";

interface IValidly is ISovereignALM {
    event Deposit(address sender, address recipient, uint256 amount0, uint256 amount1, uint256 shares);

    event Withdraw(address sender, address recipient, uint256 amount0, uint256 amount1, uint256 shares);

    function MINIMUM_LIQUIDITY() external view returns (uint256);

    function INVARIANT_CACHE_SLOT() external view returns (bytes32);

    function pool() external view returns (ISovereignPool);

    function isStable() external view returns (bool);

    function decimals0() external view returns (uint256);

    function decimals1() external view returns (uint256);

    function deposit(
        uint256 _amount0,
        uint256 _amount1,
        uint256 _minShares,
        uint256 _deadline,
        address _recipient,
        bytes calldata _verificationContext
    ) external returns (uint256 shares, uint256 amount0, uint256 amount1);

    function withdraw(
        uint256 _shares,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint256 _deadline,
        address _recipient,
        bytes calldata _verificationContext
    ) external returns (uint256 amount0, uint256 amount1);
}
