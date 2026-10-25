# CLAUDE.md — working on Palimpsest

Palimpsest is a self-evolving agent harness on a live SBCL image. A small locked
**kernel** runs the agent loop. The model works through an **evolvable layer**
that it can rewrite, but only through a gate: lint, evaluate, run the full test
suite, then write and commit with git. Read README.md for the user-facing picture.
This file is for whoever builds it out.

## Status: Phase 1 done (green), Phase 2 next

The system loads with no warnings on SBCL 2.6.9 and the FiveAM suite passes
(`asdf:test-system` signals on failure, so CI exits nonzero). The git, rollback,
timeout and backtrace paths were also checked by hand. Nothing has run against the
real API yet.

Requirements: on macOS 27, SBCL must be 2.6.6 or newer (older builds die at startup
with "failed to allocate ... at 0x300100000"), and with SBCL 2.6.9 the Quicklisp dist
must be 2026-01-01 or newer (older named-readtables breaks FSet).

Style: kernel code is written functionally where it can be: Alexandria and FSet,
and mapping and reducing rather than push/incf accumulation. Effects that are the
point (the session, the gate, git, the debugger) stay effectful.

## Commands

```sh
# One-time setup: SBCL plus Quicklisp, and the repo visible to Quicklisp
ln -s "$PWD" ~/quicklisp/local-projects/palimpsest

# Load
sbcl --non-interactive --eval '(ql:quickload :palimpsest)'

# Tests (no API key needed: they use a scripted model)
sbcl --non-interactive --eval '(ql:quickload :palimpsest/tests)' \
     --eval '(asdf:test-system :palimpsest)'

# End-to-end against the real API (needs ANTHROPIC_API_KEY)
sbcl --eval '(ql:quickload :palimpsest)' \
     --eval '(palimpsest:init-layer "/tmp/pal-demo/layer/")' \
     --eval '(palimpsest:start "/tmp/pal-demo/layer/")' \
     --eval '(print (multiple-value-list (palimpsest:run-task "Count the .lisp files in the layer and report the number.")))'
```

Dependencies, all from Quicklisp: alexandria, fset, dexador, com.inuoe.jzon, and fiveam for the tests.

## Map of the code

The files are listed in load order, as given in palimpsest.asd.

| File | Responsibility |
|---|---|
| src/packages.lisp | Three packages: `palimpsest.kernel` (nickname `palimpsest`), `palimpsest.api` (the only kernel symbols the layer may use), and `palimpsest.layer` (where agent code lives). |
| src/config.lisp | Special variables for every knob. Env vars: `PALIMPSEST_MODEL`, `PALIMPSEST_MAX_TOKENS`, `PALIMPSEST_STEP_BUDGET`. |
| src/util.lisp | `with-layer-syntax`, the pausable `with-eval-timeout`, `protocol-error` and `protocol-fail`, rendering, FNV-1a `short-hash`, `resolve-directory`. |
| src/session.lisp | The `session` struct. `session-say` merges consecutive same-role entries, so the transcript always alternates. |
| src/llm.lisp | The Anthropic Messages API over dexador, with retries. `make-scripted-backend` is a fake model. |
| src/protocol.lisp | Reads exactly one action from the last fenced block of a reply (`*read-eval*` off), and checks arity. |
| src/lint.lisp | Symbol-level checks per context: `:eval`, `:test`, `:pure`, `:effect`. |
| src/store.lisp | On-disk layout, definition keys and filenames, the definition index, `load-layer`, `undefine`, and git. |
| src/manifest.lisp | The layer description the model sees, built from source forms. |
| src/gate.lisp | `propose-definition`, `propose-test`, `create-module`, `run-tests`, and restore-on-failure. |
| src/prompts.lisp | The system prompt template (a FORMAT control string) and action help texts. |
| src/debugger.lisp | `retryable`, `eval-with-debugger`, `agent-debug` (the handler-bind conversation), restart invocation, backtraces. |
| src/agent.lisp | Hooks with fallback, context assembly, `next-action`, top-level dispatch, `run-task`. |
| src/main.lisp | `init-layer`, `start`, `protect-kernel`, `reload-layer`, `history`, `rollback`. |
| layer/ | The seed layer: `context` (pure, the `assemble-context` hook), `guidance` (pure, `system-addendum`) and `fs` (effect). |
| tests/ | FiveAM suite `:palimpsest`, covering protocol, lint, gate and debugger. |

Layer layout on disk: `<module>/MODULE.sexp`, `<module>/<category>--<name>--<hash>.lisp`
(exactly one form each), and `<module>/tests/<name>.lisp` (one form, which passes if
it returns true). The hash is FNV-1a over the definition key, for example
`"function assemble-context"`. Lookup is by reading forms, so a wrong filename
causes no duplication, but keep the seed filenames consistent anyway.

