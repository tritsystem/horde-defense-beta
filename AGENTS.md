# AGENTS.md — horde-defense-beta agent rules

Any AI agent (Hermes, Claude Code, etc.) working in this repo MUST follow these rules. They are distilled from ~15 real sessions on 2026-08-24; every rule here was learned from an actual failure.

## Environment facts
- Real working dir is THIS directory (`G:\extra horde defense\horde-extra-branch\horde-beta-version-1`). Ignore any stray `OneDrive\Documents\horde-beta-version-1` copy.
- Godot 4.7 binary NOT on PATH (note: the ".exe" is actually a FOLDER containing both binaries):
  - GUI: `C:\Users\gbran\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64.exe`
  - Headless/console (use this): `C:\Users\gbran\Downloads\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe`
- Ollama available locally: qwen2.5-coder:7b/14b back HordeLLM.gd combat barks. Don't assume network APIs.

## Mandatory verification gate (never skip)
After ANY .gd/.tscn change, run a real headless boot before claiming success:

```bash
cd "G:/extra horde defense/horde-extra-branch/horde-beta-version-1"
"C:/Users/gbran/Downloads/Godot_v4.7-stable_win64_console.exe" --headless --path . main.tscn --quit-after 2
```

- Grep output for: `Parse Error|Nonexistent function|Invalid get index|Invalid call|SCRIPT ERROR`
- KNOWN-HARMLESS pre-existing lines (do not chase): SplitScreenManager.gd:258 "add_child on null"; MainMenu.tscn:15 ext_resource warning.
- ALWAYS kill the Godot process afterward — it doesn't reliably self-exit:
  `powershell.exe -NoProfile -Command "Get-Process *Godot* -ErrorAction SilentlyContinue | Stop-Process -Force"`

## Git policy
- NEVER commit unless the user explicitly says "commit". No exceptions.

## Hard-won Godot lessons (from vault Lessons/ — full text there)
1. GDScript: object-vs-bool equality silently misbehaves — use explicit `is` / type checks (vault: gdscript-object-vs-bool-equality-error).
2. Type inference pitfalls in GDScript — annotate types explicitly (gdscript-type-inference).
3. Physics: cylinder SIDE collision blocks horizontal entry; parenting does NOT weld physics bodies — reparenting breaks transforms (two separate lessons).
4. Gravity clamp + stuck-check can fight attack states — check state machines when touching movement (godot-gravity-clamp...).
5. Node pooling: beware stale references across pool reuse (godot-node-pooling-risk).
6. Standalone SceneTree tests don't see autoloads — don't trust test results that skip autoload singletons (godot-standalone-scenetree-test-autoload-blindspot).
7. WorldEnvironment resource can be dead code after reskin (godot-worldenvironment-resource-can-be-dead-code).
8. Global class cache needs cold boot after adding class_name scripts (godot-global-class-cache-cold-boot).
9. Navigation/agent API differs across Godot versions — verify against 4.7 docs, not memory (godot-agent-navigation).
10. Wrapping buggy code in a function you immediately call does NOT defer it (wrapping-buggy-code-in-a-function...).
11. Measure interrupt correlation directly before trusting a race-condition theory (measure-interrupt-correlation...).
12. A guard that measurably engages can still fail to fix the bug — verify the OUTCOME, not the code path (a-guard-that-measurably-engages...).

## Workflow discipline
- Log each working session as a dated ledger note in the vault: `Project Work/YYYYMMDD_HHMMSS_horde-beta-<topic>.md` (see existing 2026-08-24 entries for format).
- Report negatives honestly: if a fix didn't work, say so and revert rather than leaving speculative changes in.
- Pre-register what a fix SHOULD change observably, then verify exactly that in the headless boot + a real playthrough where possible.
- Known past problem areas (recurring): zombie clumping, sink-through-floor, ally facing/targeting, game-over flow, dead-code accumulation from reskins. Re-check these after touching related systems.

## Style
- Match existing GDScript conventions in-repo. Prefer small targeted diffs over refactors.
