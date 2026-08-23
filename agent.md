# Single-task agent instructions: audio quality switch / seek root fix

## Scope and recovery

- These instructions apply only to this conversation and the entire change described by
  `docs/audio-quality-switch-root-fix/`.
- After every context compaction, before any inspection, edit, delegation, or test, reread this
  file and `docs/audio-quality-switch-root-fix/01_COORDINATOR_GUIDE.md` in full. Then reread the
  frozen contract and worker documents needed for the active wave; never continue from memory.
- The root agent is the sole coordinator and architecture owner. Do not delegate contract
  interpretation or architecture decisions to workers.

## Authoritative contract

Read and follow, in order:

1. `docs/audio-quality-switch-root-fix/README.md`
2. `docs/audio-quality-switch-root-fix/00_MASTER_PLAN.md`
3. `docs/audio-quality-switch-root-fix/01_COORDINATOR_GUIDE.md`
4. `docs/audio-quality-switch-root-fix/02_FROZEN_CONTRACTS.md`
5. `docs/audio-quality-switch-root-fix/03_WORKER_DISPATCH.md`
6. `docs/audio-quality-switch-root-fix/04_RESEARCH_EVIDENCE.md`
7. `docs/audio-quality-switch-root-fix/05_ACCEPTANCE_MATRIX.md`
8. Every `docs/audio-quality-switch-root-fix/workers/W*.md`

Do not redesign frozen APIs, state machines, HTTP behavior, identity rules, disk ownership,
fallback behavior, performance gates, or exclusions. Resolve a contract gap centrally and update
all affected task documents before implementation continues.

## Preserved baseline

- Baseline HEAD: `460f3c9dd1fd24c6e15537b21d1dd410ebe49307`.
- The initial `git status --short` was:
  - ` D docs/ios-audio-stutter-performance-report-2026-08-11.md`
  - `?? docs/audio-quality-switch-root-fix/`
  - `?? docs/ios-app-performance-optimization-report-2026-08-11.md`
- Treat all of those paths and all later unattributed changes as user assets. Never reset,
  checkout, clean, stash, overwrite, stage, or commit them. Before assigning a writer, inspect its
  whitelist diff and preserve every pre-existing hunk.

## Safety

- Follow root `AGENTS.md`; its Mandatory Build and Test Safety section overrides every conflicting
  command or workflow in this file and the task documents. Never read, print, export, modify, or
  delete production Keychain or secret environment values.
- Never use `security`, production `SecItem*`, the app composition root, authenticated/live or
  mutating API checks, or launch the app.
- Workers must never run `swift build`, `swift test`, compiling `swift run`, `xcodebuild`, or an
  Xcode Build/Test action. Only the root may run offline, guest-safe verification: one command at a
  time, with `--jobs 1`/`-j 1` or `-jobs 1`, after confirming no compiler is already running.
- Never use per-worker or per-run `--scratch-path` or `-derivedDataPath` directories. The root must
  reuse the repository `.build` directory and one stable DerivedData directory. When the root runs
  a check, set the four environment switches from the coordinator guide to empty without inspecting
  their existing values.
- Do not run the complete `Checks/run-api-checks.sh`; its tail runs a live API executable.

## Coordination protocol

- Dispatch only in the waves and dependencies defined by `03_WORKER_DISPATCH.md`.
- Every worker gets its ID, worker guide, dependency state, sole write whitelist, frozen contract
  items, prohibitions, exact validation requirements, Git prohibitions, and structured report
  requirements. Its prompt must explicitly prohibit all build and test execution.
- No two writers may touch one file concurrently. `PlayerController.swift`, `TrackCache.swift`,
  `PlayerCachePerformanceTests.swift`, and `TrackCacheTests.swift` always have one owner.
- Every writer first edits and runs only static diff checks, reports `READY_FOR_TEST_BARRIER`, and
  stays available. Only the root may announce `RUN_TESTS` with a source freeze and then run each
  required check serially.
- During a test barrier nobody edits source or tests. On failure, stop the active test before
  sending only the owning worker `RESUME_EDIT`; never start a replacement or sibling test.
- Before releasing a provider, the root reviews whitelist purity, preserved user hunks, frozen API
  signatures, required failure-path tests, forbidden patterns, and independently reruns its minimum
  suite. W00 and W14 must pass before W06/W07/W08 starts.
- Workers never expand scope, create adapters for provider mismatches, or run Git history/index
  mutations. Cross-file gaps return to the root.

## Completion

- Run W12 wiring only after all production files stabilize; do not change `Package.swift`,
  `iOS/project.yml`, or `Podfile.lock` contrary to the frozen wiring rules.
- Run W13 as a read-only audit with no writers active.
- With no workers active, run every final offline command in section 11 of the coordinator guide,
  including full SwiftPM tests, warnings-as-errors build, iOS build-for-testing, diff check, and
  status check. Run compiler-driving commands strictly one at a time, reuse stable build caches,
  and force SwiftPM `--jobs 1` and `xcodebuild -jobs 1`; never use `Promise.all` or parallel tools.
- Apply `05_ACCEPTANCE_MATRIX.md` literally, including Release performance rerun rules. Any failed
  P0 means the task remains incomplete and the exact blocker is reported.
- The final report must contain every evidence item and residual limitation listed in section 12
  of the coordinator guide, plus confirmation that the initial user changes remain preserved.
