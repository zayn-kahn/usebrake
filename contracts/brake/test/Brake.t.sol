// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Brake} from "../src/Brake.sol";
import {ERC7579DelayedExecutor} from "../src/vendor/ERC7579DelayedExecutor.sol";
import {DemoAccount} from "../src/demo/DemoAccount.sol";

contract BrakeTest is Test {
    Brake brake;
    DemoAccount account;

    address agent = makeAddr("agent"); // Driver: proposes
    address phone = makeAddr("phone"); // Brake key with cancel grant
    address watcher = makeAddr("watcher"); // Brake key, hold only
    address attacker = makeAddr("attacker");

    bytes32 constant MODE_SINGLE = bytes32(0);
    uint32 constant QUEUE_DELAY = 1 hours;
    uint32 constant EXPIRATION = 7 days;
    uint32 constant MAX_HOLD = 6 hours;
    uint128 constant ETH_DAILY_CAP = 0.1 ether;

    function setUp() public {
        brake = new Brake();
        account = new DemoAccount(address(this));
        vm.deal(address(account), 10 ether);

        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory brakes = new address[](2);
        brakes[0] = phone;
        brakes[1] = watcher;
        bool[] memory canCancel = new bool[](2);
        canCancel[0] = true;
        address[] memory capTokens = new address[](1); // address(0) = ETH
        uint128[] memory caps = new uint128[](1);
        caps[0] = ETH_DAILY_CAP;

        account.installExecutor(
            address(brake),
            abi.encode(
                Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, drivers, brakes, canCancel, capTokens, caps)
            )
        );
    }

    function _send(address to, uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(to, value, bytes(""));
    }

    function _propose(bytes32 salt, bytes memory data) internal returns (bytes32 opId, Brake.Lane lane) {
        vm.prank(agent);
        return brake.propose(address(account), salt, MODE_SINGLE, data, "test");
    }

    function _state(bytes32 opId) internal view returns (ERC7579DelayedExecutor.OperationState) {
        return brake.state(opId);
    }

    // The demo in one test: agent proposes 5 ETH to a new address, it queues, the watcher
    // holds, the owner's phone cancels, and nothing moves.
    function test_agentProposesToNewAddress_brakeHolds_phoneCancels() public {
        bytes memory data = _send(attacker, 5 ether);
        (bytes32 opId, Brake.Lane lane) = _propose(keccak256("op1"), data);

        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Scheduled));

        vm.prank(watcher);
        brake.hold(address(account), opId);
        (, uint48 executableAt, ) = brake.getSchedule(opId);
        assertEq(executableAt, block.timestamp + QUEUE_DELAY + MAX_HOLD);

        vm.prank(phone);
        brake.cancel(address(account), keccak256("op1"), MODE_SINGLE, data);

        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Canceled));
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        brake.execute(address(account), keccak256("op1"), MODE_SINGLE, data);
        assertEq(attacker.balance, 0);
        assertEq(address(account).balance, 10 ether);
    }

    address friend = makeAddr("friend");

    /// @dev The owner trusts `to`.
    function _makeKnown(address to) internal {
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), to, true)));
    }

    function test_firstSendToAnyAddressIsQueued_evenIfSmall() public {
        (, Brake.Lane lane) = _propose(keccak256("small"), _send(friend, 0.001 ether));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        assertEq(friend.balance, 0);
    }

    function test_queuedOpExecutesAfterDelay_byAnyone() public {
        bytes memory data = _send(friend, 1 ether);
        _propose(keccak256("op"), data);

        vm.expectRevert();
        brake.execute(address(account), keccak256("op"), MODE_SINGLE, data);

        vm.warp(block.timestamp + QUEUE_DELAY);
        vm.prank(makeAddr("random relayer"));
        brake.execute(address(account), keccak256("op"), MODE_SINGLE, data);
        assertEq(friend.balance, 1 ether);
    }

    function test_smallSendToKnownRecipient_runsInstantly() public {
        _makeKnown(friend);
        uint256 before = friend.balance;

        (bytes32 opId, Brake.Lane lane) = _propose(keccak256("instant"), _send(friend, 0.05 ether));

        assertEq(uint8(lane), uint8(Brake.Lane.Instant));
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Executed));
        assertEq(friend.balance, before + 0.05 ether);
    }

    function test_dailyCapIsABudget_notAPerTxLimit() public {
        _makeKnown(friend);
        (, Brake.Lane a) = _propose(keccak256("a"), _send(friend, 0.06 ether));
        (, Brake.Lane b) = _propose(keccak256("b"), _send(friend, 0.06 ether)); // 0.12 > 0.1 today
        assertEq(uint8(a), uint8(Brake.Lane.Instant));
        assertEq(uint8(b), uint8(Brake.Lane.Queued));

        vm.warp(block.timestamp + 1 days); // new day, budget resets
        (, Brake.Lane c) = _propose(keccak256("c"), _send(friend, 0.06 ether));
        assertEq(uint8(c), uint8(Brake.Lane.Instant));
    }

    function test_sendToKnownRecipientWithCalldata_isQueued() public {
        _makeKnown(friend);
        (, Brake.Lane lane) = _propose(keccak256("call"), abi.encodePacked(friend, uint256(0), hex"deadbeef"));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    // ---------------------------------------------------------------- brake keys cannot move value

    function test_brakeKeyCannotPropose() public {
        vm.prank(phone);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotDriver.selector, phone));
        brake.propose(address(account), keccak256("x"), MODE_SINGLE, _send(phone, 1 ether), "");
    }

    function test_nobodyCanUseBaseSchedule() public {
        vm.prank(agent);
        vm.expectRevert();
        brake.schedule(address(account), keccak256("x"), MODE_SINGLE, _send(agent, 1 ether));
    }

    function test_holdOnlyBrakeCannotCancel() public {
        bytes memory data = _send(attacker, 1 ether);
        _propose(keccak256("x"), data);
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnauthorizedCancel.selector, watcher));
        brake.cancel(address(account), keccak256("x"), MODE_SINGLE, data);
    }

    function test_strangerCannotHoldOrCancel() public {
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotBrake.selector, attacker));
        brake.hold(address(account), opId);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnauthorizedCancel.selector, attacker));
        brake.cancel(address(account), keccak256("x"), MODE_SINGLE, data);
        vm.stopPrank();
    }

    function test_eachBrakeHoldsOnce_soDelayIsBounded() public {
        (bytes32 opId, ) = _propose(keccak256("x"), _send(attacker, 1 ether));
        vm.startPrank(watcher);
        brake.hold(address(account), opId);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeAlreadyHeld.selector, opId, watcher));
        brake.hold(address(account), opId);
        vm.stopPrank();
    }

    function test_brakeOfOneAccountCannotHoldAnother() public {
        DemoAccount other = new DemoAccount(address(this));
        address[] memory none = new address[](0);
        other.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, _one(agent), none, new bool[](0), none, new uint128[](0)))
        );
        vm.prank(agent);
        (bytes32 opId, ) = brake.propose(address(other), keccak256("x"), MODE_SINGLE, _send(friend, 1), "");
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotBrake.selector, watcher));
        brake.hold(address(other), opId);
    }

    function test_cannotHoldAnotherAccountsOpByNamingYourOwnAccount() public {
        DemoAccount other = new DemoAccount(address(this));
        address[] memory none = new address[](0);
        other.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, _one(agent), none, new bool[](0), none, new uint128[](0)))
        );
        vm.prank(agent);
        (bytes32 otherOp, ) = brake.propose(address(other), keccak256("x"), MODE_SINGLE, _send(friend, 1), "");
        // watcher is a brake on `account`, and names `account`, but the op belongs to `other`
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotYourAccount.selector, otherOp));
        brake.hold(address(account), otherOp);
    }

    function test_delegatecallIsRefused() public {
        bytes32 delegateMode = bytes32(bytes1(0xff));
        vm.prank(agent);
        vm.expectRevert(Brake.BrakeDelegatecallRefused.selector);
        brake.propose(address(account), keccak256("x"), delegateMode, abi.encodePacked(attacker, hex"00"), "");
    }

    function test_driverCanCancelOwnProposal_notOthers() public {
        address agent2 = makeAddr("agent2");
        // agent2 is not a driver; only `agent` proposed
        bytes memory data = _send(friend, 1 ether);
        _propose(keccak256("x"), data);
        vm.prank(agent2);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnauthorizedCancel.selector, agent2));
        brake.cancel(address(account), keccak256("x"), MODE_SINGLE, data);
        vm.prank(agent);
        brake.cancel(address(account), keccak256("x"), MODE_SINGLE, data);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // An attacker's payment that got through the queue must not make the attacker trusted.
    function test_executedSendDoesNotTrustTheRecipient() public {
        bytes memory data = _send(attacker, 1 ether);
        _propose(keccak256("x"), data);
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertFalse(brake.isKnownRecipient(address(account), attacker));
        (, Brake.Lane lane) = _propose(keccak256("y"), _send(attacker, 0.01 ether));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    // ---------------------------------------------------------------- trusted contacts

    address sam = makeAddr("sam");

    function test_ownerTrustsAddress_thenSmallSendIsInstant() public {
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), sam, true)));
        assertTrue(brake.isKnownRecipient(address(account), sam));

        (, Brake.Lane lane) = _propose(keccak256("sam"), _send(sam, 0.05 ether));
        assertEq(uint8(lane), uint8(Brake.Lane.Instant));
        assertEq(sam.balance, 0.05 ether);
    }

    function test_trustedButOverDailyLimit_stillQueues() public {
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), sam, true)));
        (, Brake.Lane lane) = _propose(keccak256("big"), _send(sam, 1 ether));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_agentCannotTrustAnAddress() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotOwner.selector, agent));
        brake.setTrusted(address(account), attacker, true);
    }

    function test_brakeCannotTrustAnAddress() public {
        vm.prank(phone);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotOwner.selector, phone));
        brake.setTrusted(address(account), attacker, true);
    }

    function test_untrustingAnAddressMakesItWaitAgain() public {
        _makeKnown(friend);
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), friend, false)));
        (, Brake.Lane lane) = _propose(keccak256("x"), _send(friend, 0.01 ether));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_previewTellsTheAgentItsLimits_withoutSpendingBudget() public {
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), sam, true)));
        (Brake.Lane toSam, uint32 samWait) = brake.preview(address(account), MODE_SINGLE, _send(sam, 0.06 ether));
        (Brake.Lane toStranger, uint32 strangerWait) =
            brake.preview(address(account), MODE_SINGLE, _send(attacker, 0.06 ether));
        assertEq(uint8(toSam), uint8(Brake.Lane.Instant));
        assertEq(samWait, 0);
        assertEq(uint8(toStranger), uint8(Brake.Lane.Queued));
        assertEq(strangerWait, QUEUE_DELAY);

        // previewing twice did not use up today's budget: two real 0.05 sends still fit in 0.1
        (, Brake.Lane a) = _propose(keccak256("a"), _send(sam, 0.05 ether));
        (, Brake.Lane b) = _propose(keccak256("b"), _send(sam, 0.05 ether));
        assertEq(uint8(a), uint8(Brake.Lane.Instant));
        assertEq(uint8(b), uint8(Brake.Lane.Instant));
    }
}
