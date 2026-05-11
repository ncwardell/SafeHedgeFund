// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Gnosis Safe stand-in for module-call tests.
/// Mirrors the two interfaces SafeHedgeFundVault depends on:
///   - isModuleEnabled(address) view returns (bool)
///   - execTransactionFromModule(address,uint256,bytes,uint8) returns (bool)
contract MockSafe {
    mapping(address => bool) private _enabledModules;

    event ModuleEnabled(address indexed module);
    event ModuleDisabled(address indexed module);

    function enableModule(address module) external {
        _enabledModules[module] = true;
        emit ModuleEnabled(module);
    }

    function disableModule(address module) external {
        _enabledModules[module] = false;
        emit ModuleDisabled(module);
    }

    function isModuleEnabled(address module) external view returns (bool) {
        return _enabledModules[module];
    }

    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 /* operation: 0=Call, 1=DelegateCall — only Call supported here */
    ) external returns (bool success) {
        require(_enabledModules[msg.sender], "MockSafe: module not enabled");
        (success,) = to.call{value: value}(data);
    }

    receive() external payable {}
}
