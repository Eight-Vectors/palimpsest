# Palimpsest

A self-evolving agent harness on a live Common Lisp image.

Most agent harnesses are fixed at the moment they are written: their tools, their context management and their error handling are whatever their authors imagined. Palimpsest gives the model a small protected kernel and an **evolvable layer** that it can rewrite while it works. Every change to the layer is linted, tested against a regression suite the agent cannot weaken, and committed to git. Over time the harness becomes shaped by the deployment it runs in.

> **Status: pre-alpha.** The design is settled; the code is young. Start with `(asdf:test-system :palimpsest)`.

## Why Common Lisp

- **Conditions and restarts.** When the agent's code fails, the stack is not unwound. The agent gets the live condition, the available restarts and a backtrace, can redefine the broken function, and then resumes from the point of failure. Work done before the error is not lost.
- **Live redefinition.** Functions, macros and CLOS classes can be redefined in the running image, and existing instances are migrated.
- **A frozen standard.** ANSI Common Lisp has not changed since 1994, so what the model learned about the language is still true.
- **Introspection.** `describe`, `documentation` and `apropos` let the agent discover what exists.

## How it works

```
 ┌──────────────── SBCL image ────────────────┐
 │  kernel (locked)                           │
 │   step loop · protocol · lint · gate       │
 │   debugger · git · Anthropic client        │
 │        │ calls hooks, falls back on error  │
 │        ▼                                   │
 │  layer (evolvable)  ◀── loaded from ───────┼──  layer/ (a git repo)
 │   context · guidance · fs · …              │     <module>/MODULE.sexp
 └────────────────────────────────────────────┘     <module>/<definition>.lisp
                                                    <module>/tests/<name>.lisp
```

Each step, the kernel builds a system prompt (rules, plus a **manifest** of the layer generated from docstrings and lambda lists), asks the layer's `assemble-context` hook which transcript entries to show, calls the model, and reads exactly one action from the reply:

| Action | What happens |
|---|---|
| `(:eval FORM)` | Evaluate now. Errors enter the debugger with the stack live. May not contain definitions. |
| `(:define "module" FORM)` | Lint, evaluate, run **all** tests. Only if everything passes is it written and committed; otherwise the previous definition is restored. |
| `(:module "name" :pure\|:effect "doc" (deps))` | Create a module. Its kind is permanent. |
| `(:test "module" "name" FORM)` | Add a regression test. It must pass now, and tests are append-only. |
| `(:done "summary")` | Finish. |

In the debugger the agent can also `(:restart name-or-index args…)`, `(:backtrace)` or `(:give-up "why")`. Wrapping fragile steps in `(retryable ("description") …)` gives it a `retry` restart to resume at. Time spent debugging does not count against the evaluation's timeout.

**Pure and effect modules.** A `:pure` module may not mutate state or do I/O (no `setf`, `push`, `sort`, files, network or shell). The agent is told to use [FSet](https://github.com/slburson/fset) for functional data structures. `:effect` modules may do anything else. The check is shallow: it looks at the symbols a definition uses, not at what the functions it calls do.

**Hooks.** The kernel calls `assemble-context` and `system-addendum` in the layer when they exist, and falls back to its own defaults if they are missing, signal an error, time out or return something malformed. The agent can therefore rewrite its own context management and prompt guidance without being able to brick the loop.

## Quick start

Requirements: SBCL (2.6.6 or newer on macOS 27), Quicklisp, git, and an Anthropic API key.

```lisp
;; Clone into ~/quicklisp/local-projects/palimpsest, then in SBCL:
(ql:quickload :palimpsest)

(palimpsest:init-layer "~/agents/demo/layer/")   ; copy the seed layer, git init
(palimpsest:start "~/agents/demo/layer/")        ; load it, run its tests, lock the kernel

;; ANTHROPIC_API_KEY must be set in the environment.
(multiple-value-bind (result status session)
    (palimpsest:run-task "List the five largest files under ~/Downloads and say what each one is.")
  (palimpsest:print-transcript session)   ; the whole run, step by step
  (values result status))                 ; status is :done or :budget-exhausted

(palimpsest:history)                  ; what the agent changed in the layer
(palimpsest:rollback 1)               ; undo its last change, in the image as well as on disk
```

Configuration lives in special variables: `*model*` (or `PALIMPSEST_MODEL`), `*step-budget*`, `*eval-timeout*`, `*context-max-chars*`, `*use-git*` and others in `src/config.lisp`. `*llm-backend*` is any function of `(system messages)`, so other providers are a few lines away; `make-scripted-backend` is a fake model for tests and demos.

## Safety model

Be clear about what the guards do and do not do.

The agent runs arbitrary code with the privileges of your SBCL process. The in-process protections — package locks on the kernel, the lint, append-only tests, the gate and git history — protect the harness from **accidents and drift**. They do not stop a determined model: Lisp is too reflective for a syntactic check to be a security boundary.

The security boundary is the operating system. Run Palimpsest in a container or VM with only the files, network and credentials the task needs, and review the layer's `git log` as you would any other contributor's commits.

## Layout

```
palimpsest.asd
src/       kernel: packages, config, protocol, lint, store, manifest, gate,
           prompts, debugger, agent loop, operator entry points
layer/     the seed layer copied by INIT-LAYER
tests/     kernel tests (FiveAM, scripted model, no API key needed)
```

## Open questions and roadmap

- **Fitness beyond tests.** Tests stop regressions; they do not tell the harness whether a change made it better. Deployment-level signals are the interesting research problem.
- **Out-of-process evaluation.** Run agent code in a child image so that a crash or runaway allocation cannot take down the kernel.
- **Richer debugging.** Frame-local variable inspection through `sb-di`, and returning from a chosen frame.
- **Better definition storage.** Keep comments and formatting (forms are currently re-printed), support `(setf name)` functions, and allow diff-style edits to long definitions.
- **Portability.** The kernel is SBCL-only today because of package locks and backtraces.

## License

MIT. See [LICENSE](LICENSE).
