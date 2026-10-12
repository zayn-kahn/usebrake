# Security

Brake is testnet software and has not had an external security review. Do not use it to hold real
money.

## Reporting a problem

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository, not in a public
issue. Include what an attacker can do, the steps or a failing `forge test`, and the commit you
looked at. You'll get a reply within a few days.

## What counts

The properties Brake promises, and so the most serious findings:

- A brake key can never move money, on its own or combined with any other call
- A driver key can't skip the queue, send past the daily cap, trust a contact, or change any rule,
  directly or through a queued call
- A removed driver's queued operations can never execute, and nothing survives an uninstall
- A queued operation can't execute before its wait (plus holds) ends, or after it expires

Known and documented gaps (instant owner actions, the per-UTC-day cap, untested account
implementations) are listed in the README under "Not yet" and in
[contracts/brake/README.md](contracts/brake/README.md) under "Known gaps".
