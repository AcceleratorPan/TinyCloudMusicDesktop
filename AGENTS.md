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
