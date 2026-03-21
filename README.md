# ADCDEX-SUITES

A DeFi protocol suite implementing a decentralised exchange (DEX), bonding
mechanism, perpetuals market, flash loans, margin trading, CBDC bridge, and
compliance layer — built with Solidity and Hardhat.

> ⚠️ **This codebase is under active development and has NOT been audited for
> mainnet use.** See [SECURITY.md](./SECURITY.md) for known limitations and
> the responsible disclosure policy.

---

## Contracts

| Contract | Description |
|---|---|
| `contracts/BondingMechanism.sol` | Timelocked discount & vesting mechanism |
| `contracts/CBDCBridge.sol` | Central Bank Digital Currency bridge |
| `contracts/ComplianceLayer.sol` | KYC/AML compliance and sanctions screening |
| `contracts/FlashLoanProvider.sol` | Single-transaction flash loans (0.05% fee) |
| `contracts/GlobalSettlementProtocol.sol` | Multi-currency settlement with cross-chain support |
| `contracts/MarginTradingPool.sol` | Overcollateralised lending and margin trading |
| `contracts/MultiPoolStakingRewards.sol` | Multi-pool yield farming with NFT boost |
| `contracts/PerpetualsMarket.sol` | Perpetuals with leverage, funding rates, liquidation |
| `contracts/RouterQuote.sol` | Off-chain quote engine for swap routes |
| `contracts/StablecoinPools.sol` | Stablecoin DEX with concentrated liquidity |
| `contracts/SwapRouter.sol` | Multi-hop swap routing engine |
| `contracts/legacy/` | Legacy root-level contracts (for reference only) |

---

## Prerequisites

- Node.js ≥ 20
- npm ≥ 10

---

## Setup

```bash
npm install
```

---

## Compile

```bash
npx hardhat compile
```

---

## Test

```bash
npx hardhat test
```

---

## Lint

```bash
npx solhint 'contracts/**/*.sol'
```

---

## Security

Please read [SECURITY.md](./SECURITY.md) for:
- How to report vulnerabilities responsibly.
- Repository governance recommendations (branch protection, signed commits).
- Known limitations that must be resolved before mainnet deployment.

---

## License

[MIT](./LICENSE)
