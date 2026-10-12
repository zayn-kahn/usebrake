# Brake on EVM

Brake as an ERC-7579 executor module, so it installs on Safe (through the Safe7579 adapter),
ZeroDev Kernel and Biconomy Nexus smart accounts. See the [main README](../../README.md) for the idea.

## What's here

| Path | What it is |
|---|---|
| `src/Brake.sol` | The module: driver proposes (calls to Brake, the account, the zero address, installed modules or protected targets are refused), brake holds or cancels, owner manages trusted contacts, caps and keys |
| `src/vendor/ERC7579DelayedExecutor.sol` | OpenZeppelin's audited delayed executor, copied with two marked patches (below) |
| `src/demo/DemoAccount.sol` | A minimal smart account for tests and the demo. Not for real funds |
| `src/demo/DemoDollar.sol` | dUSD, a test dollar (6 decimals); anyone mints up to 100,000 per call |
| `src/demo/DemoWorld.sol` | Builds one demo run in one transaction: account, Brake, dUSD, keys |
| `test/` | 90 Foundry tests: 22 core rules, 14 token lane, 37 for what the queue refuses, holds, keys and uninstall (one fuzzed), 12 on OpenZeppelin's own ERC-7579 account, 4 for DemoWorld, 1 for the OpenZeppelin fix |
| `script/DeployDemo.s.sol` | Deploys Brake, dUSD and DemoWorld to Anvil or a testnet |

## Key functions

| Function | Who | Does |
|---|---|---|
| `propose(account, salt, mode, data, note)` | Driver (agent) or owner | Runs at once if it's a small payment to a trusted contact, otherwise queues it |
| `preview(account, mode, data)` | Anyone (read-only) | Tells the agent "instant" or how long it would wait |
| `hold(account, opId)` | Brake | Pushes a waiting payment back by the max hold, counted from the hold (or from its due time, if later). Once per brake per payment |
| `cancel(account, salt, mode, data)` | Owner, a brake with cancel rights, or the agent that proposed it | Kills a waiting payment for good |
| `execute(account, salt, mode, data)` | Anyone, once the wait is over and before it expires | Sends it. A relayer does this so nobody has to wake up at 3 a.m. Void if the proposing driver was removed since |
| `setTrusted(account, recipient, trusted)` | Owner only | Adds or removes a trusted contact |
| `setDailyCap(account, token, cap)` | Owner only | How much of a token (or ETH, `address(0)`) may go out instantly per day |
| `setDriver(account, driver, active)` | Owner only | Adds or removes an agent key. Removing one voids what it queued |
| `setBrake(account, brake, active, canCancel)` | Owner only | Adds, changes or removes a brake key (a lost phone, a new watcher) |
| `setProtected(account, target, on)` | Owner only | Marks a contract the queue must never call (a fallback handler, a policy registry: anything that holds the account's rules and isn't detectable as a module) |
| `setDelay(newDelay)`, `setExpiration(newExpiration)` | Owner only (the account calls) | Changes the waits later. Never zero. Raising the delay is immediate; lowering it phases in over the base executor's five-day setback |
| `isInstalled`, `isDriver`, `brakeKey`, `isProtected`, `isKnownRecipient`, `dailyCap`, `maxHold` | Anyone (read-only) | The account's current rules |
| `state(opId)` | Anyone (read-only) | Scheduled, Ready, Expired, Executed or Canceled. An operation that can never run (module uninstalled, proposer removed) reads as Canceled |

What goes out instantly: a plain ETH send, or a bare `transfer(to, amount)` on a token with no ETH
attached, to a trusted contact, within that token's daily cap. A token with no cap always waits.
Everything else waits: `approve`, `transferFrom`, batches, any other call. Delegatecall is refused
outright. Only the owner trusts contacts; a payment that went through does not make its recipient
trusted.

