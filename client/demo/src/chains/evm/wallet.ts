import { createWalletClient, custom, toHex, type Address, type Chain as ViemChain, type Hex } from 'viem'

/** An EIP-1193 provider: MetaMask, or any browser wallet. */
export type Eip1193 = { request(args: { method: string; params?: unknown[] }): Promise<unknown> }
type Announced = { info: { name: string; rdns: string }; provider: Eip1193 }

/** The viewer's own browser wallet, used as the account's owner and as "your phone". */
let provider: Eip1193 | null = null
let account: Address | null = null
const REMEMBER = 'brake-evm-wallet'
/** The rdns the development stand-in wallet announces (src/dev/testWallet.ts). */
export const DEV_WALLET = 'dev.brake.testwallet'

/** Wallets announce themselves through EIP-6963; `window.ethereum` is the fallback. */
async function discover(): Promise<Announced[]> {
  const found: Announced[] = []
  const onAnnounce = (e: Event) => found.push((e as CustomEvent<Announced>).detail)
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
  await new Promise((r) => setTimeout(r, 300))
  window.removeEventListener('eip6963:announceProvider', onAnnounce)
  const injected = (window as { ethereum?: Eip1193 }).ethereum
  if (found.length === 0 && injected) found.push({ info: { name: 'Browser wallet', rdns: 'injected' }, provider: injected })
  return found
}

/** Switches the wallet to `chain`, adding it first if the wallet doesn't know it. */
async function switchChain(p: Eip1193, chain: ViemChain) {
  const chainId = toHex(chain.id)
  if ((await p.request({ method: 'eth_chainId' })) === chainId) return
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId }] })
  } catch (e) {
    if ((e as { code?: number }).code !== 4902) throw e
    await p.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId,
          chainName: chain.name,
          nativeCurrency: chain.nativeCurrency,
          rpcUrls: chain.rpcUrls.default.http,
          blockExplorerUrls: chain.blockExplorers ? [chain.blockExplorers.default.url] : undefined,
        },
      ],
    })
  }
}

/** Rdns-style id remembered for Reown sessions, so a reload reconnects through Reown. */
const REOWN = 'reown'

function remember(id: string, p: Eip1193, address: Address | undefined, name: string) {
  if (!address) throw new Error(`${name} didn’t share an account`)
  provider = p
  account = address
  try {
    localStorage.setItem(REMEMBER, id)
  } catch {
    /* reconnecting on reload is a convenience */
  }
  return address
}

async function switchOrExplain(p: Eip1193, chain: ViemChain, name: string, phantom: boolean) {
  try {
    await switchChain(p, chain)
  } catch {
    throw new Error(
      `${name} couldn’t switch to ${chain.name}. Switch it there yourself` +
        (phantom ? ' (Phantom: Settings → Developer Settings → Testnet Mode, then pick Base Sepolia)' : '') +
        ', then try again.',
    )
  }
}

/**
 * Connects the viewer's wallet. With a Reown project ID, Reown's picker offers every kind of wallet,
 * phones included (QR code). Without one, the best browser extension is used: MetaMask, then
 * Phantom, then any other. The development stand-in, when this browser opted in, skips both.
 */
export async function connectWallet(chain: ViemChain): Promise<string> {
  const list = await discover()
  const dev = list.find((x) => x.info.rdns === DEV_WALLET)
  // Read here so the dev path never loads Reown's (large) code.
  const reownProjectId = import.meta.env.VITE_REOWN_PROJECT_ID as string | undefined
  if (!dev && reownProjectId) {
    const { reownConnect } = await import('./reown')
    const { provider: p, address } = await reownConnect(chain)
    await switchOrExplain(p, chain, 'Your wallet', false)
    return remember(REOWN, p, address, 'Your wallet')
  }
  if (list.length === 0) throw new Error('No browser wallet found. Install MetaMask (or another wallet), then reload.')
  const rank = (x: Announced) => (x.info.rdns === 'io.metamask' ? 0 : x.info.rdns === 'app.phantom' ? 1 : 2)
  const w = dev ?? [...list].sort((a, b) => rank(a) - rank(b))[0]
  const accounts = (await w.provider.request({ method: 'eth_requestAccounts' })) as Address[]
  await switchOrExplain(w.provider, chain, w.info.name, w.info.rdns === 'app.phantom')
  return remember(w.info.rdns, w.provider, accounts[0], w.info.name)
}

/** Reconnects without a prompt if this browser connected before. */
export async function restoreWallet(chain: ViemChain): Promise<string | null> {
  let id: string | null = null
  try {
    id = localStorage.getItem(REMEMBER)
  } catch {
    return null
  }
  if (!id) return null
  try {
    if (id === REOWN) {
      const { reownRestore } = await import('./reown')
      const c = await reownRestore(chain)
      return c ? remember(REOWN, c.provider, c.address, 'Your wallet') : null
    }
    const w = (await discover()).find((x) => x.info.rdns === id)
    if (!w) return null
    const accounts = (await w.provider.request({ method: 'eth_accounts' })) as Address[]
    return accounts.length ? remember(w.info.rdns, w.provider, accounts[0], w.info.name) : null
  } catch {
    return null
  }
}

export const walletAddress = () => account

/** Asks the viewer's wallet to approve and send a transaction. Returns its hash. */
export async function walletSend(chain: ViemChain, tx: { to: Address; data: Hex; value?: bigint }): Promise<Hex> {
  if (!provider || !account) throw new Error('Connect your wallet first')
  await switchChain(provider, chain)
  const client = createWalletClient({ account, chain, transport: custom(provider) })
  return client.sendTransaction({ ...tx, account, chain })
}
