/** What the demo needs from the chain. The story and the UI never talk to the chain directly. */
export type ChainId = 'evm' | 'sim'

export type OpState = 'unknown' | 'waiting' | 'ready' | 'expired' | 'sent' | 'canceled'

/** A payment the agent proposed to the Brake wallet. */
export type Op = {
  id: string
  to: string
  amount: string
  note: string
  lane: 'instant' | 'queued'
  state: OpState
  scheduledAt: number
  readyAt: number
  heldBy: string[]
  /** Whatever the chain needs to act on this payment again (e.g. salt, mode, calldata on EVM). */
  raw: unknown
}

/** A transaction the demo sent, for the "show transactions" view. */
export type Tx = { who: string; call: string; hash: string; where: string; url?: string }

export interface Chain {
  id: ChainId
  name: string
  symbol: string
  /**
   * CoinGecko id for the live price, with `usdPrice` as the fallback (labelled as assumed). Empty for a
   * test token with a fixed price, described by `priceNote`.
   */
  priceId: string
  usdPrice: number
  priceNote?: string
  amounts: { start: string; friend: string; theft: string; dailyLimit: string }
  people: { friend: string; sam: string; attacker: string }
  /** How long a new payment waits, and how much longer a brake's hold adds, in seconds. */
  waits: { queue: number; hold: number }
  /** Whether the local chain can jump forward in time. If not, the "ignore the alert" ending is hidden. */
  canSkipTime: boolean

  /** The agent proposes a payment from the Brake wallet. */
  propose(to: string, amount: string, note: string): Promise<void>
  /** What the agent sees before paying: instant, or how many seconds it would wait. */
  preview(to: string, amount: string): Promise<{ instant: boolean; wait: number }>
  /** The owner adds a trusted contact. */
  trust(contact: string): Promise<void>
  hold(op: Op): Promise<void>
  cancel(op: Op): Promise<void>
  execute(op: Op): Promise<void>
  /** The plain wallet (no Brake) pays directly. */
  twinSend(to: string, amount: string): Promise<void>
  /** Moves chain time forward. Only called when `canSkipTime` is true. */
  skip(seconds: number): Promise<void>

  loadOps(): Promise<Op[]>
  balances(): Promise<{ account: string; twin: string; attacker: string }>
  chainTime(): Promise<number>
  onTx(fn: (tx: Tx) => void): () => void

  /** Gets a clean starting state before the story begins, and remembers it so Replay can return to it. */
  prepare(): Promise<void>
  resetDemo(): Promise<void>
}
