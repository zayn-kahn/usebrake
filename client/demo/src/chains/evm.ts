import {
  createPublicClient,
  createWalletClient,
  decodeFunctionData,
  encodeFunctionData,
  encodePacked,
  erc20Abi,
  fallback,
  formatEther,
  formatUnits,
  http,
  keccak256,
  parseEther,
  parseEventLogs,
  parseUnits,
  toHex,
  type Address,
  type Chain as ViemChain,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount, privateKeyToAddress, type PrivateKeyAccount } from 'viem/accounts'
import { baseSepolia, foundry } from 'viem/chains'
import { brakeAbi, demoAccountAbi, demoDollarAbi, demoWorldAbi } from './evm/abis'
import { connectWallet, restoreWallet, walletAddress, walletSend } from './evm/wallet'
import type { Chain, Op, OpState, Tx } from './types'

// ---------------------------------------------------------------- network

/** Where the demo runs, picked with VITE_EVM_NETWORK in .env. Local Anvil until a testnet deploy exists. */
const NETWORKS = {
  anvil: {
    chain: foundry,
    label: 'a local chain (Anvil)',
    explorer: null,
    explorerName: undefined,
    canSkipTime: true,
    unreachable: 'Can’t reach the local chain. In client/demo run “npm run chain” and “npm run setup”, then reload.',
    /** ETH sent to each demo key for gas, when it runs low. */
    gas: parseEther('0.05'),
    lowGas: parseEther('0.01'),
  },
  'base-sepolia': {
    chain: baseSepolia,
    label: 'Base Sepolia',
    explorer: 'https://sepolia.basescan.org',
    explorerName: 'Basescan',
    canSkipTime: false,
    unreachable: undefined,
    // ~0.000003 ETH per transaction at Base Sepolia prices: enough for about ten each.
    gas: parseEther('0.00003'),
    lowGas: parseEther('0.00001'),
  },
} as const
type NetworkName = keyof typeof NETWORKS

export const networkName = (import.meta.env.VITE_EVM_NETWORK as NetworkName | undefined) ?? 'anvil'
const net = NETWORKS[networkName]
if (!net) throw new Error(`Unknown VITE_EVM_NETWORK “${networkName}”. Use one of: ${Object.keys(NETWORKS).join(', ')}`)
export const viemChain: ViemChain = net.chain

type Deployment = { chainId: number; fromBlock: number; brake: Address; dusd: Address; world: Address }
const deployments = import.meta.glob<Deployment>('./evm/networks/*.json', { eager: true, import: 'default' })
const d = deployments[`./evm/networks/${networkName}.json`] ?? null

/**
 * On testnets, Reown's RPC first (same project ID as the wallet picker), with the chain's public RPC
 * as the fallback: Base Sepolia's public node often answers 401 to browsers (Cloudflare).
 */
const reownId = import.meta.env.VITE_REOWN_PROJECT_ID as string | undefined
const transport =
  reownId && net.explorer
    ? fallback([http(`https://rpc.walletconnect.org/v1/?chainId=eip155:${net.chain.id}&projectId=${reownId}`), http()])
    : http()
const pub = createPublicClient({ chain: net.chain, transport, pollingInterval: 250 })
const MODE_SINGLE: Hex = `0x${'0'.repeat(64)}`
const DECIMALS = 6 // dUSD, like USDC
type Raw = { salt: Hex; mode: Hex; data: Hex }

/** The story's numbers. Same waits on every chain: an hour in the queue, six more on hold. */
const CONFIG = { queue: 3600, hold: 6 * 3600, dailyLimit: 500, start: 20_000 }

function deployed(): Deployment {
  if (!d) throw new Error(`Brake isn’t deployed on ${net.label} yet. See client/demo/README.md.`)
  return d
}

// ---------------------------------------------------------------- demo keys

/**
 * The agent and the watcher are throwaway keys made in this browser. Their only funds are a little
 * test ETH for gas, sent by the viewer's wallet during setup.
 */
function sessionKey(name: string): PrivateKeyAccount {
  const k = `brake-evm-key:${name}`
  try {
    const saved = localStorage.getItem(k) as Hex | null
    if (saved) return privateKeyToAccount(saved)
    const fresh = generatePrivateKey()
    localStorage.setItem(k, fresh)
    return privateKeyToAccount(fresh)
  } catch {
    return privateKeyToAccount(generatePrivateKey())
  }
}
const AGENT = sessionKey('agent')
const WATCHER = sessionKey('watcher')
const signerFor = (account: PrivateKeyAccount) => createWalletClient({ account, chain: net.chain, transport })
const agent = signerFor(AGENT)
const watcher = signerFor(WATCHER)
const randomAddress = () => privateKeyToAddress(generatePrivateKey())

