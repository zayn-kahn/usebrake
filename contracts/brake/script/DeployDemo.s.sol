// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {Brake} from "../src/Brake.sol";
import {DemoDollar} from "../src/demo/DemoDollar.sol";
import {DemoWorld} from "../src/demo/DemoWorld.sol";

/// @dev Deploys what every demo run shares: Brake, the dUSD test dollar and the DemoWorld factory.
/// Each viewer's wallet then builds its own run with one `DemoWorld.create` call.
/// Writes the addresses to client/demo/src/chains/evm/networks/$NETWORK.json.
contract DeployDemo is Script {
    function run() external {
        string memory network = vm.envString("NETWORK");
        uint256 fromBlock = block.number;

        vm.startBroadcast();
        Brake brake = new Brake();
        DemoDollar dusd = new DemoDollar();
        DemoWorld world = new DemoWorld(brake, dusd);
        vm.stopBroadcast();

        string memory j = "deployment";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "fromBlock", fromBlock);
        vm.serializeAddress(j, "brake", address(brake));
        vm.serializeAddress(j, "dusd", address(dusd));
        string memory out = vm.serializeAddress(j, "world", address(world));
        vm.writeJson(out, string.concat("../../client/demo/src/chains/evm/networks/", network, ".json"));
    }
}