## Invariants: do not break these

1. **Errors in agent code are handled by `handler-bind`, never by `handler-case`, until
   the agent gives up.** The stack must be live while the model debugs. This is the
   reason the project is written in Lisp.
2. **Nothing persists without passing the gate.** That means lint, then evaluate, then
   run *all* tests, then write and commit. Any failure restores the previous
   definition, and the image must match the disk afterwards.
3. **Tests are append-only for the agent and must pass when added.** The agent must
   never be able to weaken its own fitness check. Only the operator edits or
   deletes tests.
4. **Module kinds are fixed at creation**, and a definition key belongs to one module.
5. **Hooks never brick the loop.** Every hook call is wrapped. On an error, a timeout or
   malformed output, the kernel falls back to its default and sends a notice to the
   model.
6. **The transcript always alternates roles and ends with `:user` before a model call.**
7. **Time spent in the agent debugger does not count against an evaluation's
   timeout.** `agent-debug` binds `*paused-timeouts*`.
8. **`:eval` cannot define things.** Persistent code goes through `:define`, so that
   the image and the layer directory stay in sync.
9. **Be honest about security.** The lint and package locks prevent accidents. They do
   not stop a determined model. Don't market them as a sandbox, and keep the
   README's safety section accurate.

## Code conventions

- Call `protocol-fail` with a control string plus args. Never pass it pre-formatted
  text, because user data may contain `~`.
- Anything printed for the model goes through `render` or `truncate-string`.
- Read and print layer code only inside `with-layer-syntax`.
- Kernel functions the layer may call must be exported from both the
  `palimpsest.kernel` and `palimpsest.api` package definitions, and listed in
  `*api-text*` in prompts.lisp.
- Messages shown to the model are part of the product. Keep them specific, tell the
  model what to do next, and keep them short.

## Verified SBCL behaviour (Phase 1)

- Backtraces: SBCL ignores the dynamic `*print-length*`/`*print-level*` while
  printing a backtrace; bind `sb-debug:*debug-print-variable-alist*` instead.
  `agent-frames` keeps only the frames between `AGENT-DEBUG` and the kernel's
  `CALL-WITH-EVAL-TIMEOUT` wrapper. The test `backtraces-show-only-the-agents-frames`
  guards this.
- Timer timeouts fire inside `handler-bind`, and pausing during debugger turns works.
- Package locks: `retryable` and binding exported specials work with the kernel locked.
- Stored forms round-trip through `write :readably t`.
- `*mutators*` lists FSet 1.4's real modify macros (there is no `withf` or `lessf`).
- Not yet verified: dexador's return type and `http-request-failed` accessors
  (Phase 2, needs the API).

## Work plan

**Phase 1: green.**
Make the system load without warnings, then make `(asdf:test-system :palimpsest)`
pass. Make the test run exit nonzero on failure so it can run in CI. Add a GitHub
Actions workflow that installs SBCL and Quicklisp and runs the tests.

**Phase 2: real runs.**
Run 3 to 5 real tasks end to end with the API. Keep the transcripts under
`examples/`. Tune the prompt texts based on where the model actually stumbles:
protocol errors, lint rejections it doesn't understand, debugger usage. Add a
`(palimpsest:demo)` that runs a canned task.

**Phase 3: hardening.**
- Evaluate agent code in a child SBCL process (`sb-ext:run-program`), so that crashes
  and heap exhaustion cannot kill the kernel. This is the biggest robustness gap.
- Add structured logs: one JSONL file per task, with every step, action, result and
  gate decision.
- Write a rollback test that runs with git enabled.
- Preserve comments and formatting in stored definitions (today forms are
  re-printed).

**Phase 4: the research part.**
Add fitness signals beyond tests. The idea is a per-deployment evaluation set that
the operator owns, and that gates changes to hooks specifically. Also add frame-local
inspection in the debugger through `sb-di`.

Don't add features that weaken invariants 1 to 9 to make the model's life easier.
If the model keeps hitting a guard, improve the message it receives first.

## Background decisions (so they aren't relitigated)

- **SBCL over Clojure.** The JVM unwinds before handlers run, so it has no real
  restarts. Functional style comes from FSet plus the `:pure` lint instead.
- **Racket was considered.** It has continuations and contracts, but its module system
  resists live redefinition.
- **One definition per file.** This gives clean git diffs, simple replacement, and
  makes rollback able to undefine exactly what a commit added.
- **The model protocol is s-expressions, not JSON tool calls.** The reader validates
  structure, and the action vocabulary is tiny.
- **License is MIT** (could switch to Apache-2.0), and the default model is
  `claude-sonnet-5-5`.
