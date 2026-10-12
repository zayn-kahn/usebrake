import { createAppKit } from '@reown/appkit'
import { EthersAdapter } from '@reown/appkit-adapter-ethers'
import { baseSepolia, foundry } from '@reown/appkit/networks'
import type { Address, Chain as ViemChain } from 'viem'
import type { Eip1193 } from './wallet'

/**
 * Reown AppKit: one picker for browser extensions, mobile wallets over WalletConnect (QR code) and
 * hundreds more. A real phone wallet can then play "your phone", the brake key that cancels.
 * The project ID is public (it identifies the app to Reown's relay) and comes from .env.
 */
const reownProjectId = (import.meta.env.VITE_REOWN_PROJECT_ID as string | undefined) ?? ''

type Kit = ReturnType<typeof createAppKit>
let kit: Kit | null = null

function appKit(chain: ViemChain): Kit {
  kit ??= createAppKit({
    adapters: [new EthersAdapter()],
    networks: [chain.id === baseSepolia.id ? baseSepolia : foundry],
    projectId: reownProjectId,
    metadata: {
      name: 'Brake demo',
      description: 'A brake pedal for wallets run by AI agents',
      url: window.location.origin,
      icons: [`${window.location.origin}/favicon.svg`],
    },
    features: { analytics: false, email: false, socials: false, swaps: false, onramp: false, send: false, receive: false },
    themeMode: 'light',
  })
  return kit
}

function connected(k: Kit): { provider: Eip1193; address: Address } | null {
  const address = k.getAddress() as Address | undefined
  const provider = k.getWalletProvider() as Eip1193 | undefined
  return k.getIsConnectedState() && address && provider ? { provider, address } : null
}

/** Opens Reown's wallet picker; resolves once a wallet connects, rejects if the picker is closed first. */
export function reownConnect(chain: ViemChain): Promise<{ provider: Eip1193; address: Address }> {
  const k = appKit(chain)
  const now = connected(k)
  if (now) return Promise.resolve(now)
  return new Promise((resolve, reject) => {
    let opened = false
    const stop = () => {
      unAccount()
      unState()
    }
    const unAccount = k.subscribeAccount(() => {
      const c = connected(k)
      if (!c) return
      stop()
      k.close()
      resolve(c)
    })
    const unState = k.subscribeState((s) => {
      if (s.open) opened = true
      else if (opened && !connected(k)) {
        stop()
        reject(new Error('No wallet picked yet. Click Connect to choose one.'))
      }
    })
    k.open().catch((e) => {
      stop()
      reject(e)
    })
  })
}

/** Picks up a Reown session from an earlier visit, if the wallet is still connected. */
export async function reownRestore(chain: ViemChain): Promise<{ provider: Eip1193; address: Address } | null> {
  const k = appKit(chain)
  for (let i = 0; i < 20; i++) {
    const c = connected(k)
    if (c) return c
    await new Promise((r) => setTimeout(r, 150))
  }
  return null
}
