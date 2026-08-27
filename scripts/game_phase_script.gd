# ============================================================
# GamePhaseController.gd — AAA Rewrite
# ============================================================
# ARCHITECTURE:
#   • Hierarchical State Machine (HSM) — every phase is a
#     first-class State object with enter/tick/exit lifecycle.
#     No more match/string comparisons anywhere in tick loops.
#
#   • Infinite Scaling — rounds never end. ROUND_DEFS seeds
#     the first 6 rounds; beyond that, a pure math formula
#     drives horde size, wave count, enemy mix, and gold.
#     Difficulty curve uses a compound sigmoid so early game
#     stays approachable and late game never plateaus.
#
#   • Economy Engine — per-team interest, bounty multipliers,
#     streak bonuses, and a soft gold cap that prevents
#     runaway snowballing without hard-capping fun.
#
#   • Atmosphere System — fully frame-budgeted:
#       Ghosts  → update every 3 frames, pooled quads
#       Bats    → BAT_BATCH per frame, staggered index
#       Wind    → PlaneMesh FACE_Y, -90° rot eliminated
#       Shader  → blend_mix + depth_prepass_alpha fixed
#
#   • AI Creep Scaling — weight table for rounds 1-6,
#     then a continuous formula that smoothly evolves the
#     mix as rounds increase, with boss injection every 5.
#
#   • Signal Bus — all state changes go through typed signals.
#     No polling, no string-keyed dictionaries for game state.
# ============================================================
extends Node

# ══════════════════════════════════════════════════════════════
# CONSTANTS — ECONOMY
# ══════════════════════════════════════════════════════════════

const STARTING_MONEY       : int   = 300
const INTEREST_RATE        : float = 0.10   # 10 % of banked gold per round
const INTEREST_CAP         : int   = 150    # interest never exceeds this
const KILL_BOUNTY_BASE     : int   = 2      # gold per kill, round 1
const KILL_BOUNTY_SCALE    : float = 0.18   # grows per round (logarithmic)
const STREAK_THRESHOLD     : int   = 3      # kills before streak bonus kicks in
const STREAK_BONUS         : int   = 1      # extra gold per kill during streak
const GOLD_SOFT_CAP        : int   = 9999

# ══════════════════════════════════════════════════════════════
# CONSTANTS — ROUND SCALING (infinite)
# ══════════════════════════════════════════════════════════════

# Rounds 1-6: hand-authored seed data
# NOTE: these counts feed the lane/ZHM spawner per-wave.
# Hive nodes spawn ADDITIONAL enemies independently on their own timers.
# Keep these modest so the combined pressure is fair in early rounds.
const SEED_ROUNDS : Array[Dictionary] = [
	{"hordes": 5,   "waves": 2, "gold": 150, "label": "Scouting Party"},
	{"hordes": 10,  "waves": 2, "gold": 200, "label": "Advance Force"},
	{"hordes": 18,  "waves": 3, "gold": 275, "label": "Main Push"},
	{"hordes": 28,  "waves": 4, "gold": 350, "label": "Heavy Assault"},
	{"hordes": 42,  "waves": 5, "gold": 450, "label": "Overwhelming Horde"},
	{"hordes": 60,  "waves": 6, "gold": 600, "label": "Final Wave"},
]

# Procedural scaling knobs (rounds 7+)
const HORDE_BASE      : float = 120.0
const HORDE_GROWTH    : float = 1.18   # geometric per round beyond 6
const HORDE_SIGMOID_K : float = 0.07   # flattening factor — prevents infinity
const WAVE_MAX        : int   = 10
const GOLD_BASE       : float = 600.0
const GOLD_GROWTH     : float = 1.12
const BOSS_EVERY      : int   = 5      # inject a boss horde every N rounds

# ══════════════════════════════════════════════════════════════
# CONSTANTS — PHASE TIMING
# ══════════════════════════════════════════════════════════════

const PREP_DURATION     : float = 120.0
const ANNOUNCE_DURATION : float = 5.0
const CHOICE_DURATION   : float = 30.0
const RESULTS_DURATION  : float = 6.0
const WAVE_INTERVAL     : float = 28.0
const POST_WAVE_BUFFER  : float = 20.0

# ══════════════════════════════════════════════════════════════
# CONSTANTS — AI CREEP POOLS
# ══════════════════════════════════════════════════════════════

# Seed pools for rounds 1-6 (index = round - 1)
const SEED_POOLS : Array[Array] = [
	[{"id":"zombie","w":70},{"id":"leaper","w":20},{"id":"berserker","w":10},{"id":"tank","w":0}, {"id":"bomber","w":0}],
	[{"id":"zombie","w":50},{"id":"leaper","w":25},{"id":"berserker","w":20},{"id":"tank","w":5}, {"id":"bomber","w":0}],
	[{"id":"zombie","w":35},{"id":"leaper","w":25},{"id":"berserker","w":20},{"id":"tank","w":15},{"id":"bomber","w":5}],
	[{"id":"zombie","w":20},{"id":"leaper","w":20},{"id":"berserker","w":25},{"id":"tank","w":25},{"id":"bomber","w":10}],
	[{"id":"zombie","w":10},{"id":"leaper","w":15},{"id":"berserker","w":20},{"id":"tank","w":30},{"id":"bomber","w":25}],
	[{"id":"zombie","w":5}, {"id":"leaper","w":10},{"id":"berserker","w":15},{"id":"tank","w":35},{"id":"bomber","w":35}],
]

# Procedural pool formula endpoints (lerped by round progress beyond 6)
const PROC_POOL_EARLY : Dictionary = {"zombie":5, "leaper":10,"berserker":15,"tank":35,"bomber":35}
const PROC_POOL_LATE  : Dictionary = {"zombie":0, "leaper":5, "berserker":10,"tank":30,"bomber":40,"wraith":15}

# ══════════════════════════════════════════════════════════════
# CONSTANTS — ATMOSPHERE
# ══════════════════════════════════════════════════════════════

const GHOST_COUNT   : int = 8
const BAT_COUNT     : int = 120   # 120 bats across 6 flocks of 20
const BAT_BATCH     : int = 24    # update 24 per frame → full pool every 5 frames
const BAT_FLOCK_COUNT : int = 6   # number of independent flight-path flocks
const BAT_PER_FLOCK   : int = 20  # bats per flock
const WIND_COUNT    : int = 24

# DARK-HORROR RESKIN (2026-08-24, see theme_horror/HorrorTheme.gd): this
# was a dim, purely orange-red "Halloween ghost" night palette. Retinted
# toward this project's sickly desaturated green/amber/brown horror
# palette and given a real harsh key light instead of a near-invisible
# one (0.06 -> 0.22 sun energy) -- Wolfenstein-style mood wants a bright,
# hard-edged light source against DEEP shadow, not just uniform dimness.
# This is the script that's actually live at runtime (see HorrorTheme.gd
# for the full call-chain trace); main.tscn's saved Environment/
# DirectionalLight3D color+energy values are NOT -- only DirectionalLight3D's
# shadow_blur was worth touching there.
const NIGHT_SUN_ENERGY     : float = 0.22
const NIGHT_SUN_COLOR      : Color = Color(0.62, 0.46, 0.18)
const NIGHT_AMBIENT_ENERGY : float = 0.08
const SKY_TOP_COLOR        : Color = Color(0.04, 0.045, 0.03)
const SKY_HORIZON_COLOR    : Color = Color(0.34, 0.28, 0.12)
const SKY_BOTTOM_COLOR     : Color = Color(0.05, 0.045, 0.03)

# ══════════════════════════════════════════════════════════════
# EXPORTS
# ══════════════════════════════════════════════════════════════

@export var atmosphere_transition_time : float = 2.0
@export var fog_density                : float = 0.008
@export var fog_color                  : Color = Color(0.24, 0.27, 0.16, 1.0)   # was a cool blue-grey; now sickly olive
@export var scary_sound_volume_db      : float = -6.0
@export var scary_sound                : AudioStreamPlayer
@export var night_ambience             : AudioStreamPlayer

# ══════════════════════════════════════════════════════════════
# SIGNALS — typed, exhaustive
# ══════════════════════════════════════════════════════════════

signal phase_changed(from: String, to: String)
signal money_changed(team: int, amount: int)
signal ready_updated(team: int, is_ready: bool)
signal prep_time_updated(time_left: float)
signal match_started_signal()
signal show_phase_label(text: String, fade_out: bool)
signal round_announced(round_num: int, hordes: int, waves: int, label: String)
signal wave_choice_open(total_waves: int, default_wave: int, time_left: float)
signal wave_choice_closed()
signal round_started(round_num: int)
signal wave_launched(round_num: int, wave_num: int, horde_size: int)
signal round_ended(round_num: int, gold_reward: int)
signal game_over(winner_team: int)
signal phase_timer_updated(phase: String, time_left: float)
signal kill_registered(team: int, bounty: int, streak: int)
signal boss_wave_incoming(round_num: int)

