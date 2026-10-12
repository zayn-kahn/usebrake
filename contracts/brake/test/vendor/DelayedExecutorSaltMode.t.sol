// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC7579DelayedExecutor} from "../../src/vendor/ERC7579DelayedExecutor.sol";
import {DemoAccount} from "../../src/demo/DemoAccount.sol";

contract DelayedExecutorMock is ERC7579DelayedExecutor {
    function _validateSchedule(address account, bytes32, bytes32, bytes calldata) internal view override {
        require(msg.sender == account);
    }

    function _validateCancel(address account, bytes32, bytes32, bytes calldata) internal view override {
        require(msg.sender == account);
    }
}

/// @dev Regression for OpenZeppelin/openzeppelin-community-contracts#292: upstream `execute`
/// passes (mode, salt) into an override declared (salt, mode), so ops with salt != mode never run.
contract DelayedExecutorSaltModeTest is Test {
    DelayedExecutorMock module;
    DemoAccount account;
    address recipient = makeAddr("recipient");
    bytes32 constant MODE_SINGLE = bytes32(0);
    bytes data;

    function setUp() public {
        module = new DelayedExecutorMock();
        account = new DemoAccount(address(this));
        vm.deal(address(account), 10 ether);
        account.installExecutor(address(module), abi.encode(uint32(1 days), uint32(7 days)));
        data = abi.encodePacked(recipient, uint256(1 ether), bytes(""));
    }

    function test_executeWithNonZeroSalt() public {
        bytes32 salt = keccak256("any non-zero salt");
        account.call(address(module), abi.encodeCall(module.schedule, (address(account), salt, MODE_SINGLE, data)));
        vm.warp(block.timestamp + 1 days);

        module.execute(address(account), salt, MODE_SINGLE, data);

        assertEq(recipient.balance, 1 ether);
    }
}
