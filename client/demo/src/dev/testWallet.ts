/**
 * Development only: a stand-in for a browser wallet, so the demo can be driven by automated tests and
 * screen recordings without a wallet extension. Loaded only by the dev server, and only when
 * VITE_DEV_WALLET_KEY is set in .env.local (gitignored). Throwaway test keys only.
 */
import { createPublicClient, createWalletClient, http, type Address, type Chain, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { DEV_WALLET, type Eip1193 } from '../chains/evm/wallet'

export function registerTestWallet(key: Hex, chain: Chain) {
  const account = privateKeyToAccount(key)
  const transport = http(chain.rpcUrls.default.http[0])
  const pub = createPublicClient({ chain, transport })
  const signer = createWalletClient({ account, chain, transport })
  const provider: Eip1193 = {
    async request({ method, params = [] }) {
      switch (method) {
        case 'eth_requestAccounts':
        case 'eth_accounts':
          return [account.address]
        case 'wallet_switchEthereumChain':
        case 'wallet_addEthereumChain':
          return null
        case 'eth_sendTransaction': {
          const tx = params[0] as { to: Address; data?: Hex; value?: Hex }
          return signer.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ? BigInt(tx.value) : undefined })
        }
        default:
          return pub.request({ method, params } as never)
      }
    },
  }
  const detail = Object.freeze({
    info: { uuid: crypto.randomUUID(), name: 'Brake test wallet', icon: 'data:,', rdns: DEV_WALLET },
    provider,
  })
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail }))
  window.addEventListener('eip6963:requestProvider', announce)
  announce()
}