# ══════════════════════════════════════════════════════════════
# NODE REFS
# ══════════════════════════════════════════════════════════════

@onready var _world_env : WorldEnvironment   = get_node_or_null("WorldEnvironment")
@onready var _sun       : DirectionalLight3D = get_node_or_null("DirectionalLight3D")

# ══════════════════════════════════════════════════════════════
# HSM — State base class (inner class, zero overhead)
# ══════════════════════════════════════════════════════════════

class State:
	var _ctrl : Node   # back-reference to GamePhaseController

	func _init(controller: Node) -> void:
		_ctrl = controller

	func enter(_prev: String) -> void: pass
	func tick(_delta: float)   -> void: pass
	func exit(_next: String)   -> void: pass
	func name()                -> String: return "base"


# ── Prep ──────────────────────────────────────────────────────
class StatePrepLobby extends State:
	var _timer : float = PREP_DURATION

	func name() -> String: return "prep"

	func enter(_prev: String) -> void:
		_timer = PREP_DURATION
		_ctrl.show_phase_label.emit(
			"⚔  PICK YOUR DECK\nConfirm deck to start  ·  Auto-start in 2:00", false)
		print("🟢 LOBBY — %.0fs max" % PREP_DURATION)

	func tick(delta: float) -> void:
		_timer -= delta
		_ctrl.prep_time_updated.emit(maxf(_timer, 0.0))
		if _timer <= 0.0:
			_ctrl._transition_to("announce")

	func force_start() -> void:
		_timer = minf(_timer, 5.0)
		_ctrl.show_phase_label.emit("✅  All players ready — starting in 5s!", true)


# ── Announce ──────────────────────────────────────────────────
class StateAnnounce extends State:
	var _timer : float = ANNOUNCE_DURATION

	func name() -> String: return "announce"

	func enter(_prev: String) -> void:
		_timer = ANNOUNCE_DURATION
		var rnd  : int        = _ctrl._current_round
		var def  : Dictionary = _ctrl._get_round_def(rnd)
		var txt  : String = "ROUND %d  —  %s\n%d enemies  ·  %d waves\nChoose your deploy wave!" % [
			rnd, def["label"], int(def["hordes"]), int(def["waves"])]
		_ctrl.show_phase_label.emit(txt, false)
		_ctrl.round_announced.emit(rnd, int(def["hordes"]), int(def["waves"]), def["label"])
		if rnd > 0 and rnd % BOSS_EVERY == 0:
			_ctrl.boss_wave_incoming.emit(rnd)
			print("💀 BOSS ROUND %d incoming!" % rnd)
		print("📢 ROUND %d: %s | %d hordes in %d waves" % [
			rnd, def["label"], int(def["hordes"]), int(def["waves"])])

	func tick(delta: float) -> void:
		_timer -= delta
		_ctrl.phase_timer_updated.emit("announce", maxf(_timer, 0.0))
		if _timer <= 0.0:
			_ctrl._transition_to("choice")


# ── Choice ────────────────────────────────────────────────────
class StateChoice extends State:
	var _timer : float = CHOICE_DURATION

	func name() -> String: return "choice"

	func enter(_prev: String) -> void:
		_timer = CHOICE_DURATION
		_ctrl.wave_choice_open.emit(
			_ctrl._waves_this_round, _ctrl._player_deploy_wave, CHOICE_DURATION)
		_ctrl.show_phase_label.emit(
			"Choose your deploy wave  [1–%d]\nDefault: Wave 1  (%ds)" % [
				_ctrl._waves_this_round, int(CHOICE_DURATION)], false)

	func tick(delta: float) -> void:
		_timer -= delta
		_ctrl.wave_choice_open.emit(
			_ctrl._waves_this_round, _ctrl._player_deploy_wave, maxf(_timer, 0.0))
		_ctrl.phase_timer_updated.emit("choice", maxf(_timer, 0.0))
		if _timer <= 0.0:
			_ctrl._transition_to("combat")


# ── Combat ────────────────────────────────────────────────────
class StateCombat extends State:
	var _combat_timer     : float = 0.0
	var _clear_check_tick : float = 0.0   # polls for map-clear win condition

	func name() -> String: return "combat"

	func enter(_prev: String) -> void:
		_combat_timer     = 0.0
		_clear_check_tick = 0.0
		_ctrl._current_wave = 0
		_ctrl.wave_choice_closed.emit()
		_ctrl.round_started.emit(_ctrl._current_round)
		_ctrl.show_phase_label.emit("ROUND %d  BEGINS" % _ctrl._current_round, true)
		print("⚔️  COMBAT START — Round %d" % _ctrl._current_round)
		# Start corruption zones + weekly mutation on first round
		if _ctrl._current_round == 1:
			var cm := _ctrl.get_tree().get_first_node_in_group("corruption_manager")
			if is_instance_valid(cm) and cm.has_method("start"): cm.start()
			var mm := _ctrl.get_tree().get_first_node_in_group("mutation_manager")
			if is_instance_valid(mm) and mm.has_method("apply_to_game"): mm.apply_to_game()
			var rm := _ctrl.get_tree().get_first_node_in_group("revive_manager")
			if is_instance_valid(rm) and rm.has_method("reset"): rm.reset()
			_ctrl._spawn_starting_turrets()
			# REAL FIX: "rats and bats should be an option given right off the
			# start, no quest requirement" -- the rat/bat pack choice
			# (AllyChoiceUI.gd) used to only ever appear after completing the
			# "Call of the Wild" quest (15 zombie kills). Fire it directly at
			# round 1 start instead of waiting on that quest -- the quest
			# pool entry itself is removed below in questmanager.gd so it
			# can't also fire a second time later.
			# Only the first player, not a loop over every player: AllyChoiceUI
			# is a single full-screen (not per-viewport) panel that replaces
			# itself on every emit (queue_frees the previous one), so firing
			# it once per player in the same frame would just stomp every
			# panel but the last -- a pre-existing single-player-oriented
			# design, not something to silently redesign as part of this fix.
			var qm := _ctrl.get_tree().get_first_node_in_group("quest_manager")
			var first_player := _ctrl.get_tree().get_first_node_in_group("player")
			if is_instance_valid(qm) and qm.has_signal("ally_choice_available") and is_instance_valid(first_player):
				var pid : int = int(first_player.get("player_id")) if "player_id" in first_player else 1
				qm.ally_choice_available.emit(pid)
		# Checked every round, not just round 1: guarantees a starter Builder
		# ally exists no matter what happens to the previous one (it's
		# undamageable so normally can't be lost, but this is the robust
		# guarantee regardless of how it might disappear).
		_ctrl._ensure_team_ally_presence()

	func tick(delta: float) -> void:
		_combat_timer += delta
		var next_t : float = float(_ctrl._current_wave + 1) * WAVE_INTERVAL - _combat_timer
		_ctrl.phase_timer_updated.emit("combat", maxf(next_t, 0.0))

		if _ctrl._current_wave < _ctrl._waves_this_round:
			var wave_threshold : float = float(_ctrl._current_wave + 1) * WAVE_INTERVAL
			if _combat_timer >= wave_threshold:
				_ctrl._current_wave += 1
				_ctrl._launch_wave(_ctrl._current_wave)

		if _ctrl._current_wave >= _ctrl._waves_this_round:
			var last_t : float = float(_ctrl._waves_this_round) * WAVE_INTERVAL
			if _combat_timer >= last_t + POST_WAVE_BUFFER:
				_ctrl._transition_to("results")

		# MAP-CLEAR WIN CHECK — every 3s once at least one wave has launched
		if _ctrl._current_wave >= 1:
			_clear_check_tick += delta
			if _clear_check_tick >= 3.0:
				_clear_check_tick = 0.0
				if _ctrl._is_map_cleared():
					_ctrl._end_game(1)   # players win!


# ── Results ───────────────────────────────────────────────────
class StateResults extends State:
	var _timer : float = RESULTS_DURATION

	func name() -> String: return "results"

	func enter(_prev: String) -> void:
		_timer = RESULTS_DURATION
		var gold : int = _ctrl._get_round_def(_ctrl._current_round).get("gold", 0)
		_ctrl._award_end_of_round_gold(gold)
		_ctrl.round_ended.emit(_ctrl._current_round, gold)
		_ctrl.show_phase_label.emit(
			"ROUND %d COMPLETE\n+%d gold" % [_ctrl._current_round, gold], false)
		print("✅ Round %d done. +%d gold each." % [_ctrl._current_round, gold])
		_ctrl._check_base_death()

	func tick(delta: float) -> void:
		_timer -= delta
		_ctrl.phase_timer_updated.emit("results", maxf(_timer, 0.0))
		if _timer <= 0.0:
			_ctrl._transition_to("announce")   # infinite — always next round


