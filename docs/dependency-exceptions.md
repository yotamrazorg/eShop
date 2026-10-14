# Dependency Exceptions

This document catalogues every package version in [`Directory.Packages.props`](../Directory.Packages.props) that is pinned to a prerelease (preview/beta) build because no stable release exists upstream yet. Each entry is a deliberate, time-boxed exception rather than an oversight — it should be re-checked against the linked NuGet feed before each subsequent modernization pass, and the pin should move to the first available stable release.

## Current exceptions (confirmed via NuGet as of 2026-10-13)

| Package | Pinned version | Why | NuGet feed |
|---|---|---|---|
| `Aspire.Hosting.Dotnet` | `13.6.1-preview.1.26506.6` | No stable release exists; remains prerelease-only on the 13.6.x Aspire train. Pinned to the latest available preview build. | [nuget.org/packages/Aspire.Hosting.Dotnet](https://www.nuget.org/packages/Aspire.Hosting.Dotnet) |
| `Aspire.Hosting.Foundry` | `13.6.1-preview.1.26506.6` | Same as above. | [nuget.org/packages/Aspire.Hosting.Foundry](https://www.nuget.org/packages/Aspire.Hosting.Foundry) |
| `Aspire.Azure.AI.OpenAI` | `13.6.1-preview.1.26506.6` | Same as above. | [nuget.org/packages/Aspire.Azure.AI.OpenAI](https://www.nuget.org/packages/Aspire.Azure.AI.OpenAI) |
| `OpenTelemetry.Instrumentation.GrpcNetClient` | `1.19.1-beta.1` | No stable release exists; this instrumentation package has never shipped past `-beta`/`-rc`. Pinned to the latest available beta build, matching the `1.19.x` line its stable OpenTelemetry siblings (`OpenTelemetry.Extensions.Hosting`, `.Instrumentation.AspNetCore`, `.Instrumentation.Http`, `.Instrumentation.Runtime`) are already on. | [nuget.org/packages/OpenTelemetry.Instrumentation.GrpcNetClient](https://www.nuget.org/packages/OpenTelemetry.Instrumentation.GrpcNetClient) |

## Re-check cadence

Re-check this table whenever `Directory.Packages.props` is next touched for a dependency pass (at minimum, once per modernization milestone). For each row:

1. Query the package's NuGet `v3-flatcontainer` index for a version without a `-preview`/`-beta`/`-rc` suffix.
2. If a stable release now exists, bump the pin to it, remove the corresponding inline `DEPENDENCY EXCEPTION` comment in `Directory.Packages.props`, and remove the row from this table.
3. If no stable release exists yet, bump the pin to the latest available prerelease build, rebuild and retest the solution, and update the version number in both the inline comment and this table.

## History

- **2026-10-13**: All four packages re-pinned from their prior prerelease builds (`Aspire.*` at `13.6.0-preview.1.26479.8`, `OpenTelemetry.Instrumentation.GrpcNetClient` at `1.15.0-beta.1`) to the latest available prerelease build at the time. No stable release existed for any of the four.
