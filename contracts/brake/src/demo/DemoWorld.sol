// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Brake} from "../Brake.sol";
import {DemoAccount} from "./DemoAccount.sol";
import {DemoDollar} from "./DemoDollar.sol";

/// @dev Builds one run of the demo in a single transaction, so the viewer's wallet approves once:
/// a new account owned by the caller, Brake installed (the caller's wallet is also "your phone", a
/// brake key that may cancel), 20,000 dUSD, Alex trusted, and gas for the agent and watcher keys.
/// Testnet and local demos only.
contract DemoWorld {
    uint32 public constant QUEUE_DELAY = 1 hours;
    uint32 public constant EXPIRATION = 7 days;
    uint32 public constant MAX_HOLD = 6 hours;
    uint128 public constant DAILY_CAP = 500e6;
    uint256 public constant START = 20_000e6;

    Brake public immutable brake;
    DemoDollar public immutable dusd;

    event Created(address indexed owner, address account, address agent, address watcher);

    constructor(Brake brake_, DemoDollar dusd_) {
        brake = brake_;
        dusd = dusd_;
    }

    /// @param agentGas Part of `msg.value` for the agent; the rest goes to the watcher.
    function create(
        address agent,
        address watcher,
        address friend,
        uint256 agentGas
    ) external payable returns (DemoAccount account) {
        account = new DemoAccount(address(this));
        account.installExecutor(address(brake), _config(agent, watcher, msg.sender));
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), friend, true)));
        dusd.mint(address(account), START);
        account.setOwner(msg.sender);
        if (agentGas > 0) Address.sendValue(payable(agent), agentGas);
        if (msg.value > agentGas) Address.sendValue(payable(watcher), msg.value - agentGas);
        emit Created(msg.sender, address(account), agent, watcher);
    }

    function _config(address agent, address watcher, address phone) internal view returns (bytes memory) {
        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory brakes = new address[](2);
        brakes[0] = phone;
        brakes[1] = watcher;
        bool[] memory canCancel = new bool[](2);
        canCancel[0] = true;
        address[] memory capTokens = new address[](1);
        capTokens[0] = address(dusd);
        uint128[] memory caps = new uint128[](1);
        caps[0] = DAILY_CAP;
        return abi.encode(
            Brake.InstallConfig(QUEUE_DELAY, EXPIRATION, MAX_HOLD, drivers, brakes, canCancel, capTokens, caps)
        );
    }
}