# ── Done ──────────────────────────────────────────────────────
class StateDone extends State:
	func name() -> String: return "done"
	func enter(_prev: String) -> void:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# ══════════════════════════════════════════════════════════════
# GAME STATE
# ══════════════════════════════════════════════════════════════

var _hsm_states    : Dictionary = {}   # String -> State
var _hsm_current   : State      = null
var _hsm_prev_name : String     = ""

var team_money     : Dictionary = {1: 0, 2: 0}
var team_ready     : Dictionary = {1: false, 2: false}
var creep_upgrades : Dictionary = {1: [], 2: []}
var kill_streaks   : Dictionary = {1: 0, 2: 0}   # per-team kill streak counter

var match_started      : bool = false
var _current_round     : int  = 0
var _current_wave      : int  = 0
var _waves_this_round  : int  = 0
var _hordes_per_wave   : int  = 0
var _player_deploy_wave: int  = 1
var _player_chose      : bool = false
var _slo_mo_guard      : bool = false

# ── Hive tier system ──────────────────────────────────────────
# Only T1 hives spawn until all T1 are destroyed.
# Then T2 activates; when T2 is cleared T3 activates, etc.
var _current_active_tier : int   = 0      # 0 = not yet started
var _active_hives        : Array = []     # HiveNode refs for current tier

# ══════════════════════════════════════════════════════════════
# ATMOSPHERE STATE
# ══════════════════════════════════════════════════════════════

var _ghosts      : Array = []
var _bats        : Array = []
var _bat_flocks  : Array = []   # Array of flock Dictionaries driving flight paths
var _winds       : Array = []
var _atmo_tick   : int   = 0
var _ghost_mesh  : QuadMesh = null
var _bat_mesh    : QuadMesh = null


# ══════════════════════════════════════════════════════════════
# LIFECYCLE
# ══════════════════════════════════════════════════════════════

func _ready() -> void:
	add_to_group("game_manager")
	# Dedicated, unambiguous group for this node specifically: main.tscn also
	# has a separate legacy "GameManager" node (scripts/game_manager.gd) in
	# the shared "game_manager" group, and get_first_node_in_group("game_manager")
	# does not reliably resolve to this node over that one (confirmed via
	# repeated headless multiplayer smoke tests -- it picked the wrong node
	# in 2 of 3 runs). Phase 3's networked economy RPCs need this node
	# specifically (spend_gold/get_gold/rpc_request_* all live here, not on
	# the legacy node), so they look up "economy_controller" instead.
	add_to_group("economy_controller")
	_init_money()
	_apply_night_lighting()
	_build_atmosphere()
	_reset_legacy_spawners()
	_build_hsm()
	get_tree().paused = false
	Engine.time_scale  = 1.0
	if Engine.has_singleton("ZombieHordeManager"):
		var _zhm : Object = Engine.get_singleton("ZombieHordeManager")
		if _zhm.has_signal("zombie_died"):
			_zhm.zombie_died.connect(_on_any_zombie_died)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.flush_buffered_events()
	await get_tree().process_frame
	Input.flush_buffered_events()
	_transition_to("prep")


func _process(delta: float) -> void:
	if _hsm_current != null:
		_hsm_current.tick(delta)
	_tick_atmosphere(delta)


# ══════════════════════════════════════════════════════════════
# HSM MACHINERY
# ══════════════════════════════════════════════════════════════

func _build_hsm() -> void:
	_hsm_states["prep"]     = StatePrepLobby.new(self)
	_hsm_states["announce"] = StateAnnounce.new(self)
	_hsm_states["choice"]   = StateChoice.new(self)
	_hsm_states["combat"]   = StateCombat.new(self)
	_hsm_states["results"]  = StateResults.new(self)
	_hsm_states["done"]     = StateDone.new(self)


func _transition_to(next_name: String) -> void:
	assert(_hsm_states.has(next_name), "Unknown state: " + next_name)
	var prev_name : String = _hsm_current.name() if _hsm_current != null else ""

	if _hsm_current != null:
		_hsm_current.exit(next_name)

	_hsm_prev_name = prev_name
	_hsm_current   = _hsm_states[next_name]

	# Advance round counter when entering announce (= new round)
	if next_name == "announce":
		_begin_next_round()

	_hsm_current.enter(prev_name)
	phase_changed.emit(prev_name, next_name)


func get_current_phase() -> String:
	return _hsm_current.name() if _hsm_current != null else ""


# ══════════════════════════════════════════════════════════════
# ROUND MANAGEMENT — infinite scaling
# ══════════════════════════════════════════════════════════════

func _begin_next_round() -> void:
	_current_round     += 1
	_current_wave       = 0
	_player_chose       = false
	_player_deploy_wave = 1

	if not match_started:
		_on_match_start()

	var def             : Dictionary = _get_round_def(_current_round)
	_waves_this_round   = int(def["waves"])
	_hordes_per_wave    = int(ceil(float(int(def["hordes"])) / float(_waves_this_round)))


## Returns a fully-formed round definition for any round number.
## Rounds 1-6 use hand-authored data; beyond that uses compound scaling.
func _get_round_def(round_num: int) -> Dictionary:
	if round_num <= SEED_ROUNDS.size():
		var seed : Dictionary = SEED_ROUNDS[round_num - 1].duplicate()
		seed["label"] = seed.get("label", "Round %d" % round_num)
		return seed

	# Compound sigmoid horde scaling — approaches a soft ceiling asymptotically
	var r      : float = float(round_num - 6)
	var raw_h  : float = HORDE_BASE * pow(HORDE_GROWTH, r)
	var sig    : float = 1.0 / (1.0 + exp(-HORDE_SIGMOID_K * (raw_h - 800.0)))
	var hordes : int   = int(raw_h * (1.0 - sig * 0.5))   # soft cap ~1600

	var waves  : int   = mini(2 + int(sqrt(float(round_num))), WAVE_MAX)
	var gold   : int   = int(GOLD_BASE * pow(GOLD_GROWTH, r))

	var suffix_pool : Array[String] = [
		"The Undying", "Corrupted Legion", "Shadow Horde", "Abyssal Assault",
		"Eternal Onslaught", "Forsaken Army", "Void Swarm", "Dread March",
	]
	var label : String = suffix_pool[(round_num - 7) % suffix_pool.size()]

	return {"hordes": hordes, "waves": waves, "gold": gold, "label": label}


# ══════════════════════════════════════════════════════════════
# WAVE LAUNCHING
# ══════════════════════════════════════════════════════════════

func _launch_wave(wave_num: int) -> void:
	var size : int = _hordes_per_wave

	# Boss injection: add a single powerful unit on boss rounds
	var is_boss_round : bool = _current_round % BOSS_EVERY == 0
	if is_boss_round and wave_num == _waves_this_round:
		_spawn_boss_unit(2)

	wave_launched.emit(_current_round, wave_num, size)   # triggers HUD 3-2-1-GO countdown
	await get_tree().create_timer(3.0, true, false, true).timeout   # hold until GO!
	_spawn_horde(2, size)
	_deploy_player_units_for_wave(wave_num)

	print("🌊 Wave %d/%d — %d AI units%s%s" % [
		wave_num, _waves_this_round, size,
		"  [BOSS WAVE]" if (is_boss_round and wave_num == _waves_this_round) else "",
		"  + PLAYER DEPLOY" if wave_num == _player_deploy_wave else ""])


# ══════════════════════════════════════════════════════════════
# SPAWNING
# ══════════════════════════════════════════════════════════════

func _spawn_horde(team: int, count: int) -> void:
	# ── Prefer active hive positions ─────────────────────────
	# Collect living active hives for team 2 (enemy hives)
	var live_hives : Array = []
	for hive in get_tree().get_nodes_in_group("hive_clusters"):
		if not is_instance_valid(hive): continue
		if "is_dead"   in hive and bool(hive.get("is_dead")):   continue
		if "is_active" in hive and not bool(hive.get("is_active")): continue
		live_hives.append(hive)

	if live_hives.size() > 0:
		# Distribute count evenly across active hives; remainder goes to first
		var per_hive : int = maxi(1, count / live_hives.size())
		var leftover : int = count - per_hive * live_hives.size()
		for i in live_hives.size():
			var hive = live_hives[i]
			var n    : int = per_hive + (1 if i == 0 and leftover > 0 else 0)
			if hive.has_method("spawn_wave_pulse"):
				hive.spawn_wave_pulse(n)
		return

	# No active hives — all tiers cleared or not yet activated.
	# Enemies ONLY spawn from hives; we do nothing here.
	push_warning("[GamePhase] _spawn_horde called but no active hives found (team=%d, count=%d)" % [team, count])


func _spawn_boss_unit(team: int) -> void:
	var ls := get_tree().get_first_node_in_group("lane_spawner")
	if is_instance_valid(ls) and ls.has_method("spawn_boss"):
		ls.spawn_boss(team, _current_round)
	else:
		# Fallback: spawn a heavily buffed tank as the boss
		_spawn_horde(team, 1)


