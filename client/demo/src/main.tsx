import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import type { Hex } from 'viem'
import App from './App.tsx'
import { viemChain } from './chains/evm'

// Development only: if .env.local sets VITE_DEV_WALLET_KEY (a throwaway test key), register a
// stand-in wallet so automated runs can approve transactions. Only in a browser that opted in with
// localStorage "brake-dev-wallet" = "on" (the test browser), so a person's own browser always uses
// their real wallet. Never in builds; the key never goes in a URL or in storage.
const optedIn = (() => {
  try {
    return localStorage.getItem('brake-dev-wallet') === 'on'
  } catch {
    return false
  }
})()
const devKey = import.meta.env.DEV && optedIn ? (import.meta.env.VITE_DEV_WALLET_KEY as Hex | undefined) : undefined
if (devKey) (await import('./dev/testWallet')).registerTestWallet(devKey, viemChain)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
