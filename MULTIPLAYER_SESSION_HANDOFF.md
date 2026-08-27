# Multiplayer session handoff

Full plan: `C:\Users\gbran\.claude\plans\reactive-sparking-finch.md` (5 phases, server-authoritative, LAN direct-IP, ENet).

## Why this handoff exists

Two tools got configured mid-session but need a **genuinely fresh Claude Code session** to register — a continuing session doesn't pick them up:

- **`observe` MCP server** — added to this project's `mcpServers` config in `~/.claude.json` (previously only registered under the `C:/Users/gbran` home-directory scope). Semantic search across indexed projects, real server at `C:\Users\gbran\OneDrive\Documents\012-ternary\trit_mcp_server.py`, verified working standalone (loads FAISS index cleanly).
- **`mattpocock-skills` plugin** — installed via the official Claude Code marketplace (`claude plugins install mattpocock-skills`, confirmed present at `~/.claude/plugins/cache/mattpocock/mattpocock-skills/1.2.3/`). Real skills worth using here: `implement` (drives implementation from a spec — use for Phase 3+), `tdd` (seam-focused testing discipline — no formal test framework exists in this GDScript project, but the seam concept still applies: verify at the RPC/public-interface boundary, not internals), `code-review` (run once a phase is done, before committing), `codebase-design`, `diagnosing-bugs`.

Both were confirmed via direct filesystem checks (marketplace + plugin cache present, MCP server script runs and loads cleanly) — the gap is purely session registration, not installation failure.

## Progress so far (all committed, verify with `git log --oneline -5`)

```
7818956 Multiplayer Phase 2: combat/damage relay
5cc3950 Multiplayer Phase 1: peer connection + replicated player movement
c8e86ce checkpoint: pre-existing uncommitted work (creeps, allies, hive/egg spawning, class/ability systems, test scaffolding)
```

**Phase 1 (done):** `NetworkManager.gd` (host/join, ENet, port 7777, max 4), `scenes/lobby.tscn` + `scripts/lobby_ui.gd`, `scripts/net/NetPlayerSpawner.gd`, identity split (`local_input_slot` vs `player_id`) + authority-gated input/physics/camera in `player.gd`, `SplitScreenManager.gd` updated so local split-screen still works unchanged. Verified via headless Godot boot (no new errors).

**Phase 2 (done):** `scripts/net/CombatRelay.gd` (new autoload) — closes the real gap where non-host clients dealt zero damage (the `multiplayer.is_server()` guards existed in all 4 weapon scripts but nothing ever relayed a client's hits to the server). `basegun.gd`/`rocket.gd`/`flamethrower.gd`/`lazerprojectile.gd` each got the missing client-relay branch. Known simplification, noted in-code: rocket splash damage via `request_explosion` doesn't yet replicate self-damage/knockback/group-sweep-fallback for client-fired rockets — closes the zero-damage gap without claiming full parity.

**Phase 3 (in progress, not committed):** server-authoritative economy. Just started reading `scripts/game_phase_script.gd`'s gold functions before editing:
- `get_gold(team)` — line 635
- `spend_gold(team, amt)` — line 643 (returns bool, `false` if insufficient funds)
- `team_money : Dictionary` — line 336, `{1: 0, 2: 0}`
- `_end_game(winner)` — line 751
- `_activate_tier(tier)` — line 1314 (known pre-existing cosmetic no-op bug, not caused by this work, don't fix as part of it)

Not yet touched: personal crystals (`player.gd:2409 spend_crystals`), `scripts/shopui.gd`'s purchase-flow restructure (sync check-then-spawn → async request/reply), `CreepDeckUI.gd`'s vote-tally collection (currently group-iteration, only works within one process).

**Phase 4, 5:** not started. See the plan file for full detail.

## Prompt for the new session

See `NEW_SESSION_PROMPT.txt` in this same directory — paste its contents as your first message.