func _deploy_player_units_for_wave(wave_num: int) -> void:
	var ls := get_tree().get_first_node_in_group("lane_spawner")
	if is_instance_valid(ls) and ls.has_method("_deploy_queued_for_wave"):
		ls._deploy_queued_for_wave(wave_num)
		return
	if wave_num == _player_deploy_wave:
		for shop in get_tree().get_nodes_in_group("shop"):
			if shop.has_method("deploy_staged_units"):
				shop.deploy_staged_units(1)
		if is_instance_valid(ls) and ls.has_method("deploy_player_wave"):
			ls.deploy_player_wave(1)


## Picks a creep type for the given round.
## Rounds 1-6: weighted table lookup.
## Rounds 7+: smoothly lerped procedural weights.
func _pick_creep_id(round_num: int) -> String:
	var pool : Dictionary = _build_pool_for_round(round_num)
	var total : int = 0
	for w in pool.values():
		total += int(w)
	if total <= 0:
		return "zombie"
	var roll : int = randi_range(0, total - 1)
	var acc  : int = 0
	for id in pool:
		acc += int(pool[id])
		if roll < acc:
			return id
	return "zombie"


func _build_pool_for_round(round_num: int) -> Dictionary:
	if round_num <= SEED_POOLS.size():
		var out : Dictionary = {}
		for entry in SEED_POOLS[round_num - 1]:
			out[entry["id"]] = entry["w"]
		return out

	# Lerp between PROC_POOL_EARLY and PROC_POOL_LATE over 20 rounds
	var t   : float     = clampf(float(round_num - 6) / 20.0, 0.0, 1.0)
	var out : Dictionary = {}
	var all_ids : Array  = PROC_POOL_EARLY.keys() + PROC_POOL_LATE.keys()
	for id in all_ids:
		if out.has(id):
			continue
		var w_early : float = float(PROC_POOL_EARLY.get(id, 0))
		var w_late  : float = float(PROC_POOL_LATE.get(id, 0))
		var w       : int   = int(lerp(w_early, w_late, t))
		if w > 0:
			out[id] = w
	return out


# ══════════════════════════════════════════════════════════════
# ECONOMY ENGINE
# ══════════════════════════════════════════════════════════════

func _init_money() -> void:
	team_money[1] = STARTING_MONEY
	team_money[2] = STARTING_MONEY
	money_changed.emit(1, team_money[1])
	money_changed.emit(2, team_money[2])


func _award_end_of_round_gold(base_gold: int) -> void:
	for team in [1, 2]:
		var interest : int = mini(
			int(float(team_money[team]) * INTEREST_RATE),
			INTEREST_CAP)
		var total : int = base_gold + interest
		_add_gold(team, total)
		if interest > 0:
			print("[Economy] T%d interest +%d" % [team, interest])


## Called by external kill-tracking nodes (creep death scripts etc.)
func register_kill(killer_team: int) -> void:
	kill_streaks[killer_team] += 1
	kill_streaks[3 - killer_team] = 0   # reset opponent streak

	var streak  : int = kill_streaks[killer_team]
	var bounty  : int = _compute_bounty(killer_team, streak)
	_add_gold(killer_team, bounty)
	kill_registered.emit(killer_team, bounty, streak)


func _compute_bounty(team: int, streak: int) -> int:
	var base   : int = KILL_BOUNTY_BASE + int(log(float(_current_round + 1)) * KILL_BOUNTY_SCALE * 10.0)
	var bonus  : int = STREAK_BONUS * maxi(streak - STREAK_THRESHOLD, 0)
	return base + bonus


# ── Gold API ──────────────────────────────────────────────────

func get_gold(team: int)           -> int:  return team_money.get(team, 0)
func add_gold(team: int, amt: int) -> void: _add_gold(team, amt)
func set_gold(team: int, amt: int) -> void:
	if not (multiplayer.is_server() or not multiplayer.has_multiplayer_peer()): return
	team_money[team] = clampi(amt, 0, GOLD_SOFT_CAP)
	money_changed.emit(team, team_money[team])

func award_gold(team: int, amt: int) -> void: _add_gold(team, amt)

## Server-authoritative: on a client this only validates and reports
## success/failure locally, it does NOT mutate shared state. Networked
## callers (shopui.gd etc.) must go through rpc_request_spend_gold instead --
## a direct call here from a non-authoritative peer is a no-op that returns
## false, matching insufficient-funds behavior so existing callers degrade
## safely rather than silently diverging local state.
func spend_gold(team: int, amt: int) -> bool:
	if not (multiplayer.is_server() or not multiplayer.has_multiplayer_peer()): return false
	if team_money.get(team, 0) < amt:
		return false
	team_money[team] -= amt
	money_changed.emit(team, team_money[team])
	return true

func _add_gold(team: int, amt: int) -> void:
	if not (multiplayer.is_server() or not multiplayer.has_multiplayer_peer()): return
	team_money[team] = clampi(team_money.get(team, 0) + amt, 0, GOLD_SOFT_CAP)
	money_changed.emit(team, team_money[team])


## Request/reply pair for non-authoritative peers: a client calls
## rpc_request_spend_gold, the server validates+spends against its own
## authoritative team_money, then pushes the resulting balance to every
## other peer as a display-only mirror via rpc_sync_gold. Silent no-op on
## rejection (insufficient funds or a non-server receiving it) -- matches
## CombatRelay.gd's request_hit convention of not round-tripping failure.
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_spend_gold(team: int, amt: int) -> void:
	if not multiplayer.is_server(): return
	if spend_gold(team, amt):
		rpc_sync_gold.rpc(team, team_money[team])


@rpc("authority", "call_remote", "reliable")
func rpc_sync_gold(team: int, amount: int) -> void:
	team_money[team] = amount
	money_changed.emit(team, amount)


## Request/reply pair for base upgrades (shopui.gd's _on_base_upgrade_selected).
## Base is a static main.tscn child like GamePhaseController itself -- every
## peer has its own disconnected local copy, so its HP needs the same
## request/apply/broadcast shape as gold rather than a direct local mutation.
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_base_upgrade(team: int, amount: int, cost: int) -> void:
	if not multiplayer.is_server(): return
	if not spend_gold(team, cost): return
	_apply_base_upgrade(team, amount)
	rpc_apply_base_upgrade.rpc(team, amount)


@rpc("authority", "call_remote", "reliable")
func rpc_apply_base_upgrade(team: int, amount: int) -> void:
	_apply_base_upgrade(team, amount)


## Mirrors shopui.gd's _on_base_upgrade_selected effect exactly.
## REAL BUG FIX: the base-node fallback used to check for "max_health"/
## "current_health" -- basenode.gd has neither; its real fields are
## "health" (current, doubles as the de-facto ceiling -- no separate max)
## and "health_value" (a mirror of health, used for HUD binding). Neither
## fallback condition was ever true, so every base upgrade purchase --
## player-bought or AI-bought -- silently did nothing at all.
func _apply_base_upgrade(team: int, amount: int) -> void:
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and int(b.get("team_id")) == team:
			if b.has_method("add_health"):
				b.add_health(amount)
			else:
				if "health" in b:
					b.health += amount
					if "health_value" in b: b.health_value = b.health
			return


## Same request/apply/broadcast shape as base upgrades, for the creep-deck
## progressive-unlock economy (shopui.gd's "Unlock New Creep" row). Every
## peer runs its own separate CreepDeckManager autoload instance (not
## itself replicated), so each one applies the same deterministic unlock
## locally on broadcast rather than syncing a shared object.
@rpc("any_peer", "call_remote", "reliable")
func rpc_request_unlock_creep(team: int, pid: int, cost: int) -> void:
	if not multiplayer.is_server(): return
	if not spend_gold(team, cost): return
	var unlocked_id : String = _apply_unlock_creep(pid)
	if unlocked_id != "":
		rpc_apply_unlock_creep.rpc(pid, unlocked_id)


@rpc("authority", "call_remote", "reliable")
func rpc_apply_unlock_creep(pid: int, creep_id: String) -> void:
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("add_card_to_deck"):
		dm.add_card_to_deck(pid, creep_id)


func _apply_unlock_creep(pid: int) -> String:
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("unlock_next"):
		return dm.unlock_next(pid)
	return ""


# ══════════════════════════════════════════════════════════════
# UPGRADES
# ══════════════════════════════════════════════════════════════

