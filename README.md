# IMDBuyAndBurn

A contract on Base that turns USDC into burned IMD. It receives the Lobby (neighborslobby.com) payouts of
`@imdpepe`, the IMD swarm's account on Lobby, and anyone can make it buy IMD with them and burn it.

- **IMD on Base is Fren Pet** (`0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`). The Ethereum IMD token
  (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`) is a LayerZero OFT whose Base peer is an adapter that locks Fren Pet.
- **No owner, no withdraw.** USDC can only leave through `buyAndBurn()`. The contract does not accept ETH.
- **`buyAndBurn()`**, callable by anyone when the contract holds at least $5 of USDC and the price window is between 30
  minutes and 2 hours old: spends up to $1,000 and at most 0.1% of either pool's reserves (a thin pool burns in smaller
  steps instead of locking; a remainder under $5 is spent with the last capped burn rather than stranded), swaps
  USDC -> WETH -> Fren Pet through the Uniswap v2 pairs `0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C` (USDC/WETH) and
  `0xDE66c35e01ED8e619Bf092352338ef94f2327337` (WETH/Fren Pet), and has the second pair send the tokens straight to
  `0x000000000000000000000000000000000000dEaD`.
- **Price check.** Before it trades, a burn compares the route's marginal price (the pools' reserves, without fees or
  impact) with its time-weighted average over the window, and reverts if IMD is more than 3% dearer. A cheaper IMD passes.
- **Window.** It starts at the last burn, at deployment, or at `observe()`. `observe()` restarts it only when it is older
  than 2 hours, when no burn can run anyway, so it can never delay a burn. A keeper that finds an old window calls
  `observe()`, waits 30 minutes, then calls `buyAndBurn()`.
- **Economics.** Moving a pool's price by d costs about 0.3% x d x its reserve in round-trip fees, while a burn of at most
  0.1% of that reserve loses at most about d x the burn. A sandwich therefore costs its author about three times what the
  burn loses, unless the author owns more than two thirds of the pool's liquidity. Fren Pet's 4% buy and sell fees make
  the WETH/Fren Pet leg costlier still.
- **`burnHeld()`** sends any Fren Pet that was sent to the contract directly to `0x…dEaD`.
- Fren Pet charges a 4% buy fee and enforces size limits, but exempts transfers to `0x…dEaD` from both.

## Trust assumptions

- **Fren Pet's owner** (`0x54C4DD8C2E124c65f55E1E096aB1fb6543e1206c`) has not renounced its blacklist. Blacklisting
  `0x…dEaD`, the WETH/Fren Pet pair or this contract stops every burn, and the USDC then stays in this contract for good
  (there is no owner and no rescue path). The owner can also remove `0x…dEaD`'s fee exemption: burns still run, but up
  to Fren Pet's buy fee (4% today, 5% at most) of each purchase goes to the Fren Pet contract. The `Burned` event reports
  both the amount bought and the amount burned.
- **Circle** can blacklist this contract on USDC, or pause or upgrade USDC, with the same effect as a blacklist above.
- Anyone can move the route price before a burn as long as IMD ends up at most 3% dearer than the window average. After
  a real price drop inside the window, the average sits above the market, so that room is larger. Either way it is
  griefing at a loss (see Economics), not a profit, for anyone who owns less than two thirds of a pool's liquidity.
- The two-hop average is the product of the two pools' averages, which differs slightly from the route's true average
  when ETH moves a lot inside one window; at most it makes a burn wait for a new window.

## Test

The tests run against a fork of Base mainnet:

```
BASE_RPC=https://base-rpc.publicnode.com forge test -vv
```

## Audits

- IMD swarm audit, job `de9e10c6-3380-4fb8-8808-91858e518099`, commit `4e49d40`: 1 medium, 3 low, 2 info; fixed or
  documented in `2042849`. Proof of the medium: `test/ThinPoolLock.t.sol`.
- IMD swarm re-audit, job `dca64686-c3d3-4230-b0ef-7dcc623af6d6`, commit `2042849`: 3 low, 3 info; fixed or documented in
  `e70a156`. Proofs: `test/PokeGrief.t.sol` (adapted) and `test/SandwichWithinTolerance.t.sol`.
- IMD swarm re-check, job `b2cad286-240a-4884-b169-187e7d838051`, commit `e70a156`: 1 medium, 3 low, 2 info. The medium (a
  burn window with no maximum age) and the pending-window lows are removed by the bounded window in this commit; the
  size bound is now 0.1%. Commit `e70a156` was deployed at `0xcf943c7787e1f4503594e04fbd3b969157f34120` before this check
  and is retired: do not send it funds.

## Audit scope

`src/IMDBuyAndBurn.sol` (the only contract). Questions for reviewers: can USDC or the burned IMD leave in any way other
than intended; can a caller make a burn execute at a bad price (sandwich, TWAP manipulation, window griefing); can the
contract get stuck so that USDC can never be burned; is the UQ112x112 TWAP math correct, including wrap-around and the
counterfactual cumulative price.
