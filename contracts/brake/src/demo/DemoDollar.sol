// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Demo Dollar (dUSD): a test dollar with 6 decimals, like USDC. Anyone can mint up to
/// 100,000 per call. Testnet and local demos only; worth nothing.
contract DemoDollar is ERC20 {
    uint256 public constant MAX_MINT = 100_000e6;

    error TooMuch();

    constructor() ERC20("Demo Dollar", "dUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        require(amount <= MAX_MINT, TooMuch());
        _mint(to, amount);
    }
}