## NOTE: the "apply to every currently-existing unit right now" half of this
## stays per-peer-local -- creep/zombie units aren't replicated yet (that's
## Phase 4's server-only hive/zombie simulation, not started). The
## request/apply/broadcast pair below only guarantees the OTHER half --
## creep_upgrades[team], which affects future spawns -- stays consistent
## across peers, same class of known gap as player.gd's add_crystal note.
func add_creep_upgrade(team: int, upgrade: Dictionary) -> void:
	creep_upgrades[team].append(upgrade)
	for unit in get_tree().get_nodes_in_group("units"):
		if "team_id" in unit and unit.team_id == team:
			if unit.has_method("apply_upgrade"):
				unit.apply_upgrade(upgrade["stat"], upgrade["amount"])
	print("[Upgrade] T%d: %s" % [team, upgrade.get("label", "?")])


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_creep_tier_upgrade(team: int, upgrade: Dictionary, cost: int) -> void:
	if not multiplayer.is_server(): return
	if not spend_gold(team, cost): return
	add_creep_upgrade(team, upgrade)
	rpc_apply_creep_tier_upgrade.rpc(team, upgrade)


@rpc("authority", "call_remote", "reliable")
func rpc_apply_creep_tier_upgrade(team: int, upgrade: Dictionary) -> void:
	add_creep_upgrade(team, upgrade)


func get_creep_upgrades(team: int) -> Array:
	return creep_upgrades.get(team, [])


# ══════════════════════════════════════════════════════════════
# READY / LOBBY
# ══════════════════════════════════════════════════════════════

func set_team_ready(team: int, is_ready: bool = true) -> void:
	if match_started or not team_ready.has(team) or team_ready[team] == is_ready:
		return
	team_ready[team] = is_ready
	ready_updated.emit(team, is_ready)
	_check_all_ready()


func _check_all_ready() -> void:
	team_ready[2] = true   # AI always ready
	for k in team_ready:
		if not team_ready[k]:
			return
	if get_current_phase() == "prep" and _hsm_current is StatePrepLobby:
		(_hsm_current as StatePrepLobby).force_start()
		print("[GamePhase] All players ready — 5s countdown")


func player_choose_wave(wave: int) -> void:
	_player_deploy_wave = clampi(wave, 1, _waves_this_round)
	_player_chose       = true
	print("[GamePhase] Player chose deploy wave %d" % _player_deploy_wave)


# ══════════════════════════════════════════════════════════════
# BASE DEATH CHECK
# ══════════════════════════════════════════════════════════════

func _check_base_death() -> void:
	for b in get_tree().get_nodes_in_group("bases"):
		if b.has_method("is_dead") and b.is_dead():
			var loser  : int = int(b.get("team_id")) if "team_id" in b else -1
			var winner : int = 1 if loser == 2 else 2
			_end_game(winner)
			return


## Returns true when every hostile entity on the map is gone —
## zombies, enemy units, hive creeps, eggs, and hive clusters all cleared.
func _is_map_cleared() -> bool:
	# Check all standard enemy groups
	for grp in ["zombies", "hive_unit", "eggs", "hive_clusters"]:
		for node in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(node): continue
			# Skip dead/harvested nodes that haven't freed yet
			if "is_dead" in node and node.get("is_dead") == true: continue
			if "health" in node and float(node.get("health")) <= 0.0: continue
			return false

	# Check "units" group — only enemy team (team 2) counts
	for node in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node): continue
		if "team_id" in node and int(node.get("team_id")) == 1: continue   # team 1 = player side
		if "is_dead" in node and node.get("is_dead") == true: continue
		if "health" in node and float(node.get("health")) <= 0.0: continue
		return false

	return true


func _on_any_zombie_died(_pos: Vector3) -> void:
	if _slo_mo_guard: return
	if get_current_phase() != "combat": return
	if _current_wave < 1: return
	if not _is_map_cleared(): return
	_slo_mo_guard = true
	_fire_wave_clear_slo_mo()

func _fire_wave_clear_slo_mo() -> void:
	Engine.time_scale = 0.25
	await get_tree().create_timer(0.18, true, false, true).timeout
	Engine.time_scale = 1.0
	_slo_mo_guard = false


## REAL BUG FIX (2026-08-24): "base being dead should auto end game" -- it
## never did. basenode.gd::_on_destroyed() has always called
## gm._on_base_died(team_id) on whatever "game_manager" resolves to, but
## this method never existed anywhere in the codebase -- has_method()
## silently skipped the call every single time a base hit 0 HP, so the
## match just... kept running. The whole real game-over path (_end_game(),
## already correct and working for "all enemies eliminated") was simply
## never reached from this direction.
func _on_base_died(dead_team: int) -> void:
	var winner : int = 2 if dead_team == 1 else 1
	_end_game(winner)


func _end_game(winner: int = 1) -> void:
	if get_current_phase() == "done":
		return
	var txt : String
	if winner == 1:
		txt = "🏆 MAP CLEARED!\nAll enemies eliminated!"
	elif winner > 0:
		txt = "🏆 TEAM %d WINS!" % winner
	else:
		txt = "DRAW"
	show_phase_label.emit(txt, false)
	game_over.emit(winner)
	_transition_to("done")
	print("🏁 GAME OVER — Team %d wins | Round: %d | Gold: %s" % [
		winner, _current_round, str(team_money)])


# ══════════════════════════════════════════════════════════════
# MATCH START
# ══════════════════════════════════════════════════════════════

func _on_match_start() -> void:
	match_started = true
	match_started_signal.emit()
	_play_sounds()
	_spawn_ambient_fog_patches()
	_disable_legacy_spawners()
	# Hives only exist in original mode. In versus mode, spawning is handled
	# by lane spawners / AI players; hive nodes are not present or not activated.
	var gs        := get_node_or_null("/root/GameSettings")
	var game_mode : String = gs.game_mode if (is_instance_valid(gs) and "game_mode" in gs) else "original"
	if game_mode == "original":
		_activate_tier(1)
	else:
		print("[GamePhase] Versus mode — skipping hive activation")


# ══════════════════════════════════════════════════════════════
# ATMOSPHERE — BUILD (called once in _ready)
# ══════════════════════════════════════════════════════════════

func _build_atmosphere() -> void:
	_apply_night_lighting()
	_setup_orange_sky()
	_build_ghost_pool()
	_build_bat_pool()
	_build_wind_pool()


func _apply_night_lighting() -> void:
	if is_instance_valid(_sun):
		_sun.light_energy = NIGHT_SUN_ENERGY
		_sun.light_color  = NIGHT_SUN_COLOR
	if not is_instance_valid(_world_env):
		return
	var env := _world_env.environment
	if not is_instance_valid(env):
		return
	env.fog_enabled          = true
	env.fog_density          = fog_density
	env.fog_light_color      = Color(0.24, 0.27, 0.15)   # was orange (0.52,0.24,0.06); now sickly olive-amber
	env.fog_sky_affect       = 0.55
	env.ambient_light_energy = NIGHT_AMBIENT_ENERGY
	env.ambient_light_color  = Color(0.22, 0.24, 0.12)   # was orange (0.50,0.22,0.08); now desaturated olive


func _setup_orange_sky() -> void:
	if not is_instance_valid(_world_env):
		return
	var env := _world_env.environment
	if not is_instance_valid(env):
		return
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color        = SKY_TOP_COLOR
	sky_mat.sky_horizon_color    = SKY_HORIZON_COLOR
	sky_mat.ground_bottom_color  = SKY_BOTTOM_COLOR
	sky_mat.ground_horizon_color = SKY_HORIZON_COLOR
	sky_mat.sky_curve            = 0.15
	sky_mat.ground_curve         = 0.02
	sky_mat.sun_angle_max        = 20.0
	sky_mat.sun_curve            = 0.3
	var sky := Sky.new()
	sky.sky_material                 = sky_mat
	sky.process_mode                 = Sky.PROCESS_MODE_QUALITY
	env.sky                          = sky
	env.background_mode              = Environment.BG_SKY
	env.background_energy_multiplier = 0.4


# ── Ghost pool — shader-drawn face (eyes + hollow mouth) ─────

func _build_ghost_pool() -> void:
	_ghost_mesh      = QuadMesh.new()
	_ghost_mesh.size = Vector2(2.0, 2.8)   # slightly larger to show face detail

	# Ghost face shader:
	#   • Teardrop body: wide at head, tapered wispy tail with sine wobble
	#   • Two hollow eye sockets: dark voids with faint green pupils
	#   • Jagged open mouth: three triangular teeth gaps cut into the lower face
	#   • Edge glow: outer rim brightens for an ethereal backlit look
	#   • Flicker: random per-ghost time_offset makes each one pulse independently
	var ghost_shader := Shader.new()
	ghost_shader.code = \
