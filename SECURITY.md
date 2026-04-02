# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| develop | :white_check_mark: |
| others  | :x:                |

## Reporting a Vulnerability

**Please do NOT open a public GitHub issue for security vulnerabilities.**

If you discover a security vulnerability in ADCDEX-SUITES, please report it
responsibly by emailing the maintainers at:

> **security@adcdex.io** *(or open a [GitHub Security Advisory](https://github.com/EdwardMO2/ADCDEX-SUITES/security/advisories/new))*

Please include:
- A description of the vulnerability and its impact.
- Steps to reproduce or a proof-of-concept.
- The affected file(s) and line numbers (if known).
- Any suggested mitigations.

We will acknowledge your report within **48 hours** and aim to provide a fix or
mitigation within **14 days** for critical issues.

## Disclosure Policy

We follow **coordinated disclosure**:
1. Reporter submits the vulnerability privately.
2. Maintainers confirm and reproduce the issue.
3. A fix is developed and tested.
4. The fix is released and the reporter is credited (unless they prefer anonymity).
5. A public advisory is published 7 days after the fix is deployed.

## Repository Governance Recommendations

The following settings are **strongly recommended** to protect the `main` branch
but cannot be enforced via code — they must be configured in repository settings:

### Branch Protection on `main`
- Require pull-request reviews (minimum 1 approval).
- Require status checks to pass before merging (CI must be green).
- Disallow force-pushes.
- Require signed commits.

See: [About branch protection rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-a-branch-protection-rule/about-branch-protection-rules)

### Web Commit Sign-off
Enable **"Require contributors to sign off on web-based commits"** in
**Settings → General → Contributor agreements** for a complete audit trail.

### Dependabot
Enable Dependabot alerts and security updates in **Settings → Advanced Security**
to receive automated notifications about vulnerable dependencies.

## Known Limitations (Testnet Only)

The following known limitations exist in the current codebase and are documented
here for transparency.  They **must** be resolved before any mainnet deployment:

- **`contracts/PerpetualsMarket.sol`**: Price feed is owner-controlled — integrate
  Chainlink Data Feeds before mainnet.
- **`contracts/SwapRouter.sol`**: Swap execution is synthetic (no real pool calls) —
  replace with actual pool interactions before mainnet.
- **`contracts/MarginTradingPool.sol`**: Health factor assumes 1:1 token prices —
  integrate a decentralised oracle before mainnet.
