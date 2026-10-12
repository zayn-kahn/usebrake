import type { Chain, Op, OpState, Tx } from './types'

/**
 * The Brake flow, simulated in the browser with USDC amounts. No blockchain and no wallet: every
 * balance and payment lives in memory. The rules match the contract in contracts/brake:
 * trusted contacts within a daily limit go out at once, everything else waits an hour in a public
 * queue, each brake can hold a payment once for six more hours, and a brake allowed to cancel can
 * kill it. Transactions are made up for the table and labelled as simulated.
 */

const CONFIG = {
  queue: 3600,
  hold: 6 * 3600,
  dailyLimit: 500,
  start: 20_000,
  latencyMs: 450, // a believable pause per "transaction"
}

// Made-up identifiers in no chain's format: the simulation shows Brake's rules, not a network.
const hex = (n: number) => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join('')
const addr = () => `sim:${hex(24)}`
const digest = () => hex(64)
const pause = () => new Promise((r) => setTimeout(r, CONFIG.latencyMs))

const people = { friend: addr(), sam: addr(), attacker: addr() }

type Payment = {
  id: number
  to: string
  amount: number
  note: string
  instant: boolean
  scheduledAt: number
  readyAt: number
  heldBy: string[]
  done: 'sent' | 'canceled' | null
}

type State = {
  /** Simulated clock: real seconds since the start, plus any skipped time. */
  t0: number
  skipped: number
  vault: number
  twin: number
  received: Map<string, number>
  trusted: Set<string>
  spentDay: number
  spentToday: number
  payments: Payment[]
  block: number
}

let s: State
function fresh(): State {
  return {
    t0: Date.now(),
    skipped: 0,
    vault: CONFIG.start,
    twin: CONFIG.start,
    received: new Map(),
    trusted: new Set([people.friend]),
    spentDay: 0,
    spentToday: 0,
    payments: [],
    block: 0,
  }
}
s = fresh()

const now = () => Math.floor((Date.now() - s.t0) / 1000) + s.skipped + 1_760_000_000
const day = (t: number) => Math.floor(t / 86_400)

const listeners = new Set<(tx: Tx) => void>()
function logTx(who: string, call: string) {
  s.block += 1 + Math.floor(Math.random() * 3)
  listeners.forEach((fn) => fn({ who, call, hash: digest(), where: `simulated, step ${s.block.toLocaleString()}` }))
}

function receive(to: string, amount: number) {
  s.received.set(to, (s.received.get(to) ?? 0) + amount)
}

/** Instant if trusted and within today's limit; returns today's spend if it goes out. */
function lane(to: string, amount: number): { instant: boolean; spentAfter: number } {
  if (!s.trusted.has(to)) return { instant: false, spentAfter: 0 }
  const spent = day(now()) === s.spentDay ? s.spentToday : 0
  const after = spent + amount
  return after > CONFIG.dailyLimit ? { instant: false, spentAfter: 0 } : { instant: true, spentAfter: after }
}

function stateOf(p: Payment): OpState {
  if (p.done) return p.done
  return now() >= p.readyAt ? 'ready' : 'waiting'
}

function find(op: Op) {
  const p = s.payments.find((x) => String(x.id) === op.id)
  if (!p) throw new Error('No such payment')
  return p
}

export const sim: Chain = {
  id: 'sim',
  name: 'Simulation',
  symbol: 'USDC',
  priceId: '',
  usdPrice: 1,
  priceNote: 'Simulated USDC, no blockchain',
  amounts: { start: String(CONFIG.start), friend: '100', theft: '10000', dailyLimit: String(CONFIG.dailyLimit) },
  people,
  waits: { queue: CONFIG.queue, hold: CONFIG.hold },
  canSkipTime: true,

  async propose(to, amount, note) {
    await pause()
    const a = Number(amount)
    const t = now()
    const { instant, spentAfter } = lane(to, a)
    const p: Payment = {
      id: s.payments.length,
      to,
      amount: a,
      note,
      instant,
      scheduledAt: t,
      readyAt: instant ? t : t + CONFIG.queue,
      heldBy: [],
      done: null,
    }
    if (instant) {
      s.spentDay = day(t)
      s.spentToday = spentAfter
      s.vault -= a
      receive(to, a)
      p.done = 'sent'
    }
    s.payments.push(p)
    logTx('Agent', `propose ${a.toLocaleString()} USDC`)
  },

  async preview(to, amount) {
    const { instant } = lane(to, Number(amount))
    return { instant, wait: instant ? 0 : CONFIG.queue }
  },

  async trust(contact) {
    await pause()
    s.trusted.add(contact)
    logTx('You', 'trust contact')
  },

  async hold(op) {
    await pause()
    const p = find(op)
    if (stateOf(p) !== 'waiting' && stateOf(p) !== 'ready') throw new Error('Only a waiting payment can be held')
    if (p.heldBy.includes('watcher')) throw new Error('This brake already held it')
    p.heldBy.push('watcher')
    p.readyAt = Math.max(p.readyAt, now()) + CONFIG.hold
    logTx('Watcher', 'hold payment')
  },

  async cancel(op) {
    await pause()
    const p = find(op)
    if (p.done) throw new Error('Only a waiting payment can be canceled')
    p.done = 'canceled'
    logTx('Your phone', 'cancel payment')
  },

  async execute(op) {
    await pause()
    const p = find(op)
    if (stateOf(p) !== 'ready') throw new Error('Not ready yet')
    p.done = 'sent'
    s.vault -= p.amount
    receive(p.to, p.amount)
    logTx('Relayer', 'send payment (wait over)')
  },

  async twinSend(to, amount) {
    await pause()
    const a = Number(amount)
    s.twin -= a
    receive(to, a)
    logTx('Agent (no Brake)', `send ${a.toLocaleString()} USDC`)
  },

  async skip(seconds) {
    s.skipped += seconds
  },

  async loadOps() {
    return s.payments
      .map(
        (p): Op => ({
          id: String(p.id),
          to: p.to,
          amount: String(p.amount),
          note: p.note,
          lane: p.instant ? 'instant' : 'queued',
          state: stateOf(p),
          scheduledAt: p.scheduledAt,
          readyAt: p.readyAt,
          heldBy: p.heldBy,
          raw: null,
        }),
      )
      .reverse()
  },

  async balances() {
    return { account: String(s.vault), twin: String(s.twin), attacker: String(s.received.get(people.attacker) ?? 0) }
  },

  async chainTime() {
    return now()
  },

  onTx(fn) {
    listeners.add(fn)
    return () => void listeners.delete(fn)
  },

  async prepare() {
    s = fresh()
  },

  async resetDemo() {
    s = fresh()
  },
}
