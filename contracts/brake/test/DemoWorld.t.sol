// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Brake} from "../src/Brake.sol";
import {DemoAccount} from "../src/demo/DemoAccount.sol";
import {DemoDollar} from "../src/demo/DemoDollar.sol";
import {DemoWorld} from "../src/demo/DemoWorld.sol";

/// @dev One wallet approval builds a whole demo run.
contract DemoWorldTest is Test {
    Brake brake = new Brake();
    DemoDollar usd = new DemoDollar();
    DemoWorld factory = new DemoWorld(brake, usd);

    address you = makeAddr("you"); // the viewer's browser wallet: owner and phone
    address agent = makeAddr("agent");
    address watcher = makeAddr("watcher");
    address alex = makeAddr("alex");
    address attacker = makeAddr("attacker");

    function _create() internal returns (DemoAccount account) {
        vm.deal(you, 1 ether);
        vm.prank(you);
        account = factory.create{value: 0.03 ether}(agent, watcher, alex, 0.01 ether);
    }

    function test_createBuildsTheRun() public {
        DemoAccount account = _create();
        assertEq(account.owner(), you);
        assertEq(usd.balanceOf(address(account)), factory.START());
        assertTrue(brake.isKnownRecipient(address(account), alex));
        assertEq(brake.dailyCap(address(account), address(usd)), factory.DAILY_CAP());
        (uint32 delay, , ) = brake.getDelay(address(account));
        assertEq(delay, 1 hours);
        assertEq(agent.balance, 0.01 ether);
        assertEq(watcher.balance, 0.02 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_agentPaysAlexAtOnce_strangerWaits_youCancel_watcherCannot() public {
        DemoAccount account = _create();
        bytes memory toAlex = abi.encodePacked(address(usd), uint256(0), abi.encodeCall(IERC20.transfer, (alex, 100e6)));
        bytes memory theft =
            abi.encodePacked(address(usd), uint256(0), abi.encodeCall(IERC20.transfer, (attacker, 10_000e6)));

        vm.startPrank(agent);
        (, Brake.Lane a) = brake.propose(address(account), "a", bytes32(0), toAlex, "");
        (bytes32 opId, Brake.Lane b) = brake.propose(address(account), "b", bytes32(0), theft, "");
        vm.stopPrank();
        assertEq(uint8(a), uint8(Brake.Lane.Instant));
        assertEq(uint8(b), uint8(Brake.Lane.Queued));

        vm.prank(watcher);
        brake.hold(address(account), opId);
        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeUnauthorizedCancel.selector, watcher));
        brake.cancel(address(account), "b", bytes32(0), theft);
        vm.prank(you);
        brake.cancel(address(account), "b", bytes32(0), theft);
        assertEq(usd.balanceOf(attacker), 0);
    }

    function test_youCanTrustSam_factoryCannotAnymore() public {
        DemoAccount account = _create();
        address sam = makeAddr("sam");
        vm.prank(you);
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), sam, true)));
        assertTrue(brake.isKnownRecipient(address(account), sam));
        vm.prank(address(factory));
        vm.expectRevert("not owner");
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), attacker, true)));
    }

    function test_gasSplitCannotExceedValue() public {
        vm.deal(you, 1 ether);
        vm.prank(you);
        vm.expectRevert();
        factory.create{value: 0.01 ether}(agent, watcher, alex, 0.02 ether);
    }
}
