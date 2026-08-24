# ============================================================
# GameSettings.gd
# ============================================================
# Autoload — add in Project Settings → Autoload as "GameSettings"
# Persists all session settings between menu and game scene.
# ============================================================
extends Node

# ── MATCH SETTINGS ───────────────────────────────────────────
var player_count     : int        = 1
var team_assignments : Dictionary = {}   # player_idx (0-based) -> team_id (1 or 2)
## "original" = hive/egg wave defense (1 player base, zombie hives)
## "versus"   = base-vs-base (2 bases, no hives, optional VS AI)
## "endless"  = waves continue forever; score tracked in LeaderboardManager
var game_mode        : String     = "original"

# ── ENDLESS MODE ─────────────────────────────────────────────
var endless_wave     : int   = 0      # current wave in endless
var endless_start_t  : float = 0.0   # Time.get_ticks_msec() at game start

# ── AI SETTINGS ──────────────────────────────────────────────
var ai_enabled    : bool = true
var ai_team_id    : int  = 2       # which team the AI controls
var ai_difficulty : int  = 2       # 1=Easy  2=Medium  3=Hard  4=Nightmare

# ── AUDIO ────────────────────────────────────────────────────
var master_volume : float = 1.0
var music_volume  : float = 0.8
var sfx_volume    : float = 1.0

# ── DISPLAY ──────────────────────────────────────────────────
var fullscreen : bool = false

# ── RUN STATE ────────────────────────────────────────────────
# pid → Array of creep ids; survives scene reloads within a session
var player_decks : Dictionary = {}

# ─────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────

# Returns how many human players are on a given team
func human_count_on_team(tid: int) -> int:
	var n := 0
	for i in range(player_count):
		if team_assignments.get(i, (i % 2) + 1) == tid:
			n += 1
	return n

# True if the AI should be active (enabled and at least one team is AI-only)
func ai_active() -> bool:
	return ai_enabled

# Reset to defaults between sessions
func reset() -> void:
	player_count     = 1
	team_assignments = {}
	ai_enabled       = true
	ai_team_id       = 2
	ai_difficulty    = 2
	game_mode        = "original"
	player_decks     = {}

func difficulty_label() -> String:
	return ["", "EASY", "MEDIUM", "HARD", "NIGHTMARE"][clampi(ai_difficulty, 1, 4)]