"""
shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha, cull_disabled;

uniform float time_offset = 0.0;
uniform float flicker_speed = 1.4;
uniform vec3  ghost_color   = vec3(0.68, 1.0, 0.78);
uniform float ghost_alpha   = 0.55;

// Signed distance to an ellipse centred at p with radii r
float sdEllipse(vec2 p, vec2 r) {
	return (length(p / r) - 1.0) * min(r.x, r.y);
}

void fragment() {
	vec2 uv = vec2(UV.x * 2.0 - 1.0, -(UV.y * 2.0 - 1.0));   // flip Y so head is up, tail hangs down

	// ── Body: teardrop — head is a circle, tail tapers with a sine wiggle ──
	float head_r = 0.62;
	float head_d = length(uv - vec2(0.0, 0.28)) - head_r;

	// Tail: below centre, tapers and sways
	float tail_t    = clamp((-uv.y - 0.12) / 1.1, 0.0, 1.0);
	float tail_w    = mix(0.60, 0.0, tail_t * tail_t);
	float sway      = sin(TIME * 1.8 + time_offset + uv.y * 3.5) * 0.08 * tail_t;
	float tail_d    = abs(uv.x - sway) - tail_w;
	float in_tail   = step(uv.y, 0.12);   // 1 when in tail region
	float body      = smoothstep(0.04, -0.04, mix(head_d, tail_d, in_tail));

	if (body < 0.01) discard;

	// ── Eye sockets: two dark ellipses ──
	float leye = sdEllipse(uv - vec2(-0.22, 0.38), vec2(0.13, 0.10));
	float reye = sdEllipse(uv - vec2( 0.22, 0.38), vec2(0.13, 0.10));
	float eye_void   = smoothstep(0.0, -0.04, min(leye, reye));   // dark void
	float eye_pupils = smoothstep(0.02, -0.01,
		min(sdEllipse(uv - vec2(-0.22, 0.36), vec2(0.05, 0.04)),
		    sdEllipse(uv - vec2( 0.22, 0.36), vec2(0.05, 0.04))));

	// ── Mouth: a jagged open slot — three rectangular notches cut out ──
	float mouth_y   = 0.06;
	float mouth_h   = 0.10;
	float in_mouth_strip = step(mouth_y - mouth_h, uv.y) * step(uv.y, mouth_y) * step(-0.40, uv.x) * step(uv.x, 0.40);
	// Three tooth gaps — carved out by three narrow rects
	float tooth_w   = 0.09;
	float gap0 = step(abs(uv.x - (-0.24)), tooth_w * 0.5);
	float gap1 = step(abs(uv.x -   0.0  ), tooth_w * 0.5);
	float gap2 = step(abs(uv.x -   0.24 ), tooth_w * 0.5);
	float mouth_dark = in_mouth_strip * (1.0 - gap0) * (1.0 - gap1) * (1.0 - gap2);
	// Exposed gap below teeth is black
	float mouth_void = in_mouth_strip * clamp(gap0 + gap1 + gap2, 0.0, 1.0);

	// ── Edge glow: brighter near body outline ──
	float edge_glow = smoothstep(0.15, 0.0, abs(head_d)) * (1.0 - in_tail)
	                + smoothstep(0.08, 0.0, abs(tail_d))  * in_tail;

	// ── Flicker ──
	float flicker = 0.85 + 0.15 * sin(TIME * flicker_speed + time_offset * 3.7);

	// ── Composite ──
	vec3 col = ghost_color;
	col += edge_glow * 0.35 * ghost_color;          // rim brightens
	col  = mix(col, vec3(0.12, 0.55, 0.25), eye_void);   // eye socket — dark green tint
	col  = mix(col, vec3(0.05, 0.9,  0.3 ), eye_pupils); // pupils — bright green
	col  = mix(col, vec3(0.04, 0.04, 0.06), mouth_dark); // teeth areas — very dark
	col  = mix(col, vec3(0.0,  0.0,  0.0 ), mouth_void); // tooth gaps — pure black

	float a = body * ghost_alpha * flicker;
	a = mix(a, 0.0, mouth_void * in_mouth_strip);   // fully transparent in tooth gaps

	ALBEDO    = col;
	ALPHA     = clamp(a, 0.0, 1.0);
	EMISSION  = col * (0.6 + edge_glow * 0.5) * flicker;
}
"""

	# Each ghost gets its own ShaderMaterial so uniforms vary independently
	for i in GHOST_COUNT:
		var mat := ShaderMaterial.new()
		mat.shader = ghost_shader
		mat.set_shader_parameter("time_offset",    randf() * TAU)
		mat.set_shader_parameter("flicker_speed",  randf_range(0.9, 2.2))
		mat.set_shader_parameter("ghost_alpha",    randf_range(0.42, 0.65))
		# Slight hue variation: some ghosts lean more blue-white, some green
		var hue_shift : float = randf_range(-0.08, 0.08)
		mat.set_shader_parameter("ghost_color",
			Vector3(0.68 + hue_shift, 1.0, 0.78 - hue_shift * 0.5))

		var mi := MeshInstance3D.new()
		mi.mesh              = _ghost_mesh
		mi.material_override = mat
		mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode           = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)

		var pos := Vector3(
			randf_range(-35.0, 35.0),
			randf_range(5.0, 12.0),
			randf_range(-35.0, 35.0))
		mi.position = pos

		_ghosts.append({
			"mesh":    mi,
			"pos":     pos,
			"vel":     Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8)),
			"bob_t":   randf() * TAU,
			"bob_spd": randf_range(0.35, 0.75),
		})
	print("[Atmo] Ghosts: %d (shader faces enabled)" % _ghosts.size())


# ── Bat pool — 120 bats in 6 flocks, each flock on a Lissajous flight path ──
#
# Flight path design:
#   Each flock has a Lissajous attractor — a parametric curve defined by
#   independent sine frequencies on X/Y/Z. The flock centre follows this
#   path; individual bats offset from it with a small phase lag so the
#   flock stretches and compresses like a real murmuration.
#   Frequencies are chosen to be incommensurable so paths never exactly
#   repeat. Each flock also has a unique altitude band so flocks layer
#   vertically and don't all pile up at the same height.

func _build_bat_pool() -> void:
	_bat_mesh      = QuadMesh.new()
	_bat_mesh.size = Vector2(0.55, 0.28)

	var bat_shader := Shader.new()
	bat_shader.code = \
"""
shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha, cull_disabled;

uniform float wing_speed  = 9.0;
uniform float time_offset = 0.0;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 right = vec3(VIEW_MATRIX[0][0], VIEW_MATRIX[1][0], VIEW_MATRIX[2][0]);
	vec3 up    = vec3(VIEW_MATRIX[0][1], VIEW_MATRIX[1][1], VIEW_MATRIX[2][1]);
	vec3 vpos  = world_pos + right * VERTEX.x + up * VERTEX.y;
	POSITION   = PROJECTION_MATRIX * VIEW_MATRIX * vec4(vpos, 1.0);
}

void fragment() {
	vec2  uv   = UV * 2.0 - 1.0;
	float flap = sin(TIME * wing_speed + time_offset) * 0.42;
	float body = smoothstep(0.20, 0.0, length(uv * vec2(2.1, 1.0)));
	float lw   = smoothstep(0.48, 0.0, length((uv - vec2(-0.50, flap)) * vec2(0.88, 1.9)));
	float rw   = smoothstep(0.48, 0.0, length((uv - vec2( 0.50, flap)) * vec2(0.88, 1.9)));
	float mask = clamp(body + lw + rw, 0.0, 1.0);
	if (mask < 0.12) discard;
	ALBEDO = vec3(0.07, 0.03, 0.10);
	ALPHA  = mask;
}
"""

	# ── Build 6 flocks ────────────────────────────────────────
	# Lissajous params: each flock gets unique frequencies and a vertical band
	# freqs chosen to be irrational ratios — paths never repeat
	var flock_params : Array[Dictionary] = [
		{"fx":0.17, "fy":0.09, "fz":0.13, "ax":38.0, "az":38.0, "y_ctr":10.0, "y_amp":2.5, "speed":1.0},
		{"fx":0.23, "fy":0.11, "fz":0.19, "ax":32.0, "az":44.0, "y_ctr":14.0, "y_amp":2.0, "speed":0.85},
		{"fx":0.31, "fy":0.07, "fz":0.27, "ax":44.0, "az":30.0, "y_ctr":18.0, "y_amp":3.0, "speed":1.15},
		{"fx":0.13, "fy":0.15, "fz":0.21, "ax":50.0, "az":36.0, "y_ctr": 8.0, "y_amp":1.8, "speed":0.70},
		{"fx":0.29, "fy":0.13, "fz":0.11, "ax":28.0, "az":48.0, "y_ctr":22.0, "y_amp":2.2, "speed":1.30},
		{"fx":0.19, "fy":0.17, "fz":0.23, "ax":42.0, "az":26.0, "y_ctr":12.0, "y_amp":2.8, "speed":0.95},
	]

	for fi in BAT_FLOCK_COUNT:
		var fp : Dictionary = flock_params[fi]
		# Each flock gets a random time offset so they start at different path positions
		var flock_time_offset : float = randf() * TAU * 10.0
		_bat_flocks.append({
			"fx":         float(fp["fx"]),
			"fy":         float(fp["fy"]),
			"fz":         float(fp["fz"]),
			"ax":         float(fp["ax"]),
			"az":         float(fp["az"]),
			"y_ctr":      float(fp["y_ctr"]),
			"y_amp":      float(fp["y_amp"]),
			"speed":      float(fp["speed"]),
			"t":          flock_time_offset,
			"centre":     Vector3.ZERO,
		})

		# ── Spawn BAT_PER_FLOCK bats belonging to this flock ──
		for bi in BAT_PER_FLOCK:
			var mat := ShaderMaterial.new()
			mat.shader = bat_shader
			# Phase offset within the flock — spreads bats along the path
			var member_phase : float = float(bi) / float(BAT_PER_FLOCK) * TAU
			mat.set_shader_parameter("time_offset", randf() * TAU)
			mat.set_shader_parameter("wing_speed",  randf_range(7.0, 15.0))

			var mi := MeshInstance3D.new()
			mi.mesh              = _bat_mesh
			mi.material_override = mat
			mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.gi_mode           = GeometryInstance3D.GI_MODE_DISABLED
			add_child(mi)

			var pos := Vector3(
				randf_range(-50.0, 50.0),
				float(fp["y_ctr"]) + randf_range(-2.0, 2.0),
				randf_range(-50.0, 50.0))
			mi.position = pos

			_bats.append({
				"mesh":         mi,
				"pos":          pos,
				"flock_idx":    fi,
				"member_phase": member_phase,
				# Bats trail behind the flock centre by this phase lag in path-time
				"path_lag":     randf_range(0.0, 0.8),
				# Small personal offset so bats don't all sit exactly on centre
				"offset":       Vector3(
					randf_range(-3.5, 3.5),
					randf_range(-1.2, 1.2),
					randf_range(-3.5, 3.5)),
			})

	print("[Atmo] Bats: %d across %d flocks (Lissajous flight paths)" % [
		_bats.size(), _bat_flocks.size()])


