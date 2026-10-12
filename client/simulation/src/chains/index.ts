import { sim } from './sim'

/** This demo runs on a simulation: no blockchain, no wallet. */
export const activeChain = sim
export type { Chain, ChainId, Op, Tx } from './types'
