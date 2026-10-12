// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Brake} from "../src/Brake.sol";
import {ERC7579DelayedExecutor} from "../src/vendor/ERC7579DelayedExecutor.sol";
import {DemoAccount} from "../src/demo/DemoAccount.sol";
import {DemoDollar} from "../src/demo/DemoDollar.sol";

/// @dev Any contract a queued operation may legitimately call: records who called it.
contract Recorder {
    address public lastCaller;
    bytes public lastData;

    fallback() external payable {
        lastCaller = msg.sender;
        lastData = msg.data;
    }
}

/// @dev A contract that keeps per-account state keyed by msg.sender, like a validator module does.
contract OwnerKeyedModule {
    mapping(address account => address) public ownerOf;

    function transferOwnership(address newOwner) external {
        ownerOf[msg.sender] = newOwner;
    }
}

/// @dev What the queue may carry, who may change the rules, how holds count time, and what an
/// uninstall retires. These are the rules a reviewer will probe first.
contract BrakeQueueTest is Test {
    Brake brake;
    DemoAccount account;

    address agent = makeAddr("agent");
    address agent2 = makeAddr("agent2");
    address phone = makeAddr("phone"); // brake with cancel grant
    address watcher = makeAddr("watcher"); // hold only
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");

    bytes32 constant MODE_SINGLE = bytes32(0);
    bytes32 constant MODE_BATCH = bytes32(bytes1(0x01));
    uint32 constant QUEUE_DELAY = 1 hours;
    uint32 constant EXPIRATION = 7 days;
    uint32 constant MAX_HOLD = 6 hours;
    uint128 constant CAP = 0.1 ether;
    uint256 constant T0 = 1_800_000_000; // a fixed, round starting time

    function setUp() public {
        vm.warp(T0);
        brake = new Brake();
        account = new DemoAccount(address(this));
        vm.deal(address(account), 10 ether);
        _install(agent);
    }

    // ---------------------------------------------------------------- helpers

    function _config(address driver) internal view returns (bytes memory) {
        return _config(driver, QUEUE_DELAY, MAX_HOLD);
    }

    function _config(address driver, uint32 queueDelay, uint32 hold) internal view returns (bytes memory) {
        address[] memory drivers = new address[](1);
        drivers[0] = driver;
        address[] memory brakes = new address[](2);
        brakes[0] = phone;
        brakes[1] = watcher;
        bool[] memory canCancel = new bool[](2);
        canCancel[0] = true;
        address[] memory capTokens = new address[](1);
        uint128[] memory caps = new uint128[](1);
        caps[0] = CAP;
        return abi.encode(Brake.InstallConfig(queueDelay, EXPIRATION, hold, drivers, brakes, canCancel, capTokens, caps));
    }

    function _install(address driver) internal {
        account.installExecutor(address(brake), _config(driver));
    }

    function _send(address to, uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(to, value, bytes(""));
    }

    function _call(address target, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, uint256(0), callData);
    }

    function _propose(bytes32 salt, bytes memory data) internal returns (bytes32 opId, Brake.Lane lane) {
        vm.prank(agent);
        return brake.propose(address(account), salt, MODE_SINGLE, data, "test");
    }

    function _asOwner(bytes memory callData) internal {
        account.call(address(brake), callData);
    }

    function _state(bytes32 opId) internal view returns (ERC7579DelayedExecutor.OperationState) {
        return brake.state(opId);
    }

    // ---------------------------------------------------------------- the queue never carries the rules

    function test_driverCannotQueueSetTrusted() public {
        bytes memory data = _call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), attacker, true)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(account), keccak256("t"), MODE_SINGLE, data, "add payroll vendor");
    }

    function test_driverCannotQueueSetDailyCap() public {
        bytes memory data =
            _call(address(brake), abi.encodeCall(brake.setDailyCap, (address(account), address(0), type(uint128).max)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(account), keccak256("c"), MODE_SINGLE, data, "");
    }

    function test_driverCannotQueueAReinstallOrUninstall() public {
        bytes memory reinstall = _call(address(brake), abi.encodeCall(brake.onInstall, (_config(attacker, 1, 1))));
        bytes memory uninstall = _call(address(brake), abi.encodeCall(brake.onUninstall, ("")));
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(account), keccak256("i"), MODE_SINGLE, reinstall, "");
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(account), keccak256("u"), MODE_SINGLE, uninstall, "");
        vm.stopPrank();
    }

    function test_driverCannotQueueACallToTheAccountItself() public {
        bytes memory data = _call(address(account), abi.encodeCall(account.uninstallExecutor, ("")));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(account)));
        brake.propose(address(account), keccak256("a"), MODE_SINGLE, data, "");
    }

    function test_ownerCannotQueueSelfCallsEither_itChangesRulesDirectly() public {
        bytes memory data = _call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        account.call(
            address(brake), abi.encodeCall(brake.propose, (address(account), keccak256("o"), MODE_SINGLE, data, ""))
        );
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        assertTrue(brake.isKnownRecipient(address(account), friend));
    }

    function test_batchWithACallToBrakeIsRefused() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(friend, 0.01 ether, "");
        calls[1] = Execution(address(brake), 0, abi.encodeCall(brake.setTrusted, (address(account), attacker, true)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.propose(address(account), keccak256("b"), MODE_BATCH, ERC7579Utils.encodeBatch(calls), "");
    }

    function test_batchOfPlainPaymentsIsQueued_neverInstant() public {
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(friend, 0.01 ether, "");
        calls[1] = Execution(friend, 0.01 ether, "");
        vm.prank(agent);
        (, Brake.Lane lane) =
            brake.propose(address(account), keccak256("b"), MODE_BATCH, ERC7579Utils.encodeBatch(calls), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_unknownCallTypeIsRefused() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnsupportedCallType.selector, bytes1(0xfe)));
        brake.propose(address(account), keccak256("s"), bytes32(bytes1(0xfe)), _send(friend, 1), "");
    }

    function test_previewRefusesWhatProposeRefuses() public {
        bytes memory data = _call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), attacker, true)));
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(brake)));
        brake.preview(address(account), MODE_SINGLE, data);
    }

    function test_queuedCallToAnyOtherContractStillRuns() public {
        Recorder other = new Recorder();
        bytes memory data = _call(address(other), hex"deadbeef"); // any other target, any calldata: waits, then runs
        (, Brake.Lane lane) = _propose(keccak256("x"), data);
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertEq(other.lastCaller(), address(account));
        assertEq(other.lastData(), hex"deadbeef");
    }

    function test_zeroTargetIsRefused_accountsRunItAsASelfCall() public {
        bytes memory data = _call(address(0), abi.encodeCall(account.uninstallExecutor, ("")));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(0)));
        brake.propose(address(account), keccak256("z"), MODE_SINGLE, data, "");
    }

    function test_ownerProtectsAContractTheQueueMustNeverCall() public {
        OwnerKeyedModule registry = new OwnerKeyedModule();
        bytes memory data = _call(address(registry), abi.encodeCall(registry.transferOwnership, (attacker)));
        // Not a module of this account and not protected: the queue may carry it.
        (, Brake.Lane lane) = _propose(keccak256("a"), data);
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        // Protected by the owner: refused.
        _asOwner(abi.encodeCall(brake.setProtected, (address(account), address(registry), true)));
        assertTrue(brake.isProtected(address(account), address(registry)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeSelfCallRefused.selector, address(registry)));
        brake.propose(address(account), keccak256("b"), MODE_SINGLE, data, "");
    }

    function test_malformedSingleCallIsRefused() public {
        vm.prank(agent);
        vm.expectRevert(Brake.BrakeMalformedOperation.selector);
        brake.propose(address(account), keccak256("m"), MODE_SINGLE, hex"deadbeef", "");
    }

    // ---------------------------------------------------------------- holds count from the hold

    function test_holdDuringTheQueue_addsMaxHoldToTheReadyTime() public {
        (bytes32 opId, ) = _propose(keccak256("x"), _send(attacker, 1 ether));
        vm.warp(T0 + 30 minutes);
        vm.prank(watcher);
        vm.expectEmit(true, true, true, true);
        emit Brake.Held(address(account), opId, watcher, uint48(T0 + QUEUE_DELAY + MAX_HOLD));
        brake.hold(address(account), opId);
        (, uint48 executableAt, uint48 expiresAt) = brake.getSchedule(opId);
        assertEq(executableAt, T0 + QUEUE_DELAY + MAX_HOLD);
        assertEq(expiresAt, T0 + QUEUE_DELAY + MAX_HOLD + EXPIRATION);
    }

    function test_holdOnAReadyOperation_countsFromNow() public {
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);
        uint256 late = T0 + QUEUE_DELAY + MAX_HOLD + 1; // ready for over six hours, nobody executed it
        vm.warp(late);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Ready));

        vm.prank(watcher);
        brake.hold(address(account), opId);

        (, uint48 executableAt, ) = brake.getSchedule(opId);
        assertEq(executableAt, late + MAX_HOLD);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Scheduled));
        vm.expectPartialRevert(ERC7579DelayedExecutor.ERC7579ExecutorUnexpectedOperationState.selector);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertEq(attacker.balance, 0);

        vm.warp(late + MAX_HOLD);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertEq(attacker.balance, 1 ether);
    }

    function test_secondBrakeHoldsFromTheEndOfTheFirstHold() public {
        (bytes32 opId, ) = _propose(keccak256("x"), _send(attacker, 1 ether));
        vm.prank(watcher);
        brake.hold(address(account), opId);
        vm.warp(T0 + 40 minutes);
        vm.prank(phone);
        brake.hold(address(account), opId);
        (, uint48 executableAt, ) = brake.getSchedule(opId);
        assertEq(executableAt, T0 + QUEUE_DELAY + 2 * MAX_HOLD); // bounded by maxHold x active brakes
    }

    function test_anExpiredOperationCannotBeHeldBackToLife() public {
        (bytes32 opId, ) = _propose(keccak256("x"), _send(attacker, 1 ether));
        vm.warp(T0 + QUEUE_DELAY + EXPIRATION);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Expired));
        vm.prank(watcher);
        vm.expectPartialRevert(ERC7579DelayedExecutor.ERC7579ExecutorUnexpectedOperationState.selector);
        brake.hold(address(account), opId);
    }

    // ---------------------------------------------------------------- keys

    function test_ownerRemovesADriver_itCannotProposeAnymore() public {
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent, false)));
        assertFalse(brake.isDriver(address(account), agent));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotDriver.selector, agent));
        brake.propose(address(account), keccak256("x"), MODE_SINGLE, _send(friend, 1), "");
    }

    function test_removingADriverVoidsWhatItQueued_forGood() public {
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent, false)));
        vm.warp(block.timestamp + QUEUE_DELAY);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Canceled)); // reads as dead
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeProposerRevoked.selector, agent));
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        // a brake cannot hold a dead operation either
        vm.prank(watcher);
        vm.expectPartialRevert(ERC7579DelayedExecutor.ERC7579ExecutorUnexpectedOperationState.selector);
        brake.hold(address(account), opId);
        // adding the same key back does not revive it
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent, true)));
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Canceled));
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeProposerRevoked.selector, agent));
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertEq(attacker.balance, 0);
        // the re-added key proposes fresh operations as usual
        vm.prank(agent);
        (, Brake.Lane lane) = brake.propose(address(account), keccak256("y"), MODE_SINGLE, _send(friend, 1), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_theOwnersOwnQueuedOperationsSurviveKeyRotation() public {
        bytes memory data = _send(friend, 1 ether);
        account.call(address(brake), abi.encodeCall(brake.propose, (address(account), keccak256("o"), MODE_SINGLE, data, "")));
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent, false)));
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(account), keccak256("o"), MODE_SINGLE, data);
        assertEq(friend.balance, 1 ether);
    }

    function test_keyChangesEmitEvents() public {
        vm.expectEmit(true, true, true, true);
        emit Brake.DriverSet(address(account), agent2, true);
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent2, true)));
        vm.expectEmit(true, true, true, true);
        emit Brake.BrakeSet(address(account), phone, false, false);
        _asOwner(abi.encodeCall(brake.setBrake, (address(account), phone, false, true)));
        vm.expectEmit(true, true, true, true);
        emit Brake.ProtectedSet(address(account), friend, true);
        _asOwner(abi.encodeCall(brake.setProtected, (address(account), friend, true)));
    }

    function test_ownerAddsADriver() public {
        _asOwner(abi.encodeCall(brake.setDriver, (address(account), agent2, true)));
        vm.prank(agent2);
        (, Brake.Lane lane) = brake.propose(address(account), keccak256("x"), MODE_SINGLE, _send(friend, 1), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_ownerAddsAndRemovesBrakes() public {
        address newWatcher = makeAddr("new watcher");
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);

        _asOwner(abi.encodeCall(brake.setBrake, (address(account), newWatcher, true, false)));
        vm.prank(newWatcher);
        brake.hold(address(account), opId);

        _asOwner(abi.encodeCall(brake.setBrake, (address(account), phone, false, false))); // a lost phone
        (bool active, bool canCancel) = brake.brakeKey(address(account), phone);
        assertFalse(active);
        assertFalse(canCancel);
        vm.startPrank(phone);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotBrake.selector, phone));
        brake.hold(address(account), opId);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnauthorizedCancel.selector, phone));
        brake.cancel(address(account), keccak256("x"), MODE_SINGLE, data);
        vm.stopPrank();
    }

    function test_aRemovedBrakeNeverKeepsItsCancelGrant() public {
        _asOwner(abi.encodeCall(brake.setBrake, (address(account), phone, false, true)));
        (bool active, bool canCancel) = brake.brakeKey(address(account), phone);
        assertFalse(active);
        assertFalse(canCancel);
    }

    function test_onlyTheOwnerManagesKeys() public {
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotOwner.selector, agent));
        brake.setDriver(address(account), agent2, true);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotOwner.selector, agent));
        brake.setBrake(address(account), agent, true, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- install and uninstall

    function test_installTwiceIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeAlreadyInstalled.selector, address(account)));
        account.installExecutor(address(brake), _config(agent2));
    }

    function test_configNeedsADelayAHoldAndAnExpiry() public {
        DemoAccount fresh = new DemoAccount(address(this));
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        fresh.installExecutor(address(brake), _config(agent, 0, MAX_HOLD));
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        fresh.installExecutor(address(brake), _config(agent, QUEUE_DELAY, 0));
        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory none = new address[](0);
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        fresh.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, 0, MAX_HOLD, drivers, none, new bool[](0), none, new uint128[](0)))
        );
        // parallel arrays must match
        address[] memory twoBrakes = new address[](2);
        twoBrakes[0] = phone;
        twoBrakes[1] = watcher;
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        fresh.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, drivers, twoBrakes, new bool[](1), none, new uint128[](0)))
        );
    }

    function test_installEmitsTheInitialConfig() public {
        DemoAccount fresh = new DemoAccount(address(this));
        vm.expectEmit(true, true, true, true);
        emit Brake.DriverSet(address(fresh), agent, true);
        vm.expectEmit(true, true, true, true);
        emit Brake.BrakeSet(address(fresh), phone, true, true);
        vm.expectEmit(true, true, true, true);
        emit Brake.BrakeSet(address(fresh), watcher, true, false);
        vm.expectEmit(true, true, true, true);
        emit Brake.DailyCapSet(address(fresh), address(0), CAP);
        fresh.installExecutor(address(brake), _config(agent));
    }

    function test_ownerCannotSetAZeroDelayOrExpiryLater() public {
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        account.call(address(brake), abi.encodeCall(brake.setDelay, (0)));
        vm.expectRevert(Brake.BrakeInvalidConfig.selector);
        account.call(address(brake), abi.encodeCall(brake.setExpiration, (0)));
        account.call(address(brake), abi.encodeCall(brake.setExpiration, (1 days)));
        assertEq(brake.getExpiration(address(account)), 1 days);
        // raising the delay is immediate; lowering it phases in over the base executor's setback
        account.call(address(brake), abi.encodeCall(brake.setDelay, (2 hours)));
        (uint32 delay, uint32 pending, uint48 effect) = brake.getDelay(address(account));
        assertEq(delay, 2 hours);
        account.call(address(brake), abi.encodeCall(brake.setDelay, (30 minutes)));
        (delay, pending, effect) = brake.getDelay(address(account));
        assertEq(delay, 2 hours);
        assertEq(pending, 30 minutes);
        assertEq(effect, block.timestamp + 5 days);
    }

    function test_executeAfterExpiryIsRefused() public {
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);
        vm.warp(T0 + QUEUE_DELAY + EXPIRATION);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Expired));
        vm.expectPartialRevert(ERC7579DelayedExecutor.ERC7579ExecutorUnexpectedOperationState.selector);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        assertEq(attacker.balance, 0);
    }

    function test_uninstallRetiresKeysAndTrustedContacts() public {
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), attacker, true)));
        account.uninstallExecutor("");
        assertFalse(brake.isInstalled(address(account)));
        _install(agent2);

        assertFalse(brake.isDriver(address(account), agent));
        assertFalse(brake.isKnownRecipient(address(account), attacker));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotDriver.selector, agent));
        brake.propose(address(account), keccak256("old"), MODE_SINGLE, _send(attacker, 1), "");
    }

    function test_uninstallRetiresQueuedOperations() public {
        bytes memory data = _send(attacker, 1 ether);
        (bytes32 opId, ) = _propose(keccak256("x"), data);
        account.uninstallExecutor("");
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Canceled)); // dead while uninstalled
        _install(agent);
        vm.warp(block.timestamp + QUEUE_DELAY);
        assertEq(uint8(_state(opId)), uint8(ERC7579DelayedExecutor.OperationState.Canceled)); // and after a reinstall

        // (salt, mode, data) now names a fresh, unknown operation of the new install
        assertTrue(brake.hashOperation(address(account), keccak256("x"), MODE_SINGLE, data) != opId);
        vm.expectPartialRevert(ERC7579DelayedExecutor.ERC7579ExecutorUnexpectedOperationState.selector);
        brake.execute(address(account), keccak256("x"), MODE_SINGLE, data);
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeOperationRetired.selector, opId));
        brake.hold(address(account), opId);
        assertEq(attacker.balance, 0);
    }

    function test_reinstallMayReuseSaltsAndGetsItsOwnCaps() public {
        bytes memory data = _send(friend, 0.05 ether);
        _propose(keccak256("x"), data);
        account.uninstallExecutor("");
        // reinstall with a different cap: the old cap is gone with the old install
        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory none = new address[](0);
        address[] memory capTokens = new address[](1);
        uint128[] memory caps = new uint128[](1);
        caps[0] = CAP / 2;
        account.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, drivers, none, new bool[](0), capTokens, caps))
        );
        assertEq(brake.dailyCap(address(account), address(0)), CAP / 2);
        (, Brake.Lane lane) = _propose(keccak256("x"), data); // same salt and data as before: fine
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_nothingWorksWhileUninstalled() public {
        (bytes32 opId, ) = _propose(keccak256("q"), _send(attacker, 1 ether));
        account.uninstallExecutor("");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotInstalled.selector, address(account)));
        brake.propose(address(account), keccak256("x"), MODE_SINGLE, _send(friend, 1), "");
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotInstalled.selector, address(account)));
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotInstalled.selector, address(account)));
        brake.preview(address(account), MODE_SINGLE, _send(friend, 1));
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotInstalled.selector, address(account)));
        brake.hold(address(account), opId);
        // onUninstall on an account that has nothing installed is a harmless no-op, so an account's
        // own uninstall path can never be blocked by Brake
        account.call(address(brake), abi.encodeCall(brake.onUninstall, ("")));
        assertFalse(brake.isInstalled(address(account)));
    }

    function test_reinstallStartsCleanWithTheNewConfig() public {
        account.uninstallExecutor("");
        _install(agent2);
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        vm.prank(agent2);
        (, Brake.Lane lane) = brake.propose(address(account), keccak256("x"), MODE_SINGLE, _send(friend, 0.05 ether), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Instant));
        assertEq(friend.balance, 0.05 ether);
    }

    // ---------------------------------------------------------------- the instant lane, fuzzed

    /// @dev Only a bare `transfer(to, amount)` to a trusted contact can be instant. Any other calldata
    /// on a capped token waits, whatever it looks like.
    function testFuzz_onlyABareTransferToATrustedContactIsInstant(bytes memory callData, uint96 value) public {
        DemoDollar usd = new DemoDollar();
        usd.mint(address(account), 100_000e6);
        _asOwner(abi.encodeCall(brake.setDailyCap, (address(account), address(usd), 500e6)));
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        bool bareTransfer = callData.length == 68 && bytes4(callData) == IERC20.transfer.selector;
        vm.assume(!bareTransfer);
        vm.prank(agent);
        (, Brake.Lane lane) =
            brake.propose(address(account), keccak256(callData), MODE_SINGLE, abi.encodePacked(address(usd), uint256(value), callData), "");
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        assertEq(usd.balanceOf(friend), 0);
    }

    // ---------------------------------------------------------------- documented behaviour

    /// @dev The daily cap is a budget per UTC day, not a rolling 24 hours: up to twice the cap can go
    /// out around midnight. Documented in the README; a rolling window is a planned change.
    function test_dailyCapIsPerUtcDay() public {
        _asOwner(abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        uint256 midnight = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(midnight - 1);
        (, Brake.Lane a) = _propose(keccak256("a"), _send(friend, CAP));
        vm.warp(midnight);
        (, Brake.Lane b) = _propose(keccak256("b"), _send(friend, CAP));
        assertEq(uint8(a), uint8(Brake.Lane.Instant));
        assertEq(uint8(b), uint8(Brake.Lane.Instant));
        assertEq(friend.balance, 2 * CAP);
    }
}
