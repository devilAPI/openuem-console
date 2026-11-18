Related to open-uem/openuem-console#ISSUE (feature request: bulk software updates).

## Summary

Profile tasks that install or uninstall a winget package can now use the packages of the
console's private winget repository (Deploy > Software library, see the related console
PR). It also fixes the Docker image build.

## Why

The console hosts its own WinGet REST source with the packages uploaded to its software
library, and the agents register it under the name `OpenUEM`. When the agents worker
turns a profile into a WinGet configuration, the source of every `WinGetPackage` resource
was hardcoded to `winget`, the community repository, so a profile couldn't deploy a
library package to its computers.

## Changes

### Source of winget package tasks
- `models.IsLibraryPackage` checks the software package catalog: the console adds its
  library packages there with the source `openuem`, for the package search.
- `GenerateWinGetConfig` uses the source `OpenUEM` for those packages and `winget` for all
  others, so existing profiles are unchanged.

The console makes the same choice when it runs a single task (`CreateWindowsTaskConfig`),
and its task form's package search now finds library packages too.

### Dockerfile
- The source was copied to `/go`, which is `$GOPATH`, so Go ignored `go.mod`
  (`go: warning: ignoring go.mod in $GOPATH`).
- `golang:1.26.1` sets `GOTOOLCHAIN=local` while `go.mod` requires Go 1.26.2.

The build stage now uses `WORKDIR /src` and `golang:1.26`, like the console's. The
runtime stage is unchanged.

## Tests

- New unit test for `IsLibraryPackage` with SQLite (adds `testify` and `go-sqlite3` as
  test dependencies; `go.sum` already had them).
- `go build ./...`, `go vet ./internal/...` pass.
- End to end with the console stack: a profile applied to all computers, with a task for a
  library package and one for `7zip.7zip`, was requested over NATS (`wingetcfg.profiles`)
  with the agent certificate. The answer has `source: OpenUEM` for the first and
  `source: winget` for the second.
- On a Windows 11 endpoint, the same profile installed both packages: the library's
  Notepad++ from the source `OpenUEM` and `voidtools.Everything` from `winget`.

## Merge order

1. open-uem/nats
2. open-uem/openuem-cert-manager
3. open-uem/openuem-agent
4. open-uem/openuem-console
5. **This PR** (it only reads the catalog the console fills; without the console PR,
   nothing changes)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FVN6i1yNq2pA1uqE9wBGDr
