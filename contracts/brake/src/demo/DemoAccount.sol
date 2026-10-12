// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC7579Utils, Mode, CallType} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {IERC7579Module, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @dev Minimal ERC-7579 account for tests and the local demo: one executor module, single-call
/// execution only. `owner` stands in for the account's validator key. Not for real funds.
contract DemoAccount {
    address public owner;
    address public executor;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    receive() external payable {}

    /// @dev Lets a setup contract build the account and then hand it to its real owner.
    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function installExecutor(address module, bytes calldata initData) external onlyOwner {
        executor = module;
        IERC7579Module(module).onInstall(initData);
    }

    function uninstallExecutor(bytes calldata deInitData) external onlyOwner {
        IERC7579Module(executor).onUninstall(deInitData);
        executor = address(0);
    }

    function isModuleInstalled(uint256 typeId, address module, bytes calldata) external view returns (bool) {
        return typeId == MODULE_TYPE_EXECUTOR && module == executor;
    }

    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata) external returns (bytes[] memory) {
        require(msg.sender == executor, "not executor");
        (CallType callType, , , ) = ERC7579Utils.decodeMode(Mode.wrap(mode));
        require(CallType.unwrap(callType) == CallType.unwrap(ERC7579Utils.CALLTYPE_SINGLE), "unsupported call type");
        (address target, uint256 value, bytes calldata data) = ERC7579Utils.decodeSingle(executionCalldata);
        bytes[] memory out = new bytes[](1);
        bool ok;
        (ok, out[0]) = target.call{value: value}(data);
        require(ok, "call failed");
        return out;
    }

    /// @dev The owner acts as the account: `account.call(module, ...)`.
    function call(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
        return ret;
    }
}
