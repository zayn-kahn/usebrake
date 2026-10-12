// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC7579Utils, CallType} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {
    Execution,
    IERC7579ModuleConfig,
    MODULE_TYPE_VALIDATOR,
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_HOOK
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC7579DelayedExecutor} from "./vendor/ERC7579DelayedExecutor.sol";

/**
 * @title Brake
 * @notice A brake pedal for ERC-7579 accounts. Three roles per account:
 *  - Driver (hot key, agent): proposes actions. Routine ones run at once; anything else is queued.
 *  - Brake (phone, friend, watcher, AI): may `hold` a queued action once, for a bounded time, and
 *    `cancel` it if the owner granted that. A brake key can never move value.
 *  - Owner (the account itself, i.e. its validator key): cancels, changes policy, adds and removes keys.
 *
 * What the queue carries. Payments and calls to other contracts. Never the account's own rules: at
 * `propose`, every call in the operation is refused if its target is Brake, the account, the zero
 * address (ERC-7579 accounts run a zero target as a call to themselves), a validator, executor or hook
 * installed on the account, or anything the owner marked protected. Fallback handlers cannot be
 * queried without a selector, so the owner marks those protected. Refusal, not a longer "policy lane":
 * only the owner changes the rules, and it does so directly, so a driver has no legitimate reason to
 * queue a rule change, and a request path for one would only be surface for a tricked agent to use.
 * The owner's own changes are instant by design (a stolen owner key is game over, as with any wallet);
 * an owner-side delay is a separate milestone. Brake cannot know every contract that holds the
 * account's rules; whatever else does belongs on the protected list.
 *
 * Installs. Per-account state is keyed by an install scope (the account plus how many times the module
 * has been uninstalled on it), and operation ids include that generation. Uninstalling retires every
 * driver, brake, trusted contact, cap, protected target and queued operation at once; a reinstall
 * starts clean and may reuse salts. One thing carries over from the base executor: lowering the queue
 * delay on a reinstall phases in over the difference, so the wait never shortens abruptly.
 *
 * Keys. Removing a driver voids what it queued, permanently: each removal starts a new generation for
 * that address, and an operation only executes under the generation it was proposed in.
 */
