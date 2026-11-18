Related to open-uem/openuem-console#ISSUE (feature request: bulk software updates).

## Summary

Adds the NATS message types used by the agent and the console:
- to list the packages that have an available update on an endpoint,
- to run and queue bulk update runs,
- to report their status,
- to register the console's private winget repository on the agents.

This PR is the base of the related agent and console PRs and should be merged first.

## Changes

### `DeployAction.PackageScope`
New optional field: `machine`, `user`, or empty for the current behaviour.

- **Why:** the agent runs as SYSTEM, so a package installed for a single user can only be updated in that user's session. The scope tells the agent where to update the package.
- **Default:** existing messages don't set it, which keeps today's behaviour (machine-wide).
- **Constants:** `PackageScopeMachine` and `PackageScopeUser`.

### Available updates

| Type | Purpose |
|---|---|
| `AvailableUpdate` | A package with an available update: id, name, branch (flatpak), brew type, installed and available version, source, scope and the users that have it installed (user scope). |
| `ListPackageUpdatesRequest` | Optional body of `agent.listpackageupdates.<uuid>`. With `StatusOnly`, the agent only reports its last update run, without running the package manager. The console's status page uses this to ask many agents cheaply. |
| `AvailableUpdatesResponse` | The agent's answer: available updates, last update run and an error if the package manager couldn't list everything. |

### Update runs

| Type | Purpose |
|---|---|
| `UpdatePackagesRequest` | Starts an update run for the given packages, or for every package with an available update if empty. `RequestedAt` is set for requests queued in JetStream, so agents can ignore stale requests and requests already covered by a later run. |
| `UpdateResult` | The result of one package: failed, already up to date (no applicable update or not installed) and the package manager's message. |
| `UpdateRun` | A bulk update run: start and end time, number of packages, results and an error if the run couldn't be performed. `Running()` and `Counts()` (updated / up to date / failed) are nil safe. |

### Private winget repository

| Type | Purpose |
|---|---|
| `WinGetSourceConfig` | Body of `agent.wingetsource.<uuid>`: the name and URL of the console's winget REST source, and `TrustCA` when the agent must add the OpenUEM CA to its trusted roots (consoles without a reverse proxy that has a public certificate). |

## Compatibility

The change is purely additive. Existing fields, types and JSON names are unchanged. All new fields use `omitempty`, and older agents and consoles ignore them.

## Tests

- `go vet ./...` and `go test ./...` pass.
- New unit tests for `UpdateRun.Running()` and `UpdateRun.Counts()`, including a nil run.
- `WinGetSourceConfig` is tested end to end by the agent and console PRs.

## Merge order

1. **This PR.**
2. **The agent and console PRs.** They temporarily use `replace github.com/open-uem/nats => github.com/devilAPI/nats …`. Once this PR is merged, the replace is replaced by a bump to the merged version.

## Checklist

- [x] Conventional commit title
- [x] Backwards compatible
- [x] Tests added

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FVN6i1yNq2pA1uqE9wBGDr