/** One run of the story: an account the viewer's wallet owns, and the people in it. */
type World = { owner: Address; account: Address; friend: Address; sam: Address; attacker: Address; fromBlock: string }
let world: World | null = null

/**
 * The plain "Without Brake" wallet is simulated: it only shows what happens with no brake, which
 * nobody doubts. Its balance lives here and resets with each run; only Brake's side is on chain.
 */
let plain = { balance: 0, sentToAttacker: 0 }

const worldKey = (owner: string) => `brake-evm-world:${networkName}:${d?.world}:${owner}`

function setWorld(w: World | null) {
  world = w
  plain = { balance: w ? CONFIG.start : 0, sentToAttacker: 0 }
  const owner = walletAddress()
  if (!owner) return
  try {
    if (w) localStorage.setItem(worldKey(owner), JSON.stringify(w))
    else localStorage.removeItem(worldKey(owner))
  } catch {
    /* the world still works for this page view */
  }
}

function need(): World {
  if (!world) throw new Error('Set up the demo first')
  return world
}

// ---------------------------------------------------------------- transactions

const txListeners = new Set<(tx: Tx) => void>()

function logTx(who: string, call: string, hash: Hex, block: bigint) {
  const where = net.explorer ? net.label : `block ${block}`
  const url = net.explorer ? `${net.explorer}/tx/${hash}` : undefined
  txListeners.forEach((fn) => fn({ who, call, hash, where, url }))
}

