# IMDBuyAndBurn

A contract on Base that turns USDC into burned IMD. It receives the Lobby (neighborslobby.com) payouts of
`@imdpepe`, the IMD swarm's account on Lobby, and anyone can make it buy IMD with them and burn it.

- **IMD on Base is Fren Pet** (`0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`). The Ethereum IMD token
  (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`) is a LayerZero OFT whose Base peer is an adapter that locks Fren Pet.
- **No owner, no withdraw.** USDC can only leave through `buyAndBurn()`. The contract does not accept ETH.
- **`buyAndBurn()`**, callable by anyone when the contract holds at least $5 of USDC: spends up to $1,000 per call,
  and at most 0.25% of either pool's reserves (a thin pool burns in smaller steps instead of locking), swaps USDC -> WETH -> Fren Pet through the Uniswap v2 pairs `0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C`
  (USDC/WETH) and `0xDE66c35e01ED8e619Bf092352338ef94f2327337` (WETH/Fren Pet), and has the second pair send the
  tokens straight to `0x000000000000000000000000000000000000dEaD`.
- **Price check.** Before it trades, each burn compares the route's marginal price (the pools' reserves, without fees
  or impact) with its time-weighted average since the previous burn (at least 30 minutes earlier), and reverts if IMD is
  more than 3% dearer. This stops an atomic sandwich. Fees and the trade's own impact are bounded by the size cap.
  A burn that is capped leaves at least $5 behind, so the remainder can always be burned later.
- **`poke()`**: when the burn window is older than 6 hours, anyone can open a second, pending window. After 30 minutes a
  burn may use either window, so a long price trend cannot block burns for long, and `poke()` cannot delay a burn.
- **`burnHeld()`** sends any Fren Pet that was sent to the contract directly to `0x…dEaD`.
- Fren Pet charges a 4% buy fee and enforces size limits, but exempts transfers to `0x…dEaD` from both.

## Trust assumptions

- **Fren Pet's owner** (`0x54C4DD8C2E124c65f55E1E096aB1fb6543e1206c`) has not renounced its blacklist. Blacklisting
  `0x…dEaD`, the WETH/Fren Pet pair or this contract stops every burn, and the USDC then stays in this contract for good
  (there is no owner and no rescue path). The owner can also remove `0x…dEaD`'s fee exemption: burns still run, but up
  to Fren Pet's buy fee (4% today, 5% at most) of each purchase goes to the Fren Pet contract. The `Burned` event reports
  both the amount bought and the amount burned.
- **Circle** can blacklist this contract on USDC, or pause or upgrade USDC, with the same effect as a blacklist above.
- An attacker can move the route price by up to 3% before a burn without making it revert. A burn at the edge of that
  tolerance also pays the pools' fees and its own impact, so it realizes up to about 4% less IMD than at the average
  price. Such a sandwich does not pay its author: one burn spends at most 0.25% of the USDC/WETH reserve, which is
  below the 0.3% round-trip fee on that pair (the re-audit's proof, `test/SandwichWithinTolerance.t.sol`).

## Test

The tests run against a fork of Base mainnet:

```
BASE_RPC=https://base-rpc.publicnode.com forge test -vv
```

## Audits

- IMD swarm audit, job `de9e10c6-3380-4fb8-8808-91858e518099`, commit `4e49d40`: 1 medium, 3 low, 2 info. All are fixed or
  documented in commit `2042849`. The medium's proof is `test/ThinPoolLock.t.sol`.
- IMD swarm re-audit, job `dca64686-c3d3-4230-b0ef-7dcc623af6d6`, commit `2042849`: no high or medium; 3 low, 3 info. All are
  fixed or documented in the next commit (pending window for `poke()`, a burnable remainder, the 0.25% size bound). Its
  proofs are `test/PokeGrief.t.sol` and `test/SandwichWithinTolerance.t.sol`.

## Audit scope

`src/IMDBuyAndBurn.sol` (the only contract). Questions for reviewers: can USDC or the burned IMD leave in any way other
than intended; can a caller make a burn execute at a bad price (sandwich, TWAP manipulation, window griefing); can the
contract get stuck so that USDC can never be burned; is the UQ112x112 TWAP math correct, including wrap-around and the
counterfactual cumulative price.
