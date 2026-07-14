# Moonquakes TODO (as of 2026-07-14, post-codegen campaign)

Open items carried out of the v0.4.x → v0.5.0 optimization campaign.
Measurement history and rejection rationale live in
[moonquakes-optimization-candidates.md](moonquakes-optimization-candidates.md);
this file is only the forward-looking list.

## Release 0.5.0 (mechanical)

- [ ] Bump `src/version.zig` to `0.5.0`
- [ ] Release notes for the annotated tag (`Moonquakes v0.5.0 — Near Full`);
      material: ~17 real bug fixes, suite 2.3–3.7x → 1.3–2.9x vs PUC,
      12-benchmark suite, C API additions (mq_seti/mq_geti/mq_len)
- [ ] Housekeeping of untracked root files: `api.md` vs `docs/api.md`
      duplicate, `d`, `errors.md`, `fib.lua`/`fib2.lua`,
      `passing/time.txt` (generated — .gitignore candidate),
      `scripts/bench-fib.zsh`
- [ ] Decide whether the scope docs (`moonquakes-v0.3x/v0.4x-scope.md`)
      and the optimization journal get committed

## Performance (measured levers, in value order)

- [ ] fannkuch residual (~2.7x): integer-array/multi-assign shapes; the
      remaining gap is op density in the swap/rotate loops plus per-arm
      cost. Re-run the executed-op counter before touching anything.
- [ ] Retarget remaining copy-guard sites: return-list staging, CONCAT
      operand staging, multi-assignment value staging, for-header limit
      and step (same `retargetOrMove` helper; each site needs its
      expression-start index)
- [ ] concat 2.0x: result strings copy twice (stack buffer → allocString
      copy). An `allocStringUninit`-style fill-in-place API for >40-byte
      (non-interned) results removes one copy.
- [ ] Native CALL arm generalization beyond math sqrt/sin/cos: candidates
      are 1-arg numeric natives with no error path (floor/ceil/abs need
      integer-result semantics — check each before adding)
- [ ] Per-arm micro-grind (last tier): hot-loop FORLOOP/ADD arms measure
      ~39 machine instructions per bytecode op vs PUC's 33; only worth
      pursuing with pcount discipline against ±3-10% layout noise

## Boundary debts (see TODO(boundary) comments in code)

- [ ] `src/builtin/debug.zig`: 5 remaining `openFile` sites read source
      files from disk inside error/traceback formatting. Direction is
      proven: record at parse/stage time (as done for linedefined and
      metamethod frame names), then delete the scanning.
- [ ] `src/builtin/coroutine.zig`: coroutine.close manipulates the
      target VM's frame state directly; promote to a VM-level unwind API.
- [ ] `name_resolver` ↔ parser emission coupling: the GETTABLE classifier
      pattern-matches emission shapes (SELF emulation, LOADKX keys).
      Cross-referenced in comments; any emission change must update both.

## Semantics backlog (documented divergences, pre-existing)

- [ ] string→number coercion always produces float (`"2"+3 == 5.0`)
- [ ] print float formatting differs from PUC in edge cases
- [ ] exhausted gmatch iterator returns nil (PUC: zero values);
      "^"-anchored gmatch matches once (PUC: never)
- [ ] error-message chunk names are not truncated PUC-style
      (`[string "long source..."]`), and dead-coroutine snapshot frames
      render source as `[string]`
- [ ] `string.dump` chunks are moonquakes-format (PUC header, own body);
      PUC bytecode cannot be loaded
