# IMDBuyAndBurn

A contract on Base that turns USDC into burned IMD. It receives the Lobby (neighborslobby.com) payouts of
`@imdpepe`, the IMD swarm's account on Lobby, and anyone can make it buy IMD with them and burn it.

- **IMD on Base is Fren Pet** (`0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105`). The Ethereum IMD token
  (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`) is a LayerZero OFT whose Base peer is an adapter that locks Fren Pet.
- **No owner, no withdraw.** USDC can only leave through `buyAndBurn()`. The contract does not accept ETH.
- **`buyAndBurn()`**, callable by anyone when the contract holds at least $5 of USDC: spends up to $1,000 per call,
  swaps USDC -> WETH -> Fren Pet through the Uniswap v2 pairs `0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C`
  (USDC/WETH) and `0xDE66c35e01ED8e619Bf092352338ef94f2327337` (WETH/Fren Pet), and has the second pair send the
  tokens straight to `0x000000000000000000000000000000000000dEaD`.
- **Price check.** Each burn compares the pools' output with their time-weighted average price since the previous
  burn (at least 30 minutes earlier) and reverts if the output is more than 3% below it. This stops an atomic sandwich.
  `poke()` starts a fresh window only when the last one is older than 6 hours.
- **`burnHeld()`** sends any Fren Pet that was sent to the contract directly to `0x…dEaD`.
- Fren Pet charges a 4% buy fee and enforces size limits, but exempts transfers to `0x…dEaD` from both. Its owner can
  still blacklist addresses.

## Test

The tests run against a fork of Base mainnet:

```
BASE_RPC=https://base-rpc.publicnode.com forge test -vv
```

## Audit scope

`src/IMDBuyAndBurn.sol` (the only contract). Questions for reviewers: can USDC or the burned IMD leave in any way other
than intended; can a caller make a burn execute at a bad price (sandwich, TWAP manipulation, window griefing); can the
contract get stuck so that USDC can never be burned; is the UQ112x112 TWAP math correct, including wrap-around and the
counterfactual cumulative price.