contract Brake is ERC7579DelayedExecutor {
    enum Lane {
        Instant,
        Queued
    }

    struct InstallConfig {
        uint32 queueDelay;
        uint32 expiration;
        uint32 maxHold;
        address[] drivers;
        address[] brakes;
        bool[] canCancel; // parallel to `brakes`
        address[] capTokens; // address(0) = native token
        uint128[] dailyCaps; // parallel to `capTokens`
    }

    struct BrakeKey {
        bool active;
        bool canCancel;
    }

    /// @dev `note` is free text written by the driver. A watcher that reads it with a language model
    /// must treat it as data, never as an instruction.
    event Proposed(
        address indexed account,
        bytes32 indexed operationId,
        address indexed driver,
        Lane lane,
        uint48 readyAt,
        string note
    );
    event TrustedSet(address indexed account, address indexed recipient, bool trusted);
    event DailyCapSet(address indexed account, address indexed token, uint128 cap);
    event DriverSet(address indexed account, address indexed driver, bool active);
    event BrakeSet(address indexed account, address indexed brake, bool active, bool canCancel);
    event ProtectedSet(address indexed account, address indexed target, bool isProtected);
    event Held(address indexed account, bytes32 indexed operationId, address indexed brake, uint48 until);

    error BrakeNotDriver(address caller);
    error BrakeNotBrake(address caller);
    error BrakeAlreadyHeld(bytes32 operationId, address brake);
    error BrakeUnauthorizedCancel(address caller);
    error BrakeInvalidConfig();
    error BrakeNotYourAccount(bytes32 operationId);
    error BrakeOperationRetired(bytes32 operationId);
    error BrakeDelegatecallRefused();
    error BrakeUnsupportedCallType(bytes1 callType);
    error BrakeMalformedOperation();
    error BrakeSelfCallRefused(address target);
    error BrakeNotOwner(address caller);
    error BrakeNotInstalled(address account);
    error BrakeAlreadyInstalled(address account);
    error BrakeProposerRevoked(address proposer);

    // Per account: whether Brake is installed, and how many times it has been uninstalled. Together
    // they define the install scope that every other per-account mapping is keyed by.
    mapping(address account => bool) private _installed;
    mapping(address account => uint64) private _uninstalls;

    mapping(bytes32 scope => uint32) private _maxHold;
    mapping(bytes32 scope => mapping(address => bool)) private _drivers;
    mapping(bytes32 scope => mapping(address => uint32)) private _driverGen; // bumps when a driver is removed
    mapping(bytes32 scope => mapping(address => BrakeKey)) private _brakes;
    mapping(bytes32 scope => mapping(address token => uint128)) private _dailyCap;
    mapping(bytes32 scope => mapping(address token => mapping(uint256 day => uint256))) private _spent;
    mapping(bytes32 scope => mapping(address recipient => bool)) private _known;
    mapping(bytes32 scope => mapping(address target => bool)) private _protected;

    mapping(bytes32 operationId => address) private _opAccount;
    mapping(bytes32 operationId => bytes32) private _opScope;
    mapping(bytes32 operationId => address) private _proposer;
    mapping(bytes32 operationId => uint32) private _proposerGen;
    mapping(bytes32 operationId => uint48) private _heldUntil;
    mapping(bytes32 operationId => mapping(address brake => bool)) private _heldBy;

    // ---------------------------------------------------------------- install

    /**
     * @notice Installs Brake on the calling account. Only once per install; uninstall first to reconfigure.
     * @dev Does not call `super.onInstall`: the base decodes `(uint32, uint32)` and its `installed` flag
     * only guards `schedule`, which Brake disables. Brake keeps its own flag.
     */
    function onInstall(bytes calldata initData) public virtual override {
        address account = msg.sender;
        require(!_installed[account], BrakeAlreadyInstalled(account));
        InstallConfig memory cfg = abi.decode(initData, (InstallConfig));
        require(
            cfg.queueDelay > 0 &&
                cfg.expiration > 0 &&
                cfg.maxHold > 0 &&
                cfg.brakes.length == cfg.canCancel.length &&
                cfg.capTokens.length == cfg.dailyCaps.length,
            BrakeInvalidConfig()
        );
        _installed[account] = true;
        bytes32 scope = _scope(account);
        // On a first install the delay takes effect at once (the account had none). On a reinstall the
        // base executor keeps the previous delay for `old - new` when the new one is shorter.
        _setDelay(account, cfg.queueDelay, 0);
        _setExpiration(account, cfg.expiration);
        _maxHold[scope] = cfg.maxHold;
        for (uint256 i; i < cfg.drivers.length; ++i) {
            _drivers[scope][cfg.drivers[i]] = true;
            emit DriverSet(account, cfg.drivers[i], true);
        }
        for (uint256 i; i < cfg.brakes.length; ++i) {
            _brakes[scope][cfg.brakes[i]] = BrakeKey(true, cfg.canCancel[i]);
            emit BrakeSet(account, cfg.brakes[i], true, cfg.canCancel[i]);
        }
        for (uint256 i; i < cfg.capTokens.length; ++i) {
            _dailyCap[scope][cfg.capTokens[i]] = cfg.dailyCaps[i];
            emit DailyCapSet(account, cfg.capTokens[i], cfg.dailyCaps[i]);
        }
    }

    /// @notice Uninstalling retires every key, contact, cap, protected target and queued operation of this install.
    function onUninstall(bytes calldata data) public virtual override {
        if (!_installed[msg.sender]) return; // nothing to retire; never block an account's uninstall path
        _installed[msg.sender] = false;
        _uninstalls[msg.sender] += 1;
        super.onUninstall(data);
    }

    // ---------------------------------------------------------------- driver

    /// @notice Propose an action for `account`. Routine actions execute now; the rest are queued.
    function propose(
        address account,
        bytes32 salt,
        bytes32 mode,
        bytes calldata data,
        string calldata note
    ) public virtual returns (bytes32 operationId, Lane lane) {
        bytes32 scope = _requireInstalled(account);
        require(msg.sender == account || _drivers[scope][msg.sender], BrakeNotDriver(msg.sender));
        _checkTargets(account, scope, mode, data);
        lane = _classify(scope, mode, data);
        uint32 delay;
        if (lane == Lane.Queued) (delay, , ) = getDelay(account);
        (operationId, ) = _scheduleAt(account, salt, mode, data, uint48(block.timestamp), delay);
        _opAccount[operationId] = account;
        _opScope[operationId] = scope;
        _proposer[operationId] = msg.sender;
        if (msg.sender != account) _proposerGen[operationId] = _driverGen[scope][msg.sender];
        emit Proposed(account, operationId, msg.sender, lane, uint48(block.timestamp) + delay, note);
        if (lane == Lane.Instant) _execute(account, mode, salt, data);
    }

    /// @dev Every call in the operation must target something the queue may carry (see the header).
    function _checkTargets(address account, bytes32 scope, bytes32 mode, bytes calldata data) internal view {
        bytes1 callType = mode[0];
        if (callType == CallType.unwrap(ERC7579Utils.CALLTYPE_SINGLE)) {
            if (data.length < 52) revert BrakeMalformedOperation();
            (address target, , ) = ERC7579Utils.decodeSingle(data);
            _refuseProtected(account, scope, target);
        } else if (callType == CallType.unwrap(ERC7579Utils.CALLTYPE_BATCH)) {
            Execution[] calldata calls = ERC7579Utils.decodeBatch(data);
            for (uint256 i; i < calls.length; ++i) _refuseProtected(account, scope, calls[i].target);
        } else if (callType == CallType.unwrap(ERC7579Utils.CALLTYPE_DELEGATECALL)) {
            revert BrakeDelegatecallRefused();
        } else {
            revert BrakeUnsupportedCallType(callType);
        }
    }

    /// @dev Brake, the account, the zero address, an installed module, or an owner-protected target.
    function _refuseProtected(address account, bytes32 scope, address target) internal view {
        if (
            target == address(0) ||
            target == address(this) ||
            target == account ||
            _protected[scope][target] ||
            _isModule(account, target)
        ) revert BrakeSelfCallRefused(target);
    }

    /// @dev Whether `target` is a validator, executor or hook installed on `account`.
    function _isModule(address account, address target) internal view returns (bool) {
        IERC7579ModuleConfig acct = IERC7579ModuleConfig(account);
        return
            acct.isModuleInstalled(MODULE_TYPE_VALIDATOR, target, "") ||
            acct.isModuleInstalled(MODULE_TYPE_EXECUTOR, target, "") ||
            acct.isModuleInstalled(MODULE_TYPE_HOOK, target, "");
    }

    /**
     * @dev Instant only for a plain payment to a trusted contact within today's budget for that
     * token: a native-token send with no calldata, or a bare `transfer(to, amount)` on a token with
     * no value attached. A token with no daily cap always waits. Spends the budget when Instant.
     */
    function _classify(bytes32 scope, bytes32 mode, bytes calldata data) internal returns (Lane) {
        (Lane lane, address token, uint256 spentAfter) = _laneFor(scope, mode, data);
        if (lane == Lane.Instant) _spent[scope][token][block.timestamp / 1 days] = spentAfter;
        return lane;
    }

    /// @dev The lane `data` would get right now, its token, and today's spend if it ran instantly.
    function _laneFor(
        bytes32 scope,
        bytes32 mode,
        bytes calldata data
    ) internal view returns (Lane, address token, uint256 spentAfter) {
        (bool plain, address to, uint256 amount, address tok) = _payment(mode, data);
        uint128 cap = _dailyCap[scope][tok];
        if (!plain || cap == 0 || !_known[scope][to]) return (Lane.Queued, tok, 0);
        spentAfter = _spent[scope][tok][block.timestamp / 1 days] + amount;
        if (spentAfter > cap) return (Lane.Queued, tok, 0);
        return (Lane.Instant, tok, spentAfter);
    }

    /// @dev Reads a plain payment out of `data`. `token` is address(0) for the native token.
    function _payment(
        bytes32 mode,
        bytes calldata data
    ) internal pure returns (bool plain, address to, uint256 amount, address token) {
        if (mode != bytes32(0) || data.length < 52) return (false, address(0), 0, address(0));
        (address target, uint256 value, bytes calldata callData) = ERC7579Utils.decodeSingle(data);
        if (callData.length == 0) return (true, target, value, address(0));
        if (value != 0 || callData.length != 68 || bytes4(callData[:4]) != IERC20.transfer.selector) {
            return (false, address(0), 0, target);
        }
        uint256 word = uint256(bytes32(callData[4:36]));
        if (word >> 160 != 0) return (false, address(0), 0, target);
        return (true, address(uint160(word)), uint256(bytes32(callData[36:68])), target);
    }

    /// @dev All scheduling goes through {propose}.
    function _validateSchedule(address, bytes32, bytes32, bytes calldata) internal pure override {
        revert BrakeNotDriver(address(0));
    }

    /**
     * @dev Executes only operations of the account's current install whose proposer is the owner or
     * still a driver of the generation the operation was proposed in.
     */
    function _execute(
        address account,
        bytes32 mode,
        bytes32 salt,
        bytes calldata data
    ) internal virtual override returns (bytes[] memory) {
        bytes32 id = hashOperation(account, salt, mode, data);
        bytes32 scope = _requireInstalled(account);
        if (_opAccount[id] == account) {
            require(_opScope[id] == scope, BrakeOperationRetired(id));
            address proposer = _proposer[id];
            require(
                proposer == account ||
                    (_drivers[scope][proposer] && _proposerGen[id] == _driverGen[scope][proposer]),
                BrakeProposerRevoked(proposer)
            );
        }
        return super._execute(account, mode, salt, data);
    }

    // ---------------------------------------------------------------- brake

    /**
     * @notice Push a queued action back by the account's max hold, counted from now or from when it
     * was due, whichever is later. Once per brake per action, so a bad brake can only delay.
     */
    function hold(address account, bytes32 operationId) public virtual {
        bytes32 scope = _requireInstalled(account);
        require(_brakes[scope][msg.sender].active, BrakeNotBrake(msg.sender));
        require(_opAccount[operationId] == account, BrakeNotYourAccount(operationId));
        require(_opScope[operationId] == scope, BrakeOperationRetired(operationId));
        require(!_heldBy[operationId][msg.sender], BrakeAlreadyHeld(operationId, msg.sender));
        // A voided operation reads as Canceled (see {state}), so it cannot be held either.
        _validateStateBitmap(
            operationId,
            _encodeStateBitmap(OperationState.Scheduled) | _encodeStateBitmap(OperationState.Ready)
        );
        _heldBy[operationId][msg.sender] = true;
        (, uint48 executableAt, ) = getSchedule(operationId);
        uint48 from = executableAt > block.timestamp ? executableAt : uint48(block.timestamp);
        uint48 until = from + _maxHold[scope];
        _heldUntil[operationId] = until;
        emit Held(account, operationId, msg.sender, until);
    }

    /// @dev Cancel: the owner, the driver that proposed it, or a brake with a cancel grant.
    function _validateCancel(address account, bytes32 salt, bytes32 mode, bytes calldata data) internal view override {
        bytes32 scope = _scope(account);
        if (msg.sender == account || _brakes[scope][msg.sender].canCancel) return;
        bytes32 id = hashOperation(account, salt, mode, data);
        require(_proposer[id] == msg.sender && _drivers[scope][msg.sender], BrakeUnauthorizedCancel(msg.sender));
    }

    // ---------------------------------------------------------------- owner

    /**
     * @notice The owner adds or removes a trusted contact. Small payments to trusted contacts run
     * at once; everyone else waits. Only the account itself (its owner key) can call this.
     */
    function setTrusted(address account, address recipient, bool trusted) public virtual {
        bytes32 scope = _requireOwner(account);
        _known[scope][recipient] = trusted;
        emit TrustedSet(account, recipient, trusted);
    }

    /// @notice The owner sets how much of `token` (address(0) = native) may go out instantly per day.
    function setDailyCap(address account, address token, uint128 cap) public virtual {
        bytes32 scope = _requireOwner(account);
        _dailyCap[scope][token] = cap;
        emit DailyCapSet(account, token, cap);
    }

    /**
     * @notice The owner adds or removes a driver. Removing one voids what it queued, for good: adding
     * the same address back later does not revive those operations. Rotate keys by adding the new one
     * first, letting the old one's queue drain or re-proposing it, then removing the old one.
     */
    function setDriver(address account, address driver, bool active) public virtual {
        bytes32 scope = _requireOwner(account);
        if (!active && _drivers[scope][driver]) _driverGen[scope][driver] += 1;
        _drivers[scope][driver] = active;
        emit DriverSet(account, driver, active);
    }

    /// @notice The owner adds, changes or removes a brake key (a lost phone, a new watcher).
    function setBrake(address account, address brake, bool active, bool canCancel) public virtual {
        bytes32 scope = _requireOwner(account);
        _brakes[scope][brake] = BrakeKey(active, active && canCancel);
        emit BrakeSet(account, brake, active, active && canCancel);
    }

    /**
     * @notice The owner marks a contract the queue must never call: a fallback handler, a policy
     * registry, anything else that holds the account's rules and cannot be detected as a module.
     */
    function setProtected(address account, address target, bool isProtected) public virtual {
        bytes32 scope = _requireOwner(account);
        _protected[scope][target] = isProtected;
        emit ProtectedSet(account, target, isProtected);
    }

    /**
     * @notice The owner changes the queue delay. Raising it takes effect at once; lowering it waits out
     * the base executor's setback (five days, or the difference if that is longer), so the wait never
     * shortens abruptly.
     */
    function setDelay(uint32 newDelay) public virtual override {
        _requireInstalled(msg.sender);
        require(newDelay > 0, BrakeInvalidConfig());
        (uint32 current, , ) = getDelay(msg.sender);
        _setDelay(msg.sender, newDelay, newDelay >= current ? 0 : minSetback());
    }

    /// @notice The owner changes how long a ready operation stays executable. Never zero.
    function setExpiration(uint32 newExpiration) public virtual override {
        _requireInstalled(msg.sender);
        require(newExpiration > 0, BrakeInvalidConfig());
        super.setExpiration(newExpiration);
    }

    // ---------------------------------------------------------------- views

    /**
     * @notice What would happen to this action if proposed now, and how long it would wait.
     * Lets an agent read its own limits and ask the owner to trust a contact instead of queuing.
     * Reverts like {propose} would for an operation the queue refuses to carry.
     */
    function preview(address account, bytes32 mode, bytes calldata data) public view returns (Lane lane, uint32 wait) {
        bytes32 scope = _requireInstalled(account);
        _checkTargets(account, scope, mode, data);
        (lane, , ) = _laneFor(scope, mode, data);
        if (lane == Lane.Queued) (wait, , ) = getDelay(account);
    }

    /// @notice Whether Brake is currently installed on `account`.
    function isInstalled(address account) public view returns (bool) {
        return _installed[account];
    }

    /// @notice Whether `driver` may propose for `account`.
    function isDriver(address account, address driver) public view returns (bool) {
        return _drivers[_scope(account)][driver];
    }

    /// @notice Whether `brake` may hold for `account`, and whether it may also cancel.
    function brakeKey(address account, address brake) public view returns (bool active, bool canCancel) {
        BrakeKey memory key = _brakes[_scope(account)][brake];
        return (key.active, key.canCancel);
    }

    /// @notice Whether the owner marked `target` as a contract the queue must never call.
    function isProtected(address account, address target) public view returns (bool) {
        return _protected[_scope(account)][target];
    }

    /// @notice How long one hold pushes an operation back.
    function maxHold(address account) public view returns (uint32) {
        return _maxHold[_scope(account)];
    }

    /// @notice Whether `account` trusts `recipient`. Only the owner adds trusted contacts.
    function isKnownRecipient(address account, address recipient) public view returns (bool) {
        return _known[_scope(account)][recipient];
    }

    /// @notice How much of `token` (address(0) = native) may go out instantly per day. 0 = always wait.
    function dailyCap(address account, address token) public view returns (uint128) {
        return _dailyCap[_scope(account)][token];
    }

    /// @dev Operation ids include the install generation: a reinstall may reuse salts, and operations
    /// of a retired install are unreachable through `execute` and `cancel`.
    function hashOperation(
        address account,
        bytes32 salt,
        bytes32 mode,
        bytes calldata executionCalldata
    ) public view virtual override returns (bytes32) {
        return keccak256(abi.encode(account, _uninstalls[account], salt, mode, executionCalldata));
    }

    /// @dev An operation that can never execute (retired install, uninstalled module, or a proposer
    /// removed since) reads as Canceled, so watchers, relayers and brakes see what `execute` will do.
    function state(bytes32 operationId) public view virtual override returns (OperationState) {
        OperationState s = super.state(operationId);
        if ((s == OperationState.Scheduled || s == OperationState.Ready) && _isVoid(operationId)) {
            return OperationState.Canceled;
        }
        return s;
    }

    /// @dev Holds push both the ready time and the expiry back.
    function getSchedule(
        bytes32 operationId
    ) public view virtual override returns (uint48 scheduledAt, uint48 executableAt, uint48 expiresAt) {
        (scheduledAt, executableAt, expiresAt) = super.getSchedule(operationId);
        uint48 heldUntil = _heldUntil[operationId];
        if (heldUntil > executableAt) {
            expiresAt += heldUntil - executableAt;
            executableAt = heldUntil;
        }
    }

    // ---------------------------------------------------------------- internal

    function _isVoid(bytes32 operationId) internal view returns (bool) {
        address account = _opAccount[operationId];
        if (account == address(0)) return false;
        bytes32 scope = _scope(account);
        if (!_installed[account] || _opScope[operationId] != scope) return true;
        address proposer = _proposer[operationId];
        if (proposer == account) return false;
        return !_drivers[scope][proposer] || _proposerGen[operationId] != _driverGen[scope][proposer];
    }

    /// @dev The key every per-account mapping uses: the account and its install generation.
    function _scope(address account) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(account, _uninstalls[account]));
    }

    function _requireInstalled(address account) internal view returns (bytes32 scope) {
        require(_installed[account], BrakeNotInstalled(account));
        return _scope(account);
    }

    function _requireOwner(address account) internal view returns (bytes32 scope) {
        require(msg.sender == account, BrakeNotOwner(msg.sender));
        return _requireInstalled(account);
    }
}