# ── Wind pool — FIX: PlaneMesh FACE_Y so streaks are horizontal ──

func _build_wind_pool() -> void:
	var wind_mat                  := StandardMaterial3D.new()
	wind_mat.transparency          = BaseMaterial3D.TRANSPARENCY_ALPHA
	wind_mat.albedo_color          = Color(0.9, 0.8, 0.6, 0.25)
	wind_mat.shading_mode          = BaseMaterial3D.SHADING_MODE_UNSHADED
	wind_mat.depth_draw_mode       = BaseMaterial3D.DEPTH_DRAW_DISABLED
	wind_mat.cull_mode             = BaseMaterial3D.CULL_DISABLED

	for _i in WIND_COUNT:
		# PlaneMesh with FACE_Y lies flat on the XZ plane — no rotation hack needed
		var mesh              := PlaneMesh.new()
		mesh.size              = Vector2(randf_range(2.5, 8.0), 0.05 + randf() * 0.05)
		mesh.orientation       = PlaneMesh.FACE_Y

		var mi := MeshInstance3D.new()
		mi.mesh              = mesh
		mi.material_override = wind_mat
		mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode           = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)

		var pos := Vector3(
			randf_range(-45.0, 45.0),
			randf_range(0.5, 8.0),
			randf_range(-45.0, 45.0))
		mi.position = pos

		_winds.append({
			"mesh":  mi,
			"pos":   pos,
			"speed": randf_range(6.0, 16.0),
		})
	print("[Atmo] Wind streaks: %d" % _winds.size())


# ══════════════════════════════════════════════════════════════
# ATMOSPHERE — TICK
# ══════════════════════════════════════════════════════════════

func _tick_atmosphere(delta: float) -> void:
	_atmo_tick += 1

	# Ghosts: every 3 frames, compensate dt
	if _atmo_tick % 3 == 0:
		_tick_ghosts(delta * 3.0)

	# Advance all flock path times every frame (cheap — just float addition)
	_tick_flock_centres(delta)

	# Bats: BAT_BATCH per frame, rotating through pool
	var bat_start : int = (_atmo_tick * BAT_BATCH) % BAT_COUNT
	_tick_bats(delta, bat_start, BAT_BATCH)

	# Wind: all every frame (cheap translation only)
	_tick_wind(delta)


func _tick_ghosts(dt: float) -> void:
	const BOUNDS : float = 40.0
	for g in _ghosts:
		var mi : MeshInstance3D = g["mesh"]
		if not is_instance_valid(mi):
			continue
		var bob_t   : float   = float(g["bob_t"]) + float(g["bob_spd"]) * dt
		var pos     : Vector3 = g["pos"]
		pos          += (g["vel"] as Vector3) * dt
		pos.y         = 6.0 + sin(bob_t) * 1.8 + cos(bob_t * 0.6) * 0.9
		pos.x         = wrapf(pos.x, -BOUNDS, BOUNDS)
		pos.z         = wrapf(pos.z, -BOUNDS, BOUNDS)
		g["bob_t"]    = bob_t
		g["pos"]      = pos
		mi.position   = pos


## Advance each flock's parametric time and compute its world-space centre.
## Lissajous: x = ax*sin(fx*t), y = y_ctr + y_amp*sin(fy*t), z = az*sin(fz*t)
func _tick_flock_centres(delta: float) -> void:
	for flock in _bat_flocks:
		flock["t"] = float(flock["t"]) + delta * float(flock["speed"])
		var t   : float = float(flock["t"])
		var cx  : float = float(flock["ax"]) * sin(float(flock["fx"]) * t)
		var cy  : float = float(flock["y_ctr"]) + float(flock["y_amp"]) * sin(float(flock["fy"]) * t)
		var cz  : float = float(flock["az"]) * sin(float(flock["fz"]) * t)
		flock["centre"] = Vector3(cx, cy, cz)


## Bats pull toward their flock centre (with personal offset) + a small lag.
## The lag makes trailing bats follow a slightly older flock position,
## creating the elongated teardrop shape of a real bat swarm.
func _tick_bats(dt: float, start: int, count: int) -> void:
	var end : int = mini(start + count, _bats.size())
	for i in range(start, end):
		var b   : Dictionary     = _bats[i]
		var mi  : MeshInstance3D = b["mesh"]
		if not is_instance_valid(mi):
			continue

		var fi     : int     = int(b["flock_idx"])
		var flock  : Dictionary = _bat_flocks[fi]

		# Target = flock centre + personal scatter offset
		var target : Vector3 = (flock["centre"] as Vector3) + (b["offset"] as Vector3)

		# Lerp position toward target — rate proportional to path_lag inverse
		# Fast bats (low lag) snap to centre; slow bats (high lag) trail behind
		var follow_rate : float = lerp(8.0, 3.5, float(b["path_lag"]))
		var pos         : Vector3 = b["pos"]
		pos = pos.lerp(target, clampf(follow_rate * dt, 0.0, 1.0))

		b["pos"]    = pos
		mi.position = pos


func _tick_wind(dt: float) -> void:
	for w in _winds:
		var mi : MeshInstance3D = w["mesh"]
		if not is_instance_valid(mi):
			continue
		var pos : Vector3 = w["pos"]
		pos.x += float(w["speed"]) * dt
		if pos.x > 50.0:
			pos.x = -50.0
			pos.y = randf_range(0.5, 8.0)
			pos.z = randf_range(-45.0, 45.0)
		w["pos"]    = pos
		mi.position = pos


# ══════════════════════════════════════════════════════════════
# SOUNDS & FOG
# ══════════════════════════════════════════════════════════════

func _play_sounds() -> void:
	if is_instance_valid(scary_sound):
		scary_sound.volume_db = scary_sound_volume_db
		scary_sound.play()
	if is_instance_valid(night_ambience):
		night_ambience.stream_paused = false
		if not night_ambience.finished.is_connected(_loop_night_ambience):
			night_ambience.finished.connect(_loop_night_ambience, CONNECT_ONE_SHOT)
		night_ambience.play()


func _loop_night_ambience() -> void:
	if is_instance_valid(night_ambience) and match_started:
		night_ambience.play()
		night_ambience.finished.connect(_loop_night_ambience, CONNECT_ONE_SHOT)


func _spawn_ambient_fog_patches() -> void:
	var fse := get_tree().get_first_node_in_group("fog_spawn_effect")
	if not is_instance_valid(fse) or not fse.has_method("_spawn_fog_patch"):
		return
	var ls := get_tree().get_first_node_in_group("lane_spawner")
	if not is_instance_valid(ls):
		return
	for team in [1, 2]:
		for lane in 3:
			var wps : Array = ls.get_lane_waypoints(team, lane)
			if wps.size() < 3:
				continue
			var mid : Vector3 = wps[wps.size() / 2]
			mid.y = 0.0
			fse._spawn_fog_patch(mid, 5.0)


# ══════════════════════════════════════════════════════════════
# LEGACY SPAWNER HELPERS
# ══════════════════════════════════════════════════════════════

