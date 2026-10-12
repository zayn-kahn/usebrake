// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Brake} from "../src/Brake.sol";
import {DemoAccount} from "../src/demo/DemoAccount.sol";
import {DemoDollar} from "../src/demo/DemoDollar.sol";

/// @dev The token lane: a plain `transfer` to a trusted contact within that token's daily cap
/// goes out at once. Everything else about tokens waits.
contract BrakeTokenTest is Test {
    Brake brake;
    DemoAccount account;
    DemoDollar usd;
    DemoDollar other; // a token the owner set no cap for

    address agent = makeAddr("agent");
    address phone = makeAddr("phone");
    address sam = makeAddr("sam");
    address attacker = makeAddr("attacker");

    bytes32 constant MODE_SINGLE = bytes32(0);
    uint32 constant QUEUE_DELAY = 1 hours;
    uint128 constant USD_DAILY_CAP = 500e6;

    function setUp() public {
        brake = new Brake();
        account = new DemoAccount(address(this));
        usd = new DemoDollar();
        other = new DemoDollar();
        usd.mint(address(account), 20_000e6);
        other.mint(address(account), 20_000e6);

        address[] memory drivers = new address[](1);
        drivers[0] = agent;
        address[] memory brakes = new address[](1);
        brakes[0] = phone;
        bool[] memory canCancel = new bool[](1);
        canCancel[0] = true;
        address[] memory capTokens = new address[](1);
        capTokens[0] = address(usd);
        uint128[] memory caps = new uint128[](1);
        caps[0] = USD_DAILY_CAP;

        account.installExecutor(
            address(brake),
            abi.encode(Brake.InstallConfig(QUEUE_DELAY, 7 days, 6 hours, drivers, brakes, canCancel, capTokens, caps))
        );
        account.call(address(brake), abi.encodeCall(brake.setTrusted, (address(account), sam, true)));
    }

    function _call(address target, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, uint256(0), callData);
    }

    function _transfer(DemoDollar token, address to, uint256 amount) internal pure returns (bytes memory) {
        return _call(address(token), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _propose(bytes32 salt, bytes memory data) internal returns (Brake.Lane lane) {
        vm.prank(agent);
        (, lane) = brake.propose(address(account), salt, MODE_SINGLE, data, "test");
    }

    function test_transferToTrustedContactWithinCap_isInstant() public {
        Brake.Lane lane = _propose("a", _transfer(usd, sam, 100e6));
        assertEq(uint8(lane), uint8(Brake.Lane.Instant));
        assertEq(usd.balanceOf(sam), 100e6);
    }

    function test_transferToStranger_waits() public {
        Brake.Lane lane = _propose("a", _transfer(usd, attacker, 100e6));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
        assertEq(usd.balanceOf(attacker), 0);
    }

    function test_transferOverDailyCap_waits() public {
        assertEq(uint8(_propose("a", _transfer(usd, sam, 400e6))), uint8(Brake.Lane.Instant));
        assertEq(uint8(_propose("b", _transfer(usd, sam, 200e6))), uint8(Brake.Lane.Queued)); // 600 > 500
        vm.warp(block.timestamp + 1 days);
        assertEq(uint8(_propose("c", _transfer(usd, sam, 200e6))), uint8(Brake.Lane.Instant));
    }

    function test_tokenWithNoCap_alwaysWaits() public {
        Brake.Lane lane = _propose("a", _transfer(other, sam, 1e6));
        assertEq(uint8(lane), uint8(Brake.Lane.Queued));
    }

    function test_tokenBudgetIsSeparateFromEth() public {
        vm.deal(address(account), 1 ether);
        assertEq(uint8(_propose("a", _transfer(usd, sam, 500e6))), uint8(Brake.Lane.Instant));
        // ETH has no cap here, so it waits; the dUSD spend did not touch it either way
        assertEq(uint8(_propose("b", abi.encodePacked(sam, uint256(1), bytes("")))), uint8(Brake.Lane.Queued));
    }

    function test_approveToTrustedContact_waits() public {
        bytes memory data = _call(address(usd), abi.encodeCall(IERC20.approve, (sam, 1e6)));
        assertEq(uint8(_propose("a", data)), uint8(Brake.Lane.Queued));
    }

    function test_transferWithEthAttached_waits() public {
        vm.deal(address(account), 1 ether);
        bytes memory data = abi.encodePacked(address(usd), uint256(1), abi.encodeCall(IERC20.transfer, (sam, 1e6)));
        assertEq(uint8(_propose("a", data)), uint8(Brake.Lane.Queued));
    }

    function test_transferWithTrailingBytes_waits() public {
        bytes memory data = _call(address(usd), abi.encodePacked(abi.encodeCall(IERC20.transfer, (sam, 1e6)), hex"00"));
        assertEq(uint8(_propose("a", data)), uint8(Brake.Lane.Queued));
    }

    function test_previewReadsTheTokenLane() public view {
        (Brake.Lane toSam, uint32 w1) = brake.preview(address(account), MODE_SINGLE, _transfer(usd, sam, 100e6));
        (Brake.Lane toAttacker, uint32 w2) =
            brake.preview(address(account), MODE_SINGLE, _transfer(usd, attacker, 100e6));
        assertEq(uint8(toSam), uint8(Brake.Lane.Instant));
        assertEq(w1, 0);
        assertEq(uint8(toAttacker), uint8(Brake.Lane.Queued));
        assertEq(w2, QUEUE_DELAY);
    }

    function test_queuedTokenTransfer_phoneCancels_nothingMoves() public {
        bytes memory data = _transfer(usd, attacker, 10_000e6);
        _propose("theft", data);
        vm.prank(phone);
        brake.cancel(address(account), "theft", MODE_SINGLE, data);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        brake.execute(address(account), "theft", MODE_SINGLE, data);
        assertEq(usd.balanceOf(attacker), 0);
        assertEq(usd.balanceOf(address(account)), 20_000e6);
    }

    function test_queuedTokenTransfer_doesNotTrustTheRecipient() public {
        bytes memory data = _transfer(usd, attacker, 1e6);
        _propose("x", data);
        vm.warp(block.timestamp + QUEUE_DELAY);
        brake.execute(address(account), "x", MODE_SINGLE, data);
        assertEq(usd.balanceOf(attacker), 1e6);
        // the token contract was the call target; the recipient inside the call must not become trusted
        assertFalse(brake.isKnownRecipient(address(account), address(usd)));
        assertEq(uint8(_propose("y", _transfer(usd, attacker, 1e6))), uint8(Brake.Lane.Queued));
    }

    function test_ownerSetsDailyCap() public {
        account.call(address(brake), abi.encodeCall(brake.setDailyCap, (address(account), address(other), 10e6)));
        assertEq(brake.dailyCap(address(account), address(other)), 10e6);
        assertEq(uint8(_propose("a", _transfer(other, sam, 10e6))), uint8(Brake.Lane.Instant));
    }

    function test_agentCannotSetDailyCap() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Brake.BrakeNotOwner.selector, agent));
        brake.setDailyCap(address(account), address(usd), type(uint128).max);
    }

    function test_faucetMintIsCapped() public {
        vm.expectRevert(DemoDollar.TooMuch.selector);
        usd.mint(address(this), 100_000e6 + 1);
    }
}
