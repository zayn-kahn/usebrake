// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccountERC7579} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {
    Execution,
    IERC7579Module,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Brake} from "../src/Brake.sol";

/// @dev OpenZeppelin's ERC-7579 account, as a real account would be: it runs a zero target as a call
/// to itself, keeps its signer in a validator module, and executes batches.
contract OZAccount is AccountERC7579 {}

/// @dev A validator module in the shape of Nexus's K1Validator or Rhinestone's OwnableValidator: the
/// account's signer lives here, keyed by msg.sender, and the account changes it by calling the module.
contract MockValidator is IERC7579Module {
    mapping(address account => address) public ownerOf;

    function onInstall(bytes calldata data) external {
        ownerOf[msg.sender] = abi.decode(data, (address));
    }

    function onUninstall(bytes calldata) external {
        delete ownerOf[msg.sender];
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    function transferOwnership(address newOwner) external {
        ownerOf[msg.sender] = newOwner;
    }
}

/// @dev Brake on a real ERC-7579 account: the refusals that a toy account cannot show.
contract BrakeAccountsTest is Test {
    Brake brake;
    OZAccount oz;
    MockValidator validator;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address phone = makeAddr("phone");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");

    bytes32 constant MODE_SINGLE = bytes32(0);
    bytes32 constant MODE_BATCH = bytes32(bytes1(0x01));
    uint32 constant QUEUE_DELAY = 1 hours;
    uint32 constant EXPIRATION = 7 days;
    uint32 constant MAX_HOLD = 6 hours;

    function setUp() public {
        vm.warp(1_800_000_000);
        brake = new Brake();
        oz = new OZAccount();
        validator = new MockValidator();
        vm.deal(address(oz), 10 ether);

        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory brakes = new address[](1);
        brakes[0] = phone;
        bool[] memory canCancel = new bool[](1);
        canCancel[0] = true;
        address[] memory capTokens = new address[](1);
        uint128[] memory caps = new uint128[](1);
        caps[0] = 0.1 ether;
        bytes memory cfg = abi.encode(
            Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, drivers, brakes, canCancel, capTokens, caps)
        );
        // The account installs its own modules (OZ: onlyEntryPointOrSelf).
        vm.startPrank(address(oz));
        oz.installModule(MODULE_TYPE_VALIDATOR, address(validator), abi.encode(owner));
        oz.installModule(MODULE_TYPE_EXECUTOR, address(brake), cfg);
        vm.stopPrank();
        assertTrue(brake.isInstalled(address(oz)));
        assertEq(validator.ownerOf(address(oz)), owner);
    }

    function _send(address to, uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(to, value, bytes(""));
    }

    function _call(address target, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, uint256(0), callData);
    }

    // ---------------------------------------------------------------- it works on a real account

    function test_queuedPaymentExecutesOnTheAccount() public {
        bytes memory data = _send(friend, 1 ether);
        vm.prank(agent);
        (, Brake.Lane lane) = brake.propose(address(oz), keccak256("x"), MODE_SINGLE, data, "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(oz), keccak256("x"), MODE_SINGLE, data);
        assertEq(friend.balance, 1 ether);
    }

    function test_queuedBatchExecutesOnTheAccount() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(friend, 0.3 ether, "");
        calls[1] = Execution(friend, 0.2 ether, "");
        bytes memory data = ERC7579Utils.encodeBatch(calls);
        vm.prank(agent);
        brake.propose(address(oz), keccak256("b"), MODE_BATCH, data, "");
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(oz), keccak256("b"), MODE_BATCH, data);
        assertEq(friend.balance, 0.5 ether);
    }

    function test_instantPaymentWorksOnTheAccount() public {
        vm.prank(address(oz));
        brake.setTrusted(address(oz), friend, true);
        vm.prank(agent);
        (, Brake.Lane lane) = brake.propose(address(oz), keccak256("i"), MODE_SINGLE, _send(friend, 0.05 ether), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Instant));
        assertEq(friend.balance, 0.05 ether);
    }

    // ---------------------------------------------------------------- the zero target is the account

    function test_zeroTargetUninstallIsRefused() public {
        bytes memory data = _call(address(0), abi.encodeCall(oz.uninstallModule, (MODULE_TYPE_EXECUTOR, address(brake), "")));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.propose(address(oz), keccak256("u"), MODE_SINGLE, data, "");
    }

    function test_zeroTargetInstallValidatorIsRefused() public {
        MockValidator evil = new MockValidator();
        bytes memory data =
            _call(address(0), abi.encodeCall(oz.installModule, (MODULE_TYPE_VALIDATOR, address(evil), abi.encode(attacker))));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.propose(address(oz), keccak256("v"), MODE_SINGLE, data, "");
    }

    function test_zeroTargetNestedExecuteIsRefused() public {
        bytes memory inner = _call(address(brake), abi.encodeCall(brake.setTrusted, (address(oz), attacker, true)));
        bytes memory data = _call(address(0), abi.encodeCall(oz.execute, (MODE_SINGLE, inner)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.propose(address(oz), keccak256("n"), MODE_SINGLE, data, "");
    }

    function test_zeroTargetInsideABatchIsRefused() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(friend, 0.01 ether, "");
        calls[1] = Execution(address(0), 0, abi.encodeCall(oz.uninstallModule, (MODULE_TYPE_EXECUTOR, address(brake), "")));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.propose(address(oz), keccak256("bz"), MODE_BATCH, ERC7579Utils.encodeBatch(calls), "");
    }

    function test_previewRefusesTheZeroTargetToo() public {
        bytes memory data = _call(address(0), abi.encodeCall(oz.uninstallModule, (MODULE_TYPE_EXECUTOR, address(brake), "")));
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.preview(address(oz), MODE_SINGLE, data);
    }

    // ---------------------------------------------------------------- installed modules hold the rules too

    function test_queuedCallToTheValidatorIsRefused() public {
        bytes memory data = _call(address(validator), abi.encodeCall(validator.transferOwnership, (attacker)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(validator)));
        brake.propose(address(oz), keccak256("t"), MODE_SINGLE, data, "rotate signer");
        assertEq(validator.ownerOf(address(oz)), owner);
    }

    function test_queuedCallToBrakeIsRefusedHereToo() public {
        bytes memory data = _call(address(brake), abi.encodeCall(brake.setTrusted, (address(oz), attacker, true)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(oz), keccak256("s"), MODE_SINGLE, data, "");
    }

    function test_aModuleNotInstalledOnThisAccountIsAnOrdinaryTarget_untilProtected() public {
        MockValidator elsewhere = new MockValidator(); // some other account's validator
        bytes memory data = _call(address(elsewhere), abi.encodeCall(elsewhere.transferOwnership, (attacker)));
        vm.prank(agent);
        (, Brake.Lane lane) = brake.propose(address(oz), keccak256("e"), MODE_SINGLE, data, "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        vm.prank(address(oz));
        brake.setProtected(address(oz), address(elsewhere), true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(elsewhere)));
        brake.propose(address(oz), keccak256("f"), MODE_SINGLE, data, "");
    }

    // ---------------------------------------------------------------- the owner still changes the rules directly

    function test_theAccountItselfChangesTheRulesWithoutTheQueue() public {
        vm.startPrank(address(oz));
        brake.setTrusted(address(oz), friend, true);
        brake.setDriver(address(oz), attacker, false);
        brake.setBrake(address(oz), friend, true, false);
        vm.stopPrank();
        assertTrue(brake.isKnownRecipient(address(oz), friend));
        (bool active, ) = brake.brakeKey(address(oz), friend);
        assertTrue(active);
    }
}