func _reset_legacy_spawners() -> void:
	if Engine.has_singleton("ZombieHordeManager"):
		var zhm = Engine.get_singleton("ZombieHordeManager")
		if zhm.has_method("reset_for_new_scene"):
			zhm.reset_for_new_scene()


func _spawn_starting_turrets() -> void:
	var scene_path := "res://scenes/fire_turret.tscn"
	if not ResourceLoader.exists(scene_path): return
	var packed : PackedScene = load(scene_path)
	if not is_instance_valid(packed): return
	# Find team 1 base to place turrets around it
	var base : Node3D = null
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and int(b.get("team_id")) == 1 and b is Node3D:
			base = b as Node3D; break
	if not is_instance_valid(base): return
	var fwd := Vector3(0, 0, 1)
	var right := Vector3(1, 0, 0)
	# 4 turrets in a defensive arc in front of base
	var offsets := [
		right * 8.0  + fwd * 10.0,
		-right * 8.0 + fwd * 10.0,
		right * 14.0 + fwd * 6.0,
		-right * 14.0 + fwd * 6.0,
	]
	var space := get_tree().root.get_world_3d().direct_space_state
	for off in offsets:
		var t := packed.instantiate()
		var spawn : Vector3 = base.global_position + (off as Vector3)
		# Raycast to ground
		if is_instance_valid(space):
			var ray := PhysicsRayQueryParameters3D.create(Vector3(spawn.x, 200.0, spawn.z), Vector3(spawn.x, -50.0, spawn.z))
			ray.collision_mask = 1
			var hit := space.intersect_ray(ray)
			if not hit.is_empty(): spawn.y = hit.position.y + 0.1
		get_tree().current_scene.add_child(t)
		if t is Node3D: (t as Node3D).global_position = spawn
		if "team_id" in t: t.set("team_id", 1)
		t.add_to_group("starting_turret")
	print("[GamePhase] Spawned 4 starting turrets near base")


# AI-teammate feature: guarantees a starter Builder-class TeamAlly exists
# for team 1, checked every round (not just round 1) so a lost one gets
# replaced. Not yet gated to server-only or network-replicated in any way
# -- known, documented v1 scope cut (matching how MutationManager/
# CorruptionManager, called from this same combat-state-enter() block,
# already carry the same caveat): each peer in a networked game spawns
# and sees its own local, unsynced ally, but every ally's actual gold-
# spending goes through game_phase_script.gd's already-networked RPC pair
# regardless of which peer's local instance triggers it, so the economic
# effect stays correct even though the allies' own visibility isn't
# synced yet.
const TEAM_ALLY_SCRIPT : String = "res://team_ally.gd"

func _ensure_team_ally_presence() -> void:
	if not ResourceLoader.exists(TEAM_ALLY_SCRIPT): return
	for a in get_tree().get_nodes_in_group("team_allies"):
		if is_instance_valid(a) and "team_id" in a and int(a.get("team_id")) == 1 \
				and "ally_class" in a and int(a.get("ally_class")) == 0:  # AllyClass.BUILDER
			return   # a starter Builder already exists
	_spawn_team_ally(1, 0, Vector3.ZERO, false, false)   # team 1, BUILDER, near base, not trapped
	print("[GamePhase] Spawned starter Builder ally")


## Shared spawn helper -- also used by HiveCluster.gd for the
## trapped-ally-in-hive mechanic (use_override_pos=true + spawn_pos_override
## lets that caller place it at the hive's position instead of near the
## base; a bool flag rather than a Vector3.ZERO sentinel since a hive could
## legitimately end up placed near world origin).
func _spawn_team_ally(team: int, ally_class_int: int, spawn_pos_override: Vector3, use_override_pos: bool, trapped: bool) -> Node:
	var script : Script = load(TEAM_ALLY_SCRIPT)
	if not is_instance_valid(script): return null

	var spawn : Vector3
	if use_override_pos:
		spawn = spawn_pos_override
	else:
		var base : Node3D = null
		for b in get_tree().get_nodes_in_group("bases"):
			if "team_id" in b and int(b.get("team_id")) == team and b is Node3D:
				base = b as Node3D; break
		if not is_instance_valid(base): return null
		spawn = base.global_position + Vector3(6.0, 0.0, -6.0)
		var space := get_tree().root.get_world_3d().direct_space_state
		if is_instance_valid(space):
			var ray := PhysicsRayQueryParameters3D.create(Vector3(spawn.x, 200.0, spawn.z), Vector3(spawn.x, -50.0, spawn.z))
			ray.collision_mask = 1
			var hit := space.intersect_ray(ray)
			if not hit.is_empty(): spawn.y = hit.position.y

	var ally := CharacterBody3D.new()
	ally.set_script(script)
	ally.team_id = team
	ally.ally_class = ally_class_int
	ally.trapped = trapped
	get_tree().current_scene.add_child(ally)
	ally.global_position = spawn
	return ally


func _disable_legacy_spawners() -> void:
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if is_instance_valid(s) and "active" in s:
			s.set("active", false)
	var ls := get_tree().get_first_node_in_group("lane_spawner")
	if is_instance_valid(ls) and ls.has_method("stop"):
		ls.stop()


# ══════════════════════════════════════════════════════════════
# UTILITY
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
# HIVE TIER SYSTEM
# ══════════════════════════════════════════════════════════════

## Activate all hive_clusters nodes that match `tier`.
## Connects each hive's hive_died signal so we know when to advance.
func _activate_tier(tier: int) -> void:
	_current_active_tier = tier
	_active_hives.clear()

	for hive in get_tree().get_nodes_in_group("hive_clusters"):
		if not is_instance_valid(hive): continue
		if "is_dead" in hive and bool(hive.get("is_dead")): continue
		var hive_tier : int = int(hive.get("hive_tier")) if "hive_tier" in hive else 1
		if hive_tier != tier: continue

		_active_hives.append(hive)
		if hive.has_method("activate"):
			hive.activate()
		# Connect death signal (guard against double-connection)
		if hive.has_signal("hive_died"):
			if not hive.is_connected("hive_died", _on_hive_died):
				hive.hive_died.connect(_on_hive_died, CONNECT_ONE_SHOT)

	var count : int = _active_hives.size()
	if count > 0:
		show_phase_label.emit("⚠ TIER %d HIVES ACTIVE — %d nests spawning enemies!" % [tier, count], true)
		print("[HiveTier] Activated tier %d — %d hives" % [tier, count])
	else:
		print("[HiveTier] No tier %d hives found in scene." % tier)


## Called whenever any hive emits hive_died.
func _on_hive_died(_hive: Node3D) -> void:
	# Remove from active list
	_active_hives.erase(_hive)
	# Check if all current-tier hives are cleared
	_check_tier_progress()


func _check_tier_progress() -> void:
	# Count surviving hives of the active tier
	var alive : int = 0
	for hive in get_tree().get_nodes_in_group("hive_clusters"):
		if not is_instance_valid(hive): continue
		if "is_dead" in hive and bool(hive.get("is_dead")): continue
		if "health"  in hive and float(hive.get("health")) <= 0.0: continue
		var hive_tier : int = int(hive.get("hive_tier")) if "hive_tier" in hive else 1
		if hive_tier == _current_active_tier:
			alive += 1

	if alive > 0:
		return   # still hives alive at this tier

	var next_tier : int = _current_active_tier + 1
	# Check whether any next-tier hives exist
	var next_exists : bool = false
	for hive in get_tree().get_nodes_in_group("hive_clusters"):
		if not is_instance_valid(hive): continue
		if "is_dead" in hive and bool(hive.get("is_dead")): continue
		var hive_tier : int = int(hive.get("hive_tier")) if "hive_tier" in hive else 1
		if hive_tier == next_tier:
			next_exists = true
			break

	if next_exists:
		show_phase_label.emit("✅ TIER %d CLEARED — Tier %d nests awakening!" % [
			_current_active_tier, next_tier], true)
		print("[HiveTier] Tier %d cleared — advancing to tier %d" % [_current_active_tier, next_tier])
		_activate_tier(next_tier)
	else:
		# No more hive tiers — check map clear
		print("[HiveTier] All hive tiers destroyed — checking map clear")
		if _is_map_cleared():
			_end_game(1)


func _get_team_base_pos(team: int) -> Vector3:
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and int(b.get("team_id")) == team and b is Node3D:
			return (b as Node3D).global_position
	return Vector3.ZERO


# ── Public read API ───────────────────────────────────────────
func get_current_round()       -> int:    return _current_round
func get_waves_this_round()    -> int:    return _waves_this_round
func get_player_deploy_wave()  -> int:    return _player_deploy_wave
func is_in_choice_phase()      -> bool:   return get_current_phase() == "choice"
func is_boss_round()           -> bool:   return _current_round > 0 and _current_round % BOSS_EVERY == 0