/** Waits until `hash` is mined; throws if it reverted. */
async function confirm(hash: Hex, who: string, call: string) {
  const receipt = await pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${call} reverted`)
  logTx(who, call, hash, receipt.blockNumber)
  return receipt
}

type BrakeWrite = 'propose' | 'hold' | 'execute' | 'cancel'

/**
 * A propose that goes out instantly also runs the payment, so it costs more gas than one that queues.
 * A gas estimate from a node that hasn't yet seen "Sam is trusted" prices the queued path and the
 * instant payment then runs out of gas. A fixed limit avoids that; only the gas used is paid.
 */
const PROPOSE_GAS = 400_000n

/** A demo key signs and sends a call to Brake. */
async function send(signer: typeof agent, who: string, functionName: BrakeWrite, args: readonly unknown[], call: string) {
  const gas = functionName === 'propose' ? PROPOSE_GAS : undefined
  const hash = await signer.writeContract({ address: deployed().brake, abi: brakeAbi, functionName, args, gas } as never)
  return confirm(hash, who, call)
}

/** The viewer's wallet approves and sends. */
async function sendWallet(who: string, call: string, tx: { to: Address; data: Hex; value?: bigint }) {
  return confirm(await walletSend(net.chain, tx), who, call)
}

/** A bare dUSD `transfer`, wrapped as the ERC-7579 single call Brake classifies. */
function payment(to: Address, amount: string): Hex {
  const transfer = encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [to, parseUnits(amount, DECIMALS)] })
  return encodePacked(['address', 'uint256', 'bytes'], [deployed().dusd, 0n, transfer])
}

async function propose(to: string, amount: string, note: string) {
  const w = need()
  const salt = keccak256(toHex(`${note}:${Date.now()}:${Math.random()}`))
  await send(agent, 'Agent', 'propose', [w.account, salt, MODE_SINGLE, payment(to as Address, amount), note], `Brake.propose(${amount} dUSD)`)
}

/** What the agent sees before paying: instant, or how long it would wait. */
async function preview(to: string, amount: string) {
  const w = need()
  const [lane, wait] = await pub.readContract({
    address: deployed().brake,
    abi: brakeAbi,
    functionName: 'preview',
    args: [w.account, MODE_SINGLE, payment(to as Address, amount)],
  })
  return { instant: lane === 0, wait: Number(wait) }
}

/** The owner adds a trusted contact. It goes through the account itself, so only the owner can do it. */
async function trust(contact: string) {
  const w = need()
  const inner = encodeFunctionData({ abi: brakeAbi, functionName: 'setTrusted', args: [w.account, contact as Address, true] })
  const data = encodeFunctionData({ abi: demoAccountAbi, functionName: 'call', args: [deployed().brake, inner] })
  await sendWallet('You (wallet)', 'Brake.setTrusted()', { to: w.account, data })
}

const raw = (op: Op) => op.raw as Raw

async function hold(op: Op) {
  await send(watcher, 'Watcher', 'hold', [need().account, op.id], 'Brake.hold()')
}

/** "Your phone" is the viewer's wallet, which holds the brake key that may cancel. */
async function cancel(op: Op) {
  const r = raw(op)
  const data = encodeFunctionData({ abi: brakeAbi, functionName: 'cancel', args: [need().account, r.salt, r.mode, r.data] })
  await sendWallet('Your phone (wallet)', 'Brake.cancel()', { to: deployed().brake, data })
}

// Open to anyone once the wait is over; the watcher's key pays the gas.
async function execute(op: Op) {
  const r = raw(op)
  await send(watcher, 'Relayer', 'execute', [need().account, r.salt, r.mode, r.data], 'Brake.execute()')
}

/** The plain wallet pays at once. Simulated: no transaction is sent. */
async function twinSend(to: string, amount: string) {
  need()
  await new Promise((r) => setTimeout(r, 400))
  plain.balance -= Number(amount)
  if (to === world?.attacker) plain.sentToAttacker += Number(amount)
  txListeners.forEach((fn) =>
    fn({ who: 'Agent (no Brake)', call: `transfer(${amount} dUSD), simulated`, hash: '—', where: 'simulated, not on chain' }),
  )
}

async function skip(seconds: number) {
  if (!net.canSkipTime) throw new Error(`${net.label} can’t skip time`)
  await pub.request({ method: 'evm_increaseTime' as never, params: [toHex(seconds)] as never })
  await pub.request({ method: 'evm_mine' as never, params: [] as never })
}

// ---------------------------------------------------------------- reads

const STATES: OpState[] = ['unknown', 'waiting', 'ready', 'expired', 'sent', 'canceled']

/** Who gets paid and how much, read back out of the call the agent proposed. */
function readPayment(data: Hex): { to: string; amount: string } {
  const target = `0x${data.slice(2, 42)}` as Address
  const value = BigInt(`0x${data.slice(42, 106)}`)
  const callData = `0x${data.slice(106)}` as Hex
  if (callData === '0x') return { to: target, amount: formatEther(value) }
  try {
    const { functionName, args } = decodeFunctionData({ abi: erc20Abi, data: callData })
    if (functionName === 'transfer') return { to: args[0], amount: formatUnits(args[1], DECIMALS) }
  } catch {
    /* not a token transfer */
  }
  return { to: target, amount: '0' }
}

/** Rebuilds every payment for this run's account from Brake's events plus live state. */
/**
 * Brake's events for this run's account, read forward in small block ranges and kept, so each poll
 * only fetches what's new. Base Sepolia's public RPC answers at most ~200 blocks per log request
 * (about 7 minutes of blocks), so one request from the start of the run stops working mid-story.
 */
const LOG_CHUNK = 150n
async function fetchEvents(w: World, dep: Deployment, from: bigint, to: bigint) {
  const common = { address: dep.brake, abi: brakeAbi, fromBlock: from, toBlock: to, args: { account: w.account } } as const
  const [scheduled, proposed, held] = await Promise.all([
    pub.getContractEvents({ ...common, eventName: 'ERC7579ExecutorOperationScheduled' }),
    pub.getContractEvents({ ...common, eventName: 'Proposed' }),
    pub.getContractEvents({ ...common, eventName: 'Held' }),
  ])
  return { scheduled, proposed, held }
}
type Events = Awaited<ReturnType<typeof fetchEvents>>
let scan: { key: string; next: bigint; events: Events } | null = null
let scanning: Promise<Events> | null = null

function runEvents(w: World, dep: Deployment): Promise<Events> {
  scanning ??= (async () => {
    const key = `${w.account}:${w.fromBlock}`
    if (scan?.key !== key) scan = { key, next: BigInt(w.fromBlock), events: { scheduled: [], proposed: [], held: [] } }
    const latest = await pub.getBlockNumber()
    while (scan.next <= latest) {
      const to = scan.next + LOG_CHUNK - 1n < latest ? scan.next + LOG_CHUNK - 1n : latest
      const got = await fetchEvents(w, dep, scan.next, to)
      scan.events.scheduled.push(...got.scheduled)
      scan.events.proposed.push(...got.proposed)
      scan.events.held.push(...got.held)
      scan.next = to + 1n
    }
    return scan.events
  })().finally(() => {
    scanning = null
  })
  return scanning
}

async function loadOps(): Promise<Op[]> {
  if (!world || !d) return []
  const { scheduled, proposed, held } = await runEvents(world, d)
  const ops = await Promise.all(
    scheduled.map(async (ev) => {
      const a = ev.args as { operationId: Hex; salt: Hex; mode: Hex; executionCalldata: Hex }
      const p = proposed.find((x) => x.args.operationId === a.operationId)
      const [stateIdx, schedule] = await Promise.all([
        pub.readContract({ address: d.brake, abi: brakeAbi, functionName: 'state', args: [a.operationId] }),
        pub.readContract({ address: d.brake, abi: brakeAbi, functionName: 'getSchedule', args: [a.operationId] }),
      ])
      return {
        id: a.operationId,
        raw: { salt: a.salt, mode: a.mode, data: a.executionCalldata } satisfies Raw,
        ...readPayment(a.executionCalldata),
        note: p?.args.note ?? '',
        lane: p?.args.lane === 0 ? 'instant' : 'queued',
        state: STATES[stateIdx],
        scheduledAt: Number(schedule[0]),
        readyAt: Number(schedule[1]),
        heldBy: held.filter((h) => h.args.operationId === a.operationId).map((h) => h.args.brake as string),
      } satisfies Op
    }),
  )
  return ops.reverse()
}

async function balances() {
  if (!world || !d) return { account: '0', twin: '0', attacker: '0' }
  const units = await pub.readContract({ address: d.dusd, abi: demoDollarAbi, functionName: 'balanceOf', args: [world.account] })
  return { account: formatUnits(units, DECIMALS), twin: String(plain.balance), attacker: String(plain.sentToAttacker) }
}

async function chainTime() {
  return Number((await pub.getBlock()).timestamp)
}

// ---------------------------------------------------------------- setup and reuse

/**
 * One wallet approval creates the whole run through DemoWorld.create: a new account the wallet owns,
 * Brake installed with the wallet as "your phone", 20,000 dUSD, Alex trusted, and test ETH for gas to
 * any demo key running low.
 */
async function setUp() {
  const dep = deployed()
  const owner = walletAddress()
  if (!owner) throw new Error('Connect your wallet first')
  const [agentBal, watcherBal] = await Promise.all([
    pub.getBalance({ address: AGENT.address }),
    pub.getBalance({ address: WATCHER.address }),
  ])
  const agentGas = agentBal < net.lowGas ? net.gas : 0n
  const watcherGas = watcherBal < net.lowGas ? net.gas : 0n
  if (networkName === 'anvil') {
    // Local chain only: give whichever wallet connected some ETH, so MetaMask works with any account.
    if ((await pub.getBalance({ address: owner })) < parseEther('1')) {
      await pub.request({ method: 'anvil_setBalance' as never, params: [owner, toHex(parseEther('100'))] as never })
    }
  }
  const friend = randomAddress()
  const data = encodeFunctionData({
    abi: demoWorldAbi,
    functionName: 'create',
    args: [AGENT.address, WATCHER.address, friend, agentGas],
  })
  const receipt = await sendWallet('You (wallet)', 'DemoWorld.create() (account, Brake, dUSD, keys)', {
    to: dep.world,
    data,
    value: agentGas + watcherGas,
  })
  const [created] = parseEventLogs({ abi: demoWorldAbi, eventName: 'Created', logs: receipt.logs })
  if (!created) throw new Error('Setup didn’t create an account')
  setWorld({
    owner,
    account: created.args.account,
    friend,
    sam: randomAddress(),
    attacker: randomAddress(),
    fromBlock: String(receipt.blockNumber),
  })
}

/**
 * Gets a used run ready for another pass without asking the wallet: the agent cancels anything its last
 * run left waiting (a driver may cancel its own proposals), tops the account back up from the open
 * dUSD faucet, and the story gets a new Sam and attacker, so Sam starts untrusted again. False when the
 * run can't be reused today (its instant budget is spent), so the viewer sets up a new one.
 */
async function reuse(w: World): Promise<boolean> {
  setWorld(w)
  // Only look back over a recent run (~an hour of Base blocks); older leftovers stay unexecuted,
  // since nobody but this page relays them, and their recipients are throwaway addresses.
  const recent = (await pub.getBlockNumber()) - BigInt(w.fromBlock) < 2000n
  const leftover = recent ? (await loadOps()).filter((op) => op.state === 'waiting' || op.state === 'ready') : []
  for (const op of leftover) {
    const r = raw(op)
    await send(agent, 'Agent', 'cancel', [w.account, r.salt, r.mode, r.data], 'Brake.cancel() (last run)')
  }
  if (!(await preview(w.friend, '100')).instant) return false
  const units = await pub.readContract({ address: deployed().dusd, abi: demoDollarAbi, functionName: 'balanceOf', args: [w.account] })
  const missing = parseUnits(String(CONFIG.start), DECIMALS) - units
  if (missing > 0n) {
    const hash = await agent.writeContract({ address: deployed().dusd, abi: demoDollarAbi, functionName: 'mint', args: [w.account, missing] })
    await confirm(hash, 'Agent', `dUSD.mint(${formatUnits(missing, DECIMALS)}) top-up`)
  }
  const block = await pub.getBlockNumber()
  setWorld({ ...w, sam: randomAddress(), attacker: randomAddress(), fromBlock: String(block + 1n) })
  return true
}

/**
 * One at a time: React's development mode runs the page's load effect twice, and two reuses at once
 * would send the agent's top-up twice with the same nonce. A second call shares the first one's run.
 */
let busy: Promise<void> | null = null
function once(fn: () => Promise<void>): Promise<void> {
  busy ??= fn().finally(() => {
    busy = null
  })
  return busy
}

async function replay() {
  if (!world) return
  try {
    if (!(await reuse(world))) {
      console.warn('Brake demo: today’s instant budget is spent, so this run needs a new wallet.')
      setWorld(null)
    }
  } catch (e) {
    console.warn('Brake demo: couldn’t reuse the last run, so this run needs a new wallet.', e)
    setWorld(null)
  }
}

/** Picks up this wallet's last run, reusing it if it was played already; otherwise the viewer sets one up. */
async function prepare() {
  const dep = deployed()
  if (!(await pub.getCode({ address: dep.world }))) {
    throw new Error(`Brake isn’t deployed on ${net.label} at the saved address. ${net.unreachable ?? ''}`)
  }
  const owner = walletAddress() ?? (await restoreWallet(net.chain))
  if (!owner) return
  let saved: World | null = null
  try {
    saved = JSON.parse(localStorage.getItem(worldKey(owner)) ?? 'null') as World | null
  } catch {
    saved = null
  }
  if (!saved?.friend) return setWorld(null)
  setWorld(saved)
  try {
    const [b, ops] = await Promise.all([balances(), loadOps()])
    if (ops.length > 0 || Number(b.account) !== CONFIG.start) await replay()
  } catch {
    setWorld(null) // e.g. a restarted local chain no longer has this account
  }
}

export const evm: Chain = {
  id: 'evm',
  name: 'EVM',
  network: net.label,
  explorerName: net.explorerName,
  unreachable: net.unreachable,
  symbol: 'dUSD',
  priceId: '',
  usdPrice: 1,
  priceNote: `dUSD is a test dollar on ${net.label}`,
  plainSimulated: true,
  amounts: { start: String(CONFIG.start), friend: '100', theft: '10000', dailyLimit: String(CONFIG.dailyLimit) },
  people: {
    get friend() {
      return world?.friend ?? ''
    },
    get sam() {
      return world?.sam ?? ''
    },
    get attacker() {
      return world?.attacker ?? ''
    },
  },
  waits: { queue: CONFIG.queue, hold: CONFIG.hold },
  canSkipTime: net.canSkipTime,
  propose,
  preview,
  trust,
  hold,
  cancel,
  execute,
  twinSend,
  skip,
  loadOps,
  balances,
  chainTime,
  onTx: (fn) => {
    txListeners.add(fn)
    return () => void txListeners.delete(fn)
  },
  prepare: () => once(prepare),
  resetDemo: () => once(replay),
  wallet: {
    // With Reown, phone wallets connect too (QR code), so it's not only a browser wallet.
    label: import.meta.env.VITE_REOWN_PROJECT_ID ? 'wallet' : 'browser wallet',
    setupSteps: [
      `Creates a Brake wallet you own, with ${CONFIG.start.toLocaleString()} test dollars (dUSD)`,
      'Gives the agent and the watcher their keys; your wallet is the owner and your phone',
      'Sends a little test ETH to the agent and watcher for gas, if they’re low',
    ],
    connect: () => connectWallet(net.chain),
    restore: () => restoreWallet(net.chain),
    address: walletAddress,
    ready: () => world !== null,
    setUp,
    forget: async () => setWorld(null),
  },
}
