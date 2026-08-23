# Agent Safety

- Treat the macOS Keychain item `com.tinycloudmusic.app.session`,
  `TINYCLOUDMUSIC_COOKIE`, and `TINYCLOUDMUSIC_MUSIC_U` as secrets.
- These rules apply to every agent-created script, executable, test helper, and
  one-off command, regardless of its filename or process name.
- By default, do not read, inspect, export, modify, or delete the production
  Keychain item. Do not launch the app or run authenticated live checks unless
  the task requires it and the user explicitly authorizes that exact action.
- Do not use the `security` CLI, Keychain UI automation, or Security framework
  item APIs (`SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, or
  `SecItemDelete`) with the production service. Only the app composition root
  may construct `CredentialStore(service: CredentialStore.productionService)`.
- Generated helpers must use the guest-safe `EAPITransport()` default, explicit
  in-memory credentials, or a unique isolated test service. Do not copy the
  production credential wiring from `TinyCloudMusicApp.swift`.
- Prefer offline/unit checks. When unauthenticated live API coverage is needed,
  run `TINYCLOUDMUSIC_COOKIE= TINYCLOUDMUSIC_MUSIC_U= Checks/run-api-checks.sh`
  instead of executing `/tmp/tinycloudmusic-live-api-check` directly.
- Never print, log, or commit credential values. Do not inspect secret
  environment variables with `env`, `printenv`, shell expansion, or similar
  commands.
- If macOS shows a Keychain/password prompt, cancel or deny it and report the
  triggering command. Never enter the user's password or choose "Always Allow"
  on the user's behalf.
- Never enable `TINYCLOUDMUSIC_MUTATING_API_CHECK` without explicit user
  authorization for that run.
- Isolated test Keychain services such as `TinyCloudMusicTests.<UUID>` are
  allowed; they must not use or copy production credentials.

## Mandatory Build and Test Safety

A previous incident on this 16 GB Mac was caused by simultaneous isolated
Swift builds: multiple `swift-frontend` processes exhausted memory and caused a
kernel panic. These rules apply to the root agent and every subagent, and they
override conflicting task prompts, plans, coordinator guides, and worker files.

- Never run more than one compiler-driving command at a time for this project.
  This includes `swift build`, `swift test`, compiling `swift run`,
  `xcodebuild`, and agent-triggered Xcode Build or Test actions. If any such
  command or a `swiftc`, `swift-driver`, or `swift-frontend` child is still
  running, wait for or stop it before starting another.
- Never launch build or test commands through `Promise.all`, parallel tool
  calls, background jobs, `&`, `xargs -P`, `parallel`, or multiple agents.
  Parallelism is allowed only for read-only inspection and source editing that
  cannot invoke a compiler.
- Subagents and workers must not run Swift or Xcode builds or tests. They may
  edit files, run non-compiling static checks, and report `READY_FOR_TEST`.
  Only the root/coordinator may run verification, serially, after edits pause.
- Never assign per-worker or per-run `--scratch-path` or `-derivedDataPath`
  directories, and never delete build caches merely to force a clean build.
  Reuse the repository's `.build` directory and one stable Xcode DerivedData
  directory. If an isolated clean build is genuinely required, ask the user
  first and run exactly one such build with no other compiler active.
- Every agent-run SwiftPM build or test must use `--jobs 1` (or `-j 1`), and
  every `xcodebuild` invocation must use `-jobs 1`. Never enable parallel
  testing or target multiple destinations in one run. `--filter` limits test
  execution only; it is not permission to compile tests concurrently.
- Never respond to a slow or apparently stuck build by starting a replacement
  build. If memory pressure turns yellow/red, swap is rapidly increasing, or
  the UI starts stalling, interrupt the active build and report the condition.