**What the queue refuses.** At `propose`, every call in the operation (single, or each call of a batch)
is refused if its target is any of: Brake itself; the account; the zero address (ERC-7579 accounts
run a zero target as a call to themselves); a validator, executor or hook installed on the account
(asked through `isModuleInstalled`, so a queued `transferOwnership` on the account's validator is
refused too); or a contract the owner marked protected with `setProtected`. Fallback handlers cannot
be queried without a selector, and Brake cannot know every contract that holds the account's rules,
so those go on the protected list. Delegatecall and unknown call types are refused outright. The
queue carries payments and calls to other contracts; the rules are changed only by the owner,
directly. Refusal rather than a longer "policy lane", because a driver has no legitimate reason to
queue a rule change and a request path for one would only be surface for a tricked agent. The owner's
own changes are instant by design; an owner-side delay is a milestone.

**Keys.** Removing a driver voids what it queued, for good: each removal starts a new generation for
that address, and an operation only executes under the generation it was proposed in. Rotate keys by
adding the new one first, letting the old one's queue drain or re-proposing it, then removing the old
one. The owner's own queued operations are unaffected by rotation.

**Uninstall and reinstall.** Every per-account mapping is keyed by an install scope (the account plus
how many times Brake has been uninstalled on it), and operation ids include that generation.
Uninstalling retires every driver, brake, trusted contact, cap, protected target and queued operation,
and those operations read as Canceled from then on; a reinstall starts from its own config and may
reuse salts. One thing carries over from the base executor: a reinstall with a shorter delay keeps the
previous delay for the difference. Install refuses `queueDelay`, `maxHold` or `expiration` of zero.

**For watchers.** The `note` in `Proposed` is free text written by the driver. A watcher that reads it
with a language model must treat it as data, never as an instruction.

## The OpenZeppelin patches

1. `ERC7579Executor.execute` calls `_execute(account, mode, salt, …)`, but `ERC7579DelayedExecutor`
   declares the override as `(account, salt, mode, …)`. The two values swap, so any operation with a
   non-zero salt can never execute. Reported upstream as
   [issue #292](https://github.com/OpenZeppelin/openzeppelin-community-contracts/issues/292), still
   open; our copy fixes the parameter order and `test/vendor/` covers it.
2. `state(bytes32)` is made `virtual`, so Brake can report an operation that can never execute as
   Canceled instead of Scheduled or Ready.

## Run the tests

```sh
# first time only: the libraries are not committed
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts \
  OpenZeppelin/openzeppelin-community-contracts@2add94e5b7ce9d040ae5f6c80b6082e8159002da --no-git
forge test
```

Built and tested with forge-std 1.17.0, OpenZeppelin Contracts 5.7.0 and openzeppelin-community-contracts
commit `2add94e5` (2026-09-30); pin that commit if `main` moves:
`forge install OpenZeppelin/openzeppelin-community-contracts@2add94e5b7ce9d040ae5f6c80b6082e8159002da --no-git`.
The one community-contracts file we depend on for behaviour is copied into `src/vendor/`, so later
upstream changes can't shift it under us; the base `ERC7579Executor` (the public `execute` entry point)
still comes from the library.

## Run the demo

The technical demo lives in [client/demo/](../../client/demo/): Base Sepolia or local Anvil. See its README.

## Known gaps

- The owner key can uninstall the module instantly at the account level, and its own rule changes
  are instant. Closing this needs a hook that routes uninstall (and, optionally, policy changes)
  through a long wait.
- Daily caps count per UTC day, not per rolling 24 hours.
- Tested against the minimal `DemoAccount` and OpenZeppelin's `AccountERC7579`; Safe7579, Kernel and
  Nexus integration tests are a milestone.
- Brake refuses calls to detectable modules and to the protected list; a contract that holds the
  account's rules and is on neither can still be reached through the queue. The owner protects it.
- No ERC-1271 signature queue yet (deliberately: that is where Zodiac Delay's June 2026 bug was).
- Per-amount waits are not built.
- Not externally reviewed. Do not use with real funds.
