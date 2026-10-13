# Licensing Notes

This document records the licensing posture of this repository's two dependencies that carry a non-permissive, dual (reciprocal + commercial) license. It is a **documentation/compliance checkpoint, not a legal opinion** — a qualified legal/licensing review should still occur before production deployment.

## Duende.IdentityServer (and `.AspNetIdentity`, `.EntityFramework`, `.EntityFramework.Storage`, `.Storage`), version 7.3.2

Used by `src/Identity.API` as the OpenID Connect / OAuth2 provider.

- **License**: [Reciprocal Public License (RPL) 1.5](https://github.com/DuendeSoftware/products/blob/main/LICENSE), with a separate [Duende commercial license](https://duendesoftware.com/products/identityserver) for organizations that fall outside the free-use tiers.
- **Free-use tiers** (no commercial license required):
  - Development, testing, and evaluation use.
  - Production use under the **Community Edition**: for-profit organizations with less than $1M USD annual revenue *and* less than $3M USD in capital/funding raised, or non-profit organizations with less than $1M USD annual budget.
- **Commercial license required** for production use by any organization exceeding those revenue/capital/budget thresholds.
- **Status for this repository**: `eShop` is a Microsoft reference/sample application, not a revenue-generating product — the Community Edition free-use tier applies to this codebase as distributed. **Confirmed acceptable for this repository's reference/sample purpose as of 2026-10-13.** Any organization that forks this repository and deploys it to production must independently verify its own eligibility against the thresholds above before going live, and purchase a Duende commercial license if it does not qualify.

## MediatR, version 13.1.0

Used by `src/Ordering.Domain` for in-process domain events.

- **License**: As of **v13.0 (released 2025-07-02)**, MediatR moved from its prior permissive license to the same dual-license model as Duende: [Reciprocal Public License (RPL) 1.5](https://github.com/jbogard/MediatR/blob/master/LICENSE) + a commercial license from [Lucky Penny Software](https://www.lucky-penny.io/).
- **Status for this repository**: The pin in `Directory.Packages.props` is `13.1.0`, which is already past the v13.0 license change — it does **not** predate the new licensing terms. (A stale `<!-- Before license change -->` comment previously sat above this pin and has been corrected; see `docs/dependency-exceptions.md` history and the `Directory.Packages.props` diff for this milestone.)
- Same free-use/commercial-license split applies as RPL 1.5 dual-licensed software generally: evaluate under the same production-use criteria as Duende IdentityServer above. **Confirmed acceptable for this repository's reference/sample purpose as of 2026-10-13.** Any organization deploying a fork of this repository to production should independently verify its own licensing obligations and purchase a Lucky Penny Software commercial license if required.

## Recommendation

Both dependencies' free-use tiers are reasonably assumed to cover this repository's use as a public, non-commercial Microsoft reference sample. This is **not** a substitute for a qualified legal review: before any organization ships a production deployment built on this codebase, it should have its legal/licensing team independently confirm eligibility under the current RPL 1.5 + commercial terms for both Duende IdentityServer and MediatR, as license terms and thresholds are subject to change by the respective vendors.
