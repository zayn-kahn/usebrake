# Brake simulation

Live: https://brake-simulation.vercel.app

The Brake story in nine steps, with USDC amounts, for recording a demo video. **No blockchain and no
wallet:** every balance, payment and transaction lives in the browser. The screen says so ("Simulation"
next to the name, "Simulated USDC, no blockchain" under each balance, "Simulated transactions" over
the table).

The rules are the same as the real contract in [contracts/brake](../../contracts/brake):

- Payments to a trusted contact within the daily limit (500 USDC) go out at once
- Anything else waits an hour in a public queue
- A watcher can hold a waiting payment once, for six more hours
- Your phone holds a brake key that can cancel, and can never send
- Once the wait is over, anyone (a relayer) can send it

## Run it

```sh
npm install
npm run dev
```

No chain, keys or `.env` needed.

## The story

1. **The right key signed. The money was gone.** Bybit, Drift, Grok × Bankr
2. **Meet your agent.** Two wallets with 20,000 USDC each; only one has Brake. Alex is trusted
3. **A new friend.** The agent checks its limits: Sam isn't trusted, so it asks you
4. **You decide who's trusted.** You add Sam; 100 USDC goes out at once
5. **Then someone gets clever.** A Morse-code post tricks the agent into sending 10,000 USDC from both
6. **Same mistake. Different ending.** "Gone in seconds" next to "1 hour to decide"
7. **Someone's watching.** The watcher holds it for six more hours and says why
8. **Your phone lights up.** Cancel it, or ignore it
9. **The bottom line**, or, if you ignored it, skip seven hours and watch it go through

"Show transactions" lists every action the real contract would receive, in plain words (propose,
trust contact, hold payment, cancel payment, send payment), with made-up identifiers in no chain's
format and a step counter instead of block numbers.

## How it works

`src/chains/sim.ts` implements the same `Chain` interface as the real adapters, keeping state in
memory. Time runs in real seconds and can jump forward, so both endings work. Each action waits
about half a second so it reads like a transaction.
