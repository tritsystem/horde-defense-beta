# ============================================================
# zombie.gd
# AAA FULL SYSTEM — SINGLE SCRIPT
# ============================================================
# ORIGINAL SYSTEMS (ALL RETAINED, NONE REMOVED)
# ------------------------------------------------------------
# • Stable lane pushing
# • No castle spinning
# • No gate orbiting
# • No attack slot bugs
# • Easy to debug
# • Pool friendly
# • Horde friendly
# • Damage numbers
# • Energy aura
# • Health bars
# • LOD support
# • Multiplayer safe
# ============================================================
# AAA EXTENSIONS ADDED
# ------------------------------------------------------------
# • Elite zombie systems
# • Boss mutations
# • Swarm intelligence
# • Advanced animation states
# • Damage types + armor system
# • Debug overlay tools
# • Network sync layer hooks
# • Phase zombie double health bar
# • Armor DR types (slash/blunt/pierce/magic/fire/ice/poison)
# • Status effects (burn/freeze/poison/stun/slow)
# • Boss phase transitions
# • Swarm pheromone broadcasting
# • Elite ability pool
# • Threat scoring for targeting
# • Debug gizmo overlay
# • Sync snapshot API
# ============================================================

extends CharacterBody3D


# ============================================================
# ENUMS
# ============================================================

enum AIMode {
	LANE_PUSH,
	ATTACK,
	DEFEND,
	STAY,
	FOLLOW_OWNER,
	PATROL
}

enum LOD {
	FULL,
	CHEAP,
	SLEEP
}

# ---- AAA: Zombie tier -------------------------------------

enum ZombieTier {
	BASIC,
	ELITE,
	BOSS,
	PHASE
}

# ---- AAA: Damage types ------------------------------------

enum DamageType {
	PHYSICAL,
	SLASH,
	BLUNT,
	PIERCE,
	MAGIC,
	FIRE,
	ICE,
	POISON,
	TRUE_DAMAGE
}

# ---- AAA: Status effect types -----------------------------

enum StatusType {
	NONE,
	BURN,
	FREEZE,
	POISON,
	STUN,
	SLOW,
	MARKED,
	ENRAGED
}

# ---- AAA: Elite ability pool ------------------------------

enum EliteAbility {
	NONE,
	REGEN,
	SHIELD_BURST,
	LEAP,
	FRENZY,
	GHOST,
	SPORE_CLOUD,
	LIFE_STEAL,
	CHAIN_ATTACK
}

# ============================================================
# TEAM
# ============================================================

@export var team_id : int = 1

# ============================================================
# STATS
# ============================================================

@export_group("Stats")

@export var max_health : float = 350.0
@export var move_speed : float = 4.0
@export var damage : float = 15.0

@export var attack_range : float = 2.3
@export var turret_range : float = 3.5
@export var base_range : float = 5.0

@export var aggro_range : float = 14.0

@export var attack_cooldown : float = 0.9

@export var gravity : float = 20.0

@export var gold_reward : int = 25

# ============================================================
# STUCK
# ============================================================

@export_group("Stuck")

@export var stuck_time : float = 1.5
@export var stuck_distance : float = 0.4

# ============================================================
# AUDIO
# ============================================================

@export_group("Audio")

@export var audio_enabled : bool = true

@export var attack_sounds : Array[AudioStream] = []
@export var hurt_sounds : Array[AudioStream] = []
@export var death_sounds : Array[AudioStream] = []

# ---- AAA: Additional audio slots --------------------------

@export var ability_sounds : Array[AudioStream] = []
@export var phase_sounds : Array[AudioStream] = []
@export var enrage_sounds : Array[AudioStream] = []

# ============================================================
# AAA: TIER & IDENTITY
# ============================================================

@export_group("AAA Tier")

@export var zombie_tier : ZombieTier = ZombieTier.BASIC

@export var tier_label : String = ""

# ---- Phase zombie settings --------------------------------

@export var is_phase_zombie : bool = false
@export var phase_count : int = 2
@export var phase_health_equal : bool = true
@export var phase_transition_delay : float = 0.8

# ---- Boss settings ----------------------------------------

@export var is_boss : bool = false
@export var boss_phase_thresholds : Array[float] = [0.75, 0.5, 0.25]
@export var boss_enrage_threshold : float = 0.25

# ---- Elite settings ---------------------------------------

@export var is_elite : bool = false
@export var elite_ability : EliteAbility = EliteAbility.NONE
@export var elite_ability_cooldown : float = 8.0

# ============================================================
# AAA: ARMOR SYSTEM
# ============================================================

@export_group("AAA Armor")

@export var armor_physical : float = 0.0
@export var armor_slash : float = 0.0
@export var armor_blunt : float = 0.0
@export var armor_pierce : float = 0.0
@export var armor_magic : float = 0.0
@export var armor_fire : float = 0.0
@export var armor_ice : float = 0.0
@export var armor_poison : float = 0.0

# ---- DR cap -----------------------------------------------

@export var armor_dr_cap : float = 0.85

# ============================================================
# AAA: SWARM INTELLIGENCE
# ============================================================

@export_group("AAA Swarm")

@export var swarm_enabled : bool = true
@export var swarm_broadcast_radius : float = 12.0
@export var swarm_pheromone_strength : float = 1.0
@export var swarm_follow_leader : bool = true

# ============================================================
# AAA: DEBUG
# ============================================================

@export_group("AAA Debug")

@export var debug_overlay_enabled : bool = false
@export var debug_show_range : bool = true
@export var debug_show_target_line : bool = true
@export var debug_show_ai_mode : bool = true
@export var debug_show_status : bool = true

# ============================================================
# AAA: NETWORK
# ============================================================

@export_group("AAA Network")

@export var network_sync_enabled : bool = false
@export var network_sync_rate : float = 0.1
@export var network_authority_id : int = 1

# ============================================================
# HEALTH
# ============================================================

var health : float = 0.0

# ---- Phase health tracking --------------------------------

var phase_current : int = 0
var phase_health_thresholds : Array[float] = []
var phase_transitioning : bool = false
var phase_transition_timer : float = 0.0

# ============================================================
# TARGETS
# ============================================================

var target : Node3D = null
var target_type : String = ""

var enemy_base : Node3D = null
var friendly_base : Node3D = null

# ============================================================
# AI
# ============================================================
# ============================================================
# PATH VALIDATION
# ============================================================

var unreachable_timer : float = 0.0
var last_target_distance : float = INF
var target_progress_timer : float = 0.0
var _unreachable_blacklist : Dictionary = {}  # node → cooldown timer

@export var unreachable_timeout : float = 2.5
@export var min_progress_distance : float = 0.75
var ai_mode : AIMode = AIMode.LANE_PUSH

# ============================================================
# LANE
# ============================================================

var lane_waypoints : Array[Vector3] = []

var current_waypoint : int = 0

# ============================================================
# TIMERS
# ============================================================

var attack_timer : float = 0.0
var retarget_timer : float = 0.0

# ============================================================
# STUCK
# ============================================================

var stuck_timer : float = 0.0

var last_position : Vector3 = Vector3.ZERO
var last_position_timer : float = 0.0

# ============================================================
# NEIGHBORS
# ============================================================

var neighbors_cache : Array = []

# ============================================================
# LOD
# ============================================================

var lod : LOD = LOD.FULL
var _body_meshes : Array[MeshInstance3D] = []
var _mesh_near   : bool = true   # true = shadows on, false = shadows off

# ============================================================
# STATE
# ============================================================

var is_dead : bool = false

# ============================================================
# AUDIO PLAYER
# ============================================================

var sfx : AudioStreamPlayer3D = null
var sfx_ability : AudioStreamPlayer3D = null

# ============================================================
# ANIMATION
# ============================================================

var anim_tree : AnimationTree = null

# ---- AAA: Advanced anim state tracking --------------------

var anim_state_current : String = "idle"
var anim_blend_speed : float = 0.0

# ============================================================
# ENERGY
# ============================================================

var energized_timer : float = 0.0

# ============================================================
# HEALTH BAR — PRIMARY
# ============================================================

var health_bar_root : Node3D = null
var health_bar_fill : MeshInstance3D = null

# ============================================================
# HEALTH BAR — PHASE (SECOND BAR)
# ============================================================

var phase_bar_root : Node3D = null
var phase_bar_fill : MeshInstance3D = null
var phase_bar_segment_markers : Array[MeshInstance3D] = []

# ============================================================
# ENERGY ICON
# ============================================================

var energy_icon : MeshInstance3D = null

# ============================================================
# AAA: STATUS EFFECTS
# ============================================================

var status_effects : Dictionary = {}
# Format: { StatusType: { timer: float, strength: float, tick_timer: float } }

var is_stunned : bool = false
var is_frozen : bool = false
var current_slow : float = 0.0

# ============================================================
# AAA: ARMOR SHIELD (elite)
# ============================================================

var shield_hp : float = 0.0
var shield_max : float = 0.0
var shield_active : bool = false

# ============================================================
# AAA: BOSS PHASE
# ============================================================

var boss_phase : int = 0
var boss_enraged : bool = false
var boss_phase_triggered : Array[bool] = []

# ============================================================
# AAA: ELITE ABILITY
# ============================================================

var elite_ability_timer : float = 0.0
var elite_ability_active : bool = false
var elite_ghost_timer : float = 0.0

# ============================================================
# AAA: SWARM
# ============================================================

var swarm_leader : Node3D = null
var swarm_pheromone_pos : Vector3 = Vector3.ZERO
var swarm_pheromone_timer : float = 0.0
var swarm_pheromone_active : bool = false

# ============================================================
# AAA: THREAT SCORE CACHE
# ============================================================

var threat_scores : Dictionary = {}

# ============================================================
# AAA: NETWORK SYNC
# ============================================================

var net_sync_timer : float = 0.0
var net_last_snapshot : Dictionary = {}

# ============================================================
# AAA: LIFE STEAL
# ============================================================

var life_steal_pct : float = 0.0

# ============================================================
# AAA: ENRAGE MULTIPLIERS
# ============================================================

var enrage_damage_mult : float = 1.0
var enrage_speed_mult : float = 1.0

# ============================================================
# AAA: DEBUG OVERLAY
# ============================================================

var debug_label : Node = null
var debug_draw_timer : float = 0.0
# ============================================================
# COMMAND STATE
# ============================================================

enum SquadOrder {
	NONE,
	ATTACK,
	DEFEND,
	PATROL,
	STAY,
	FOLLOW
}

var patrol_points : Array = []
var _patrol_idx   : int   = 0
var _patrol_dir   : int   = 1
var squad_order      : int     = SquadOrder.NONE
var squad_target     : Node3D  = null
var squad_position   : Vector3 = Vector3.ZERO
var order_persistent : bool    = false
var squad_persistent : bool    = false
var squad_timer      : float   = 0.0

# unreachable handling
var _path_fail_time : float = 0.0
const MAX_UNREACHABLE_TIME := 2.5
# ============================================================
# PRIORITY TARGET SYSTEM
# Reworked combat targeting logic
#
# PURPOSE:
# • Enemy players are highest priority
# • Enemy zombies/minions next
# • Structures/objectives only if no nearby threats
# • Stops zombies from ignoring close combat
# • Prevents turret tunnel-vision
# • Supports unreachable fallback behavior
# ============================================================
const PLAYER_PRIORITY_RADIUS := 26.0
const UNIT_PRIORITY_RADIUS := 18.0
const STRUCTURE_RADIUS := 80.0

const PLAYER_PRIORITY_WEIGHT := 1000.0
const UNIT_PRIORITY_WEIGHT := 500.0
const STRUCTURE_PRIORITY_WEIGHT := 100.0


func _update_targeting(delta: float) -> void:

	# =====================================================
	# VALIDATE CURRENT TARGET
	# =====================================================

	if is_instance_valid(target):

		if target.has_method("is_dead") and target.is_dead():
			target = null

		elif "health" in target and target.health <= 0:
			target = null

		elif "team_id" in target and int(target.team_id) == int(team_id):
			target = null


	# =====================================================
	# PRIORITY SEARCH
	# =====================================================

	var best_target : Node3D = null
	var best_score : float = -999999.0

	var my_pos : Vector3 = global_position


	# =====================================================
	# 1. ENEMY PLAYERS
	# =====================================================

	for p in get_tree().get_nodes_in_group("players"):

		if not is_instance_valid(p):
			continue

		if p == self:
			continue

		if not ("team_id" in p):
			continue

		if int(p.team_id) == int(team_id):
			continue

		if p.has_method("is_dead") and p.is_dead():
			continue

		# Skip blacklisted (unreachable) targets
		if _unreachable_blacklist.has(p.get_instance_id()):
			continue

		var d := my_pos.distance_to(p.global_position)

		if d > PLAYER_PRIORITY_RADIUS:
			continue

		var score : float = PLAYER_PRIORITY_WEIGHT - d

		if "health" in p:
			score += clamp(100.0 - float(p.health), 0.0, 100.0)

		if p.get("target") == self:
			score += 250.0

		# unreachable check
		if has_method("_can_reach_position"):
			if not _can_reach_position(p.global_position):
				score -= 900.0

		if score > best_score:
			best_score = score
			best_target = p


	# =====================================================
	# 2. ENEMY UNITS / ZOMBIES
	# =====================================================

	for group_name in ["units", "zombies", "minions"]:

		for u in get_tree().get_nodes_in_group(group_name):

			if not is_instance_valid(u):
				continue

			if u == self:
				continue

			if not ("team_id" in u):
				continue

			if int(u.team_id) == int(team_id):
				continue

			if u.has_method("is_dead") and u.is_dead():
				continue

			var d := my_pos.distance_to(u.global_position)
			# Skip blacklisted (unreachable) targets
			if _unreachable_blacklist.has(u.get_instance_id()):
				continue

			if d > UNIT_PRIORITY_RADIUS:
				continue

			var score : float = UNIT_PRIORITY_WEIGHT - d

			if "health" in u:
				score += clamp(50.0 - float(u.health), 0.0, 50.0)

			if u.get("target") == self:
				score += 100.0

			if has_method("_can_reach_position"):
				if not _can_reach_position(u.global_position):
					score -= 700.0

			if score > best_score:
				best_score = score
				best_target = u


	# =====================================================
	# 3. STRUCTURES / TURRETS
	# =====================================================

	for g in ["turrets", "bases", "structures"]:

		for s in get_tree().get_nodes_in_group(g):

			if not is_instance_valid(s):
				continue

			if not ("team_id" in s):
				continue

			if int(s.team_id) == int(team_id):
				continue

			var d := my_pos.distance_to(s.global_position)

			if d > STRUCTURE_RADIUS:
				continue

			var score : float = STRUCTURE_PRIORITY_WEIGHT - d

			if score > best_score:
				best_score = score
				best_target = s


	# =====================================================
	# APPLY TARGET
	# =====================================================

	if is_instance_valid(best_target):
		target = best_target
# ============================================================
func command_follow(player_node: Node3D, persistent: bool = false) -> void:
	squad_order      = SquadOrder.FOLLOW
	squad_target     = player_node
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0
	ai_mode          = AIMode.FOLLOW_OWNER


func command_defend(persistent: bool = false) -> void:
	squad_order      = SquadOrder.DEFEND
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0
	ai_mode          = AIMode.DEFEND


func command_attack_position(pos: Vector3, persistent: bool = false) -> void:
	squad_order      = SquadOrder.ATTACK
	squad_position   = pos
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0


func command_hold(persistent: bool = false) -> void:
	squad_order      = SquadOrder.STAY
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0


func clear_order() -> void:
	squad_order      = SquadOrder.NONE
	squad_target     = null
	order_persistent = false
	squad_persistent = false
	squad_timer      = 0.0
func _ready() -> void:

	health = max_health

	add_to_group("units")
	add_to_group("zombies")

	if is_phase_zombie:
		add_to_group("phase_zombies")

	if is_boss:
		add_to_group("boss_units")

	if is_elite:
		add_to_group("elite_units")

	last_position = global_position

	_setup_audio()

	anim_tree = _find_anim_tree()

	for m in find_children("*", "MeshInstance3D", true, false):
		_body_meshes.append(m as MeshInstance3D)

	_find_bases()

	_build_health_bar()

	_build_energy_icon()

	# ---- AAA inits ----------------------------------------

	_init_phase_system()

	_init_boss_system()

	_init_elite_system()

	_init_armor_display()

	if debug_overlay_enabled:
		_build_debug_overlay()

	if swarm_enabled:
		_register_swarm()

# ============================================================
# AUDIO
# ============================================================

func _setup_audio() -> void:
	# REAL BUG FIX (2026-07-21): same fix as zombie.gd -- route to the
	# pre-attenuated "zombie fx" bus instead of the unattenuated default.
	sfx = AudioStreamPlayer3D.new()
	sfx.max_distance = 25.0
	sfx.bus = "zombie fx"
	add_child(sfx)

	sfx_ability = AudioStreamPlayer3D.new()
	sfx_ability.max_distance = 30.0
	sfx_ability.bus = "zombie fx"
	add_child(sfx_ability)

# ============================================================
# ANIMATION TREE
# ============================================================

func _find_anim_tree() -> AnimationTree:

	var t : AnimationTree = get_node_or_null("AnimationTree")

	if t != null:
		return t

	for c in get_children():
		if c is AnimationTree:
			return c

	return null

# ============================================================
# FIND BASES
# ============================================================

func _find_bases() -> void:

	enemy_base = null
	friendly_base = null

	for b in get_tree().get_nodes_in_group("bases"):

		if not is_instance_valid(b):
			continue

		if not ("team_id" in b):
			continue

		if int(b.get("team_id")) == team_id:
			friendly_base = b
		else:
			enemy_base = b

# ============================================================
# AAA: INIT PHASE SYSTEM
# ============================================================

func _init_phase_system() -> void:

	if not is_phase_zombie:
		return

	phase_health_thresholds.clear()

	var segment : float = max_health / float(phase_count)

	for i in range(phase_count):
		phase_health_thresholds.append(
			max_health - segment * float(i + 1)
		)

	phase_current = 0
	phase_transitioning = false

	_build_phase_health_bar()

# ============================================================
# AAA: INIT BOSS SYSTEM
# ============================================================

func _init_boss_system() -> void:

	if not is_boss:
		return

	boss_phase = 0
	boss_enraged = false

	boss_phase_triggered.clear()

	for _i in boss_phase_thresholds.size():
		boss_phase_triggered.append(false)

# ============================================================
# AAA: INIT ELITE SYSTEM
# ============================================================

func _init_elite_system() -> void:

	if not is_elite:
		return

	elite_ability_timer = randf_range(
		elite_ability_cooldown * 0.3,
		elite_ability_cooldown
	)

	if elite_ability == EliteAbility.SHIELD_BURST:
		shield_max = max_health * 0.3
		shield_hp = shield_max
		shield_active = true

	if elite_ability == EliteAbility.LIFE_STEAL:
		life_steal_pct = 0.12

# ============================================================
# AAA: INIT ARMOR DISPLAY (placeholder hook)
# ============================================================

func _init_armor_display() -> void:
	# Future: spawn floating armor text or icon overlay
	pass

# ============================================================
# PHYSICS
# ============================================================

func _physics_process(delta: float) -> void:

	if is_dead:
		return

	_update_timers(delta)

	_apply_gravity(delta)

	# ---- Phase transition hold ----------------------------

	if phase_transitioning:

		phase_transition_timer -= delta

		velocity.x = move_toward(velocity.x, 0.0, move_speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 8.0 * delta)

		move_and_slide()

		_update_animation()

		_update_health_bar()

		_update_phase_bar()

		_update_energy_icon()

		if phase_transition_timer <= 0.0:

			phase_transitioning = false

			_on_phase_complete()

		return

	# ---- Stun hold ----------------------------------------

	if is_stunned:

		# Tick status effects so freeze/slow timers still expire
		_tick_status_effects(delta)

		velocity.x = move_toward(velocity.x, 0.0, move_speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 8.0 * delta)

		move_and_slide()

		_update_animation()

		_update_health_bar()

		_update_phase_bar()

		_update_energy_icon()

		if debug_overlay_enabled:
			_tick_debug_overlay(delta)

		return

	match lod:
		LOD.FULL:
			_tick_full(delta)
		LOD.CHEAP:
			_tick_cheap(delta)
	_validate_target_reachability(delta)
	move_and_slide()

	_update_animation()

	_update_stuck(delta)

	_update_health_bar()

	_update_phase_bar()

	_update_energy_icon()

	# ---- AAA ticks ----------------------------------------

	_tick_status_effects(delta)

	_tick_elite_ability(delta)

	_tick_boss_checks()

	_tick_swarm(delta)

	_tick_network_sync(delta)

	if debug_overlay_enabled:
		_tick_debug_overlay(delta)
	
# ============================================================
# TIMERS
# ============================================================

func _update_timers(delta: float) -> void:

	attack_timer = maxf(0.0, attack_timer - delta)

	retarget_timer -= delta

	energized_timer = maxf(0.0, energized_timer - delta)
	if energized_timer <= 0.0: energized_stacks = 0

	# Tick down unreachable blacklist
	for iid in _unreachable_blacklist.keys():
		_unreachable_blacklist[iid] -= delta
		if _unreachable_blacklist[iid] <= 0.0:
			_unreachable_blacklist.erase(iid)

	elite_ability_timer = maxf(0.0, elite_ability_timer - delta)

	swarm_pheromone_timer = maxf(0.0, swarm_pheromone_timer - delta)

	net_sync_timer = maxf(0.0, net_sync_timer - delta)

	# Squad command: non-persistent orders expire after 1s
	if squad_order != SquadOrder.NONE and not squad_persistent and not order_persistent:
		squad_timer += delta
		if squad_timer >= 1.0:
			squad_order      = SquadOrder.NONE
			squad_target     = null
			squad_persistent = false
			squad_timer      = 0.0
			ai_mode          = AIMode.LANE_PUSH

# ============================================================
# GRAVITY
# ============================================================

func _apply_gravity(delta: float) -> void:

	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

# ============================================================
# FULL AI
# ============================================================

func _tick_full(delta: float) -> void:

	if retarget_timer <= 0.0:

		retarget_timer = randf_range(0.25, 0.5)

		# Skip auto-targeting when player has issued a command
		if squad_order == SquadOrder.NONE:
			_find_best_target()

	# ---- Ghost elite: pass through units ------------------

	if elite_ghost_timer > 0.0:

		elite_ghost_timer -= delta

	match ai_mode:
		AIMode.LANE_PUSH:
			_tick_lane_push(delta)
		AIMode.ATTACK:
			_tick_attack(delta)
		AIMode.DEFEND:
			_tick_defend(delta)
		AIMode.STAY:
			_tick_stay(delta)
		AIMode.FOLLOW_OWNER:
			_tick_follow(delta)
		AIMode.PATROL:
			_tick_patrol(delta)

# ============================================================
# CHEAP AI
# ============================================================

func _tick_cheap(delta: float) -> void:

	if is_instance_valid(target):

		_move_toward(
			target.global_position,
			move_speed * 0.8,
			delta
		)

	elif is_instance_valid(enemy_base):

		_move_toward(
			enemy_base.global_position,
			move_speed * 0.8,
			delta
		)

# ============================================================
# TARGETING
# ============================================================

func _find_best_target() -> void:

	target = null
	target_type = ""

	var best_target : Node3D = null
	var best_type : String = ""

	var best_score : float = -INF

	# ========================================================
	# COMBAT THREAT RANGE
	# ========================================================

	var combat_range : float = aggro_range

	# bosses aggro harder
	if is_boss:
		combat_range *= 1.4

	# ========================================================
	# PRIORITY 1 — PLAYERS
	# ========================================================

	for p in get_tree().get_nodes_in_group("players"):

		if not is_instance_valid(p):
			continue

		if p == self:
			continue

		if not ("team_id" in p):
			continue

		if int(p.get("team_id")) == team_id:
			continue

		# Skip blacklisted
		if _unreachable_blacklist.has(p.get_instance_id()):
			continue

		var d : float = global_position.distance_to(
			p.global_position
		)

		if d > combat_range:
			continue

		var score : float = 10000.0

		# closer = higher priority
		score -= d * 25.0

		# weak targets are prioritized
		if "health" in p and "max_health" in p:

			var hp_pct : float = (
				float(p.get("health")) /
				maxf(float(p.get("max_health")), 1.0)
			)

			score += (1.0 - hp_pct) * 500.0

		# attacking us?
		if p.has_method("get_target"):
			if p.get_target() == self:
				score += 250.0

		if score > best_score:

			best_score = score
			best_target = p
			best_type = "player"

	# ========================================================
	# PRIORITY 2 — ENEMY ZOMBIES / UNITS
	# ========================================================

	for u in get_tree().get_nodes_in_group("units"):

		if not is_instance_valid(u):
			continue

		if u == self:
			continue

		if not ("team_id" in u):
			continue

		if int(u.get("team_id")) == team_id:
			continue

		# Skip blacklisted
		if _unreachable_blacklist.has(u.get_instance_id()):
			continue

		var d : float = global_position.distance_to(
			u.global_position
		)

		if d > combat_range:
			continue

		var score : float = 5000.0

		score -= d * 18.0

		# elites/bosses become priority
		if "is_boss" in u and u.get("is_boss"):
			score += 1000.0

		elif "is_elite" in u and u.get("is_elite"):
			score += 350.0

		# attacking us?
		if u.has_method("get_target"):
			if u.get_target() == self:
				score += 180.0

		# low hp cleanup behavior
		if "health" in u and "max_health" in u:

			var hp_pct : float = (
				float(u.get("health")) /
				maxf(float(u.get("max_health")), 1.0)
			)

			score += (1.0 - hp_pct) * 250.0

		if score > best_score:

			best_score = score
			best_target = u
			best_type = "unit"

	# ========================================================
	# PRIORITY 3 — TURRETS
	# ONLY IF NO COMBAT THREATS
	# ========================================================
	
	if best_target == null:

		for t in get_tree().get_nodes_in_group("turrets"):

			if not is_instance_valid(t):
				continue
	
			if not ("team_id" in t):
				continue

			if int(t.get("team_id")) == team_id:
				continue

			var d : float = global_position.distance_to(
				t.global_position
			)

			if d > aggro_range * 1.6:
				continue

			var score : float = 1000.0

			score -= d * 10.0

			if score > best_score:

				best_score = score
				best_target = t
				best_type = "turret"

	# ========================================================
	# PRIORITY 4 — BASE PUSH
	# ========================================================

	if best_target == null and is_instance_valid(enemy_base):

		best_target = enemy_base
		best_type = "base"

	# ========================================================
	# APPLY TARGET
	# ========================================================

	target = best_target
	target_type = best_type

	# ========================================================
	# AI MODE — only override if no squad order is active
	# ========================================================

	# Never let targeting override a player-issued command
	if squad_order != SquadOrder.NONE:
		return

	if is_instance_valid(target):
		if target_type == "base":
			ai_mode = AIMode.LANE_PUSH
		else:
			ai_mode = AIMode.ATTACK
	else:
		ai_mode = AIMode.LANE_PUSH

func _get_threat_score(node: Node3D, dist: float) -> float:

	if threat_scores.has(node):
		return threat_scores[node]

	return 100.0 / maxf(dist, 1.0)

# ============================================================
# LANE PUSH
# ============================================================

func _tick_lane_push(delta: float) -> void:

	if is_instance_valid(target):

		var dist : float = global_position.distance_to(target.global_position)

		var range : float = _get_attack_range()

		if dist <= range:

			velocity.x = move_toward(
				velocity.x,
				0.0,
				move_speed * 10.0 * delta
			)

			velocity.z = move_toward(
				velocity.z,
				0.0,
				move_speed * 10.0 * delta
			)

			_face_target(target.global_position)

			_try_attack(target)

			return

		var effective_speed : float = move_speed * enrage_speed_mult * (
			1.0 - current_slow
		)

		_move_toward(
			target.global_position,
			effective_speed,
			delta
		)

		return
func _validate_target_reachability(delta: float) -> void:

	if not is_instance_valid(target):
		unreachable_timer = 0.0; last_target_distance = INF; return

	if target_type == "base":
		return

	var dist : float = global_position.distance_to(target.global_position)

	# Already in range — reset
	if dist <= _get_attack_range() + 0.5:
		unreachable_timer = 0.0
		target_progress_timer = 0.0
		last_target_distance = dist
		return

	# Initialize baseline on first call
	if last_target_distance == INF:
		last_target_distance = dist
		return

	target_progress_timer += delta
	if target_progress_timer < 0.5:
		return
	target_progress_timer = 0.0

	var progress : float = last_target_distance - dist
	last_target_distance = dist

	if progress < min_progress_distance:
		unreachable_timer += 0.5
	else:
		unreachable_timer = maxf(0.0, unreachable_timer - 0.25)

	if unreachable_timer >= unreachable_timeout:
		_clear_unreachable_target()

# ============================================================
# ATTACK
# ============================================================

func _tick_attack(delta: float) -> void:
	# Find and attack nearest enemy; hold position if none found
	if is_instance_valid(target) and target_type != "base":
		_tick_lane_push(delta)
		return
	_find_best_target()
	if is_instance_valid(target):
		_tick_lane_push(delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)

# ============================================================
# DEFEND
# ============================================================

func _tick_defend(delta: float) -> void:
	# Attack nearby enemies first, then fall back to base if none
	if is_instance_valid(target) and _target_in_defend_range():
		_tick_lane_push(delta)
		return
	_find_best_target()
	if is_instance_valid(target) and _target_in_defend_range():
		_tick_lane_push(delta)
		return
	# No enemies nearby — move to friendly base
	target = null
	if not is_instance_valid(friendly_base): return
	var d : float = global_position.distance_to(friendly_base.global_position)
	if d > 6.0:
		_move_toward(friendly_base.global_position, move_speed, delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)


func _target_in_defend_range() -> bool:
	if not is_instance_valid(target): return false
	var anchor : Vector3 = friendly_base.global_position if is_instance_valid(friendly_base) else global_position
	return target.global_position.distance_to(anchor) <= 20.0

# ============================================================
# STAY
# ============================================================

func _tick_stay(delta: float) -> void:

	velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)


func _tick_follow(delta: float) -> void:
	# Follow squad_target — also attack enemies that are close to the player
	var follow_target : Node3D = squad_target if is_instance_valid(squad_target) else null
	if not is_instance_valid(follow_target):
		velocity.x = 0.0; velocity.z = 0.0; return
	# Attack nearby enemies (within 12m of the player) before following
	if is_instance_valid(target):
		var tgt_near : bool = is_instance_valid(follow_target) and 			target.global_position.distance_to(follow_target.global_position) <= 12.0
		if tgt_near:
			_tick_lane_push(delta)
			return
		target = null
	# Scan for enemies near the player
	_find_best_target()
	if is_instance_valid(target):
		var near : bool = target.global_position.distance_to(follow_target.global_position) <= 12.0
		if near:
			_tick_lane_push(delta)
			return
		target = null
	# No threat — stay close to player
	var d : float = global_position.distance_to(follow_target.global_position)
	if d <= 2.5:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)
	else:
		_move_toward(follow_target.global_position, move_speed, delta)


func _tick_patrol(delta: float) -> void:
	if not "patrol_points" in self or patrol_points.is_empty():
		velocity.x = 0.0; velocity.z = 0.0; return
	var dest : Vector3 = patrol_points[_patrol_idx]
	if global_position.distance_to(dest) < 1.5:
		_patrol_idx += _patrol_dir
		if _patrol_idx >= patrol_points.size(): _patrol_idx = patrol_points.size()-2; _patrol_dir = -1
		elif _patrol_idx < 0: _patrol_idx = 1; _patrol_dir = 1
		_patrol_idx = clampi(_patrol_idx, 0, patrol_points.size()-1)
	else:
		_move_toward(dest, move_speed, delta)


# ============================================================
# MOVE
# ============================================================

func _move_toward(
	pos: Vector3,
	speed: float,
	delta: float
) -> void:

	var dir : Vector3 = pos - global_position

	dir.y = 0.0

	if dir.length_squared() <= 0.001:
		return

	dir = dir.normalized()

	dir += _get_separation_force()

	if dir.length_squared() <= 0.001:
		return

	dir = dir.normalized()

	velocity.x = lerp(velocity.x, dir.x * speed, 0.15)
	velocity.z = lerp(velocity.z, dir.z * speed, 0.15)

	rotation.y = lerp_angle(
		rotation.y,
		atan2(dir.x, dir.z),
		0.18
	)

# ============================================================
# SEPARATION
# ============================================================

func _get_separation_force() -> Vector3:

	var force : Vector3 = Vector3.ZERO
	var count : int = 0

	for n in neighbors_cache:

		if count >= 4:
			break

		if not is_instance_valid(n):
			continue

		if n == self:
			continue

		var diff : Vector3 = global_position - n.global_position

		diff.y = 0.0

		var dist : float = diff.length()

		if dist <= 0.01:
			continue

		if dist > 1.0:
			continue

		force += diff.normalized() * (1.0 - (dist / 1.0))

		count += 1

	if force.length_squared() > 0.01:
		force = force.normalized() * 0.35

	return force

# ============================================================
# FACE
# ============================================================

func _face_target(pos: Vector3) -> void:

	var dir : Vector3 = pos - global_position

	dir.y = 0.0

	if dir.length_squared() <= 0.01:
		return

	rotation.y = lerp_angle(
		rotation.y,
		atan2(dir.x, dir.z),
		0.25
	)

# ============================================================
# RANGE
# ============================================================

func _get_attack_range() -> float:

	match target_type:
		"turret":
			return turret_range
		"base":
			return base_range
		_:
			return attack_range

# ============================================================
# ATTACK
# ============================================================

func _try_attack(t: Node3D) -> void:

	if attack_timer > 0.0:
		return

	if not is_instance_valid(t):
		return

	if "team_id" in t:
		if int(t.get("team_id")) == team_id:
			return

	attack_timer = attack_cooldown

	_play_sound(attack_sounds, 5.0, "zombie_attack")

	if anim_tree != null:
		anim_tree.set(
			"parameters/attack_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
		)

	var final_damage : float = damage * enrage_damage_mult

	# Enchant stacking: each stack = +15% (cap 5 stacks = +75%)
	var enchant_mult : float = 1.0 + energized_stacks * 0.15 if energized_timer > 0.0 else 1.0
	final_damage *= enchant_mult
	if energized_timer <= 0.0:
		if target_type != "turret" and target_type != "base":
			final_damage *= 0.45

	# ---- Chain attack (elite) -----------------------------

	if elite_ability == EliteAbility.CHAIN_ATTACK and is_instance_valid(t):
		_do_chain_attack(final_damage * 0.4)

	# ---- Life steal ---------------------------------------

	if life_steal_pct > 0.0:
		_heal(final_damage * life_steal_pct)

	if t.has_method("take_damage"):
		t.take_damage(final_damage, self)

	# ---- Apply elemental effect from enchantment ----------
	var my_enchant : int = get_meta("enchantment") if has_meta("enchantment") else 0
	if my_enchant > 0 and energized_timer > 0.0:
		_apply_zombie_enchant_effect(t, final_damage, my_enchant)


func _spawn_enchant_number(t: Node, amount: float, enchant: int) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if not is_instance_valid(dn) or not dn.has_method("spawn_number"): return
	if not (t is Node3D): return
	dn.spawn_number(amount, (t as Node3D).global_position + Vector3(0, 2.2, 0), enchant, false)


func _apply_zombie_enchant_effect(t: Node, dmg: float, enchant: int) -> void:
	match enchant:
		1: # FIRE — burn DoT
			if t.has_method("apply_status"): t.apply_status(4, 3.0, dmg * 0.2)
			_zombie_dot(t, dmg * 0.15, 3, 1.0, 1)   # orange numbers
		2: # ICE — slow + number
			if t.has_method("apply_status"): t.apply_status(5, 2.5, 0.4)
			_spawn_enchant_number(t, dmg * 0.1, 2)   # cyan flash
		3: # POISON — poison DoT
			if t.has_method("apply_status"): t.apply_status(6, 5.0, dmg * 0.12)
			_zombie_dot(t, dmg * 0.08, 5, 1.0, 3)   # green numbers
		4: # ELECTRIC — chain to nearby
			_spawn_enchant_number(t, dmg * 0.35, 4)  # yellow
			for n in neighbors_cache:
				if not is_instance_valid(n) or n == t: continue
				if not ("team_id" in n) or int(n.get("team_id")) == team_id: continue
				if (n as Node3D).global_position.distance_to(t.global_position) > 4.0: continue
				if n.has_method("take_damage"):
					var chain_dmg := dmg * 0.35
					n.take_damage(chain_dmg, self)
					_spawn_enchant_number(n, chain_dmg, 4)
					break
		5: # SHADOW — extra damage at low HP
			if "health" in t and "max_health" in t:
				if float(t.get("health")) / maxf(float(t.get("max_health")), 1.0) < 0.4:
					var shadow_dmg := dmg * 0.5
					if t.has_method("take_damage"): t.take_damage(shadow_dmg, self)
					_spawn_enchant_number(t, shadow_dmg, 5)  # purple
		6: # VAMPIRIC — heal self + red number
			var heal_amt := dmg * 0.25
			_heal(heal_amt)
			# Show heal as vampiric number above self
			var dn := get_tree().get_first_node_in_group("damage_numbers")
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(heal_amt, global_position + Vector3(0, 2.5, 0), 6, false)


func _zombie_dot(t: Node, dmg: float, ticks: int, interval: float, enchant_type: int = 0) -> void:
	if ticks <= 0 or not is_instance_valid(t): return
	if t.has_method("is_dead") and t.is_dead(): return
	if t.has_method("take_damage"): t.take_damage(dmg, self)
	_spawn_enchant_number(t, dmg, enchant_type)
	get_tree().create_timer(interval).timeout.connect(
		func(): _zombie_dot(t, dmg, ticks - 1, interval, enchant_type), CONNECT_ONE_SHOT)

# ============================================================
# AAA: CHAIN ATTACK
# ============================================================

func _do_chain_attack(chain_damage: float) -> void:

	var chain_count : int = 0

	for n in neighbors_cache:

		if chain_count >= 2:
			break

		if not is_instance_valid(n):
			continue

		if n == self or n == target:
			continue

		if not ("team_id" in n):
			continue

		if int(n.get("team_id")) == team_id:
			continue

		var d : float = global_position.distance_to(n.global_position)

		if d > attack_range * 2.5:
			continue

		if n.has_method("take_damage"):
			n.take_damage(chain_damage, self)

		chain_count += 1

# ============================================================
# AAA: HEAL
# ============================================================

func _heal(amount: float) -> void:

	if is_dead:
		return

	health = minf(health + amount, max_health)

# ============================================================
# DAMAGE (ORIGINAL + AAA ARMOR + STATUS + PHASE)
# ============================================================

# Enchant weakness table — index = enchant type, value = weakness enchant type
# FIRE(1) weak to ICE(2), ICE(2) weak to FIRE(1), POISON(3) weak to ELECTRIC(4),
# ELECTRIC(4) weak to POISON(3), SHADOW(5) weak to VAMPIRIC(6), VAMPIRIC(6) weak to SHADOW(5)
const ENCHANT_WEAKNESS : Array = [0, 2, 1, 4, 3, 6, 5]

func take_damage(
	amount: float,
	instigator = null,
	damage_type: int = DamageType.PHYSICAL
) -> void:

	if is_dead:
		return

	if phase_transitioning:
		return

	# ---- Enchant weakness check --------------------------------
	# If zombie is energized AND instigator has the weakness enchant → +50% damage
	if energized_timer > 0.0 and is_instance_valid(instigator):
		var zombie_enchant : int = get_meta("enchantment") if has_meta("enchantment") else 0
		var atk_enchant   : int = int(instigator.get("enchantment") if "enchantment" in instigator else 0)
		if zombie_enchant > 0 and atk_enchant > 0:
			if ENCHANT_WEAKNESS[zombie_enchant] == atk_enchant:
				amount *= 1.5   # weakness bonus
			elif atk_enchant == zombie_enchant:
				amount *= 0.75  # same element is slightly resisted

	# ---- Shield absorb (elite) ----------------------------

	if shield_active and shield_hp > 0.0:

		var absorbed : float = minf(shield_hp, amount)

		shield_hp -= absorbed
		amount -= absorbed

		if shield_hp <= 0.0:
			shield_active = false

		_spawn_damage_number(absorbed, true)

		if amount <= 0.0:
			return

	# ---- Armor DR -----------------------------------------

	var reduced : float = _apply_armor(amount, damage_type)

	health -= reduced

	_play_sound(hurt_sounds, 2.0)

	_spawn_damage_number(reduced, false)

	if is_instance_valid(instigator) and instigator is Node3D:
		# Only retaliate against actual combat units — not weapons/projectiles
		var _ins := instigator as Node3D
		var _is_combatant : bool = (
			_ins.is_in_group("player") or
			_ins.is_in_group("units")  or
			_ins.is_in_group("zombies")
		)
		if _is_combatant:
			target = _ins
			target_type = "unit"

	# ---- Status on hit (example: fire applies burn) -------

	_maybe_apply_status_from_damage(damage_type)

	# ---- Phase check first --------------------------------

	if is_phase_zombie:

		_check_phase_transition()

		if phase_transitioning:
			return

	# ---- Boss threshold check ----------------------------

	if is_boss:
		_check_boss_thresholds()

	if health <= 0.0:
		_die()

# ============================================================
# AAA: ARMOR DR
# ============================================================

func _apply_armor(amount: float, damage_type: int) -> float:

	if damage_type == DamageType.TRUE_DAMAGE:
		return amount

	var dr : float = 0.0

	match damage_type:
		DamageType.PHYSICAL:
			dr = armor_physical
		DamageType.SLASH:
			dr = armor_slash
		DamageType.BLUNT:
			dr = armor_blunt
		DamageType.PIERCE:
			dr = armor_pierce
		DamageType.MAGIC:
			dr = armor_magic
		DamageType.FIRE:
			dr = armor_fire
		DamageType.ICE:
			dr = armor_ice
		DamageType.POISON:
			dr = armor_poison

	var dr_pct : float = dr / (dr + 100.0)

	dr_pct = clampf(dr_pct, 0.0, armor_dr_cap)

	return amount * (1.0 - dr_pct)

# ============================================================
# AAA: DAMAGE NUMBER SPAWN
# ============================================================

func _spawn_damage_number(
	amount: float,
	is_shield: bool
) -> void:

	var dn : Node = get_tree().get_first_node_in_group("damage_numbers")

	if dn == null:
		return

	if not dn.has_method("spawn_number"):
		return

	dn.spawn_number(
		amount,
		global_position + Vector3(0, 2.0, 0),
		1 if is_shield else 0,
		is_shield
	)

# ============================================================
# AAA: STATUS FROM DAMAGE
# ============================================================

func _maybe_apply_status_from_damage(damage_type: int) -> void:

	match damage_type:

		DamageType.FIRE:
			apply_status(StatusType.BURN, 4.0, 5.0)

		DamageType.ICE:
			apply_status(StatusType.FREEZE, 2.0, 1.0)
			apply_status(StatusType.SLOW, 3.0, 0.4)

		DamageType.POISON:
			apply_status(StatusType.POISON, 6.0, 3.0)

# ============================================================
# AAA: APPLY STATUS EFFECT
# ============================================================

func apply_status(
	type: int,
	duration: float,
	strength: float
) -> void:

	if is_dead:
		return

	if status_effects.has(type):

		var existing : Dictionary = status_effects[type]

		var existing_timer : float = existing.get("timer", 0.0)

		status_effects[type] = {
			"timer": maxf(existing_timer, duration),
			"strength": maxf(existing.get("strength", 0.0), strength),
			"tick_timer": existing.get("tick_timer", 0.0)
		}

	else:

		status_effects[type] = {
			"timer": duration,
			"strength": strength,
			"tick_timer": 0.0
		}

	_apply_status_immediate(type, strength)

# ============================================================
# AAA: IMMEDIATE STATUS EFFECT APPLY
# ============================================================

func _apply_status_immediate(type: int, strength: float) -> void:

	match type:

		StatusType.STUN:
			is_stunned = true

		StatusType.FREEZE:
			is_frozen = true
			is_stunned = true

		StatusType.SLOW:
			current_slow = minf(current_slow + strength, 0.8)

		StatusType.ENRAGED:
			enrage_damage_mult = 1.0 + strength
			enrage_speed_mult = 1.0 + (strength * 0.5)

# ============================================================
# AAA: TICK STATUS EFFECTS
# ============================================================

func _tick_status_effects(delta: float) -> void:

	var to_remove : Array = []

	for type in status_effects.keys():

		var data : Dictionary = status_effects[type]

		data["timer"] -= delta

		if data["timer"] <= 0.0:

			to_remove.append(type)
			continue

		# ---- Tick damage effects -------------------------

		match type:

			StatusType.BURN:

				data["tick_timer"] -= delta

				if data["tick_timer"] <= 0.0:

					data["tick_timer"] = 1.0

					var burn_dmg : float = data.get("strength", 5.0)

					health -= burn_dmg

					# Fire-colored damage number (type 1)
					var _dn := get_tree().get_first_node_in_group("damage_numbers")
					if is_instance_valid(_dn) and _dn.has_method("spawn_number"):
						_dn.spawn_number(burn_dmg, global_position + Vector3(0,2.0,0), 1, false)

					if health <= 0.0:
						_die()
						return

			StatusType.POISON:

				data["tick_timer"] -= delta

				if data["tick_timer"] <= 0.0:

					data["tick_timer"] = 1.5

					var poison_dmg : float = data.get("strength", 3.0)

					health -= poison_dmg

					# Poison-colored damage number (type 3)
					var _dn2 := get_tree().get_first_node_in_group("damage_numbers")
					if is_instance_valid(_dn2) and _dn2.has_method("spawn_number"):
						_dn2.spawn_number(poison_dmg, global_position + Vector3(0,2.0,0), 3, false)

					if health <= 0.0:
						_die()
						return

	for type in to_remove:

		_expire_status(type)

		status_effects.erase(type)

# ============================================================
# AAA: EXPIRE STATUS
# ============================================================

func _expire_status(type: int) -> void:

	match type:

		StatusType.STUN:
			is_stunned = false

		StatusType.FREEZE:
			is_frozen = false
			is_stunned = false

		StatusType.SLOW:
			current_slow = 0.0
			# Re-check if another slow is still active
			for other_type in status_effects.keys():
				if other_type == StatusType.SLOW:
					current_slow = status_effects[other_type].get("strength", 0.0)

		StatusType.ENRAGED:
			enrage_damage_mult = 1.0
			enrage_speed_mult = 1.0

# ============================================================
# AAA: PHASE ZOMBIE — CHECK TRANSITION
# ============================================================

func _check_phase_transition() -> void:

	if phase_current >= phase_health_thresholds.size():
		return

	var threshold : float = phase_health_thresholds[phase_current]

	if health <= threshold:

		phase_transitioning = true
		phase_transition_timer = phase_transition_delay

		_play_sound(phase_sounds, 8.0)

		if anim_tree != null:
			anim_tree.set(
				"parameters/phase_shot/request",
				AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
			)

		_on_phase_start(phase_current)

# ============================================================
# AAA: PHASE START
# ============================================================

func _on_phase_start(phase_index: int) -> void:

	# Override in subclass or connect signal for custom logic
	emit_signal("phase_started", phase_index)

# ============================================================
# AAA: PHASE COMPLETE
# ============================================================

func _on_phase_complete() -> void:

	phase_current += 1

	emit_signal("phase_completed", phase_current - 1)

	# ---- Partial heal between phases ----------------------

	if phase_current < phase_health_thresholds.size():

		health = maxf(
			health,
			phase_health_thresholds[phase_current - 1] * 0.1
		)

# ============================================================
# AAA: BOSS — CHECK THRESHOLDS
# ============================================================

func _tick_boss_checks() -> void:

	if not is_boss:
		return

	var pct : float = health / maxf(max_health, 1.0)

	for i in boss_phase_thresholds.size():

		if boss_phase_triggered[i]:
			continue

		if pct <= boss_phase_thresholds[i]:

			boss_phase_triggered[i] = true
			boss_phase = i + 1

			_on_boss_phase_start(boss_phase)

	if not boss_enraged and pct <= boss_enrage_threshold:

		boss_enraged = true

		_play_sound(enrage_sounds, 10.0)

		apply_status(StatusType.ENRAGED, 9999.0, 0.5)

		emit_signal("boss_enraged")

func _check_boss_thresholds() -> void:

	_tick_boss_checks()

# ============================================================
# AAA: BOSS PHASE START
# ============================================================

func _on_boss_phase_start(phase_index: int) -> void:

	emit_signal("boss_phase_started", phase_index)

# ============================================================
# AAA: ELITE ABILITY TICK
# ============================================================

func _tick_elite_ability(delta: float) -> void:

	if not is_elite:
		return

	if elite_ability_timer > 0.0:
		return

	elite_ability_timer = elite_ability_cooldown

	_fire_elite_ability()

# ============================================================
# AAA: FIRE ELITE ABILITY
# ============================================================

func _fire_elite_ability() -> void:

	_play_sound_on(sfx_ability, ability_sounds, 7.0, "zombie_ability")

	match elite_ability:

		EliteAbility.REGEN:
			_ability_regen()

		EliteAbility.SHIELD_BURST:
			_ability_shield_burst()

		EliteAbility.LEAP:
			_ability_leap()

		EliteAbility.FRENZY:
			_ability_frenzy()

		EliteAbility.GHOST:
			_ability_ghost()

		EliteAbility.SPORE_CLOUD:
			_ability_spore_cloud()

		EliteAbility.LIFE_STEAL:
			pass

		EliteAbility.CHAIN_ATTACK:
			pass

# ============================================================
# AAA: ELITE — REGEN
# ============================================================

func _ability_regen() -> void:

	var regen_amount : float = max_health * 0.08

	_heal(regen_amount)

# ============================================================
# AAA: ELITE — SHIELD BURST
# ============================================================

func _ability_shield_burst() -> void:

	shield_hp = shield_max
	shield_active = true

# ============================================================
# AAA: ELITE — LEAP
# ============================================================

func _ability_leap() -> void:

	if not is_instance_valid(target):
		return

	var dir : Vector3 = (
		target.global_position - global_position
	).normalized()

	dir.y = 0.0

	velocity.x = dir.x * move_speed * 4.0
	velocity.z = dir.z * move_speed * 4.0

	if is_on_floor():
		velocity.y = 8.0

# ============================================================
# AAA: ELITE — FRENZY
# ============================================================

func _ability_frenzy() -> void:

	apply_status(StatusType.ENRAGED, 5.0, 0.4)

# ============================================================
# AAA: ELITE — GHOST
# ============================================================

func _ability_ghost() -> void:

	elite_ghost_timer = 3.0

# ============================================================
# AAA: ELITE — SPORE CLOUD
# ============================================================

func _ability_spore_cloud() -> void:

	for n in neighbors_cache:

		if not is_instance_valid(n):
			continue

		if not ("team_id" in n):
			continue

		if int(n.get("team_id")) == team_id:
			continue

		var d : float = global_position.distance_to(n.global_position)

		if d > 4.0:
			continue

		if n.has_method("apply_status"):
			n.apply_status(StatusType.POISON, 5.0, 4.0)

# ============================================================
# AAA: SWARM INTELLIGENCE
# ============================================================

func _register_swarm() -> void:

	add_to_group("swarm_units")

func _tick_swarm(delta: float) -> void:

	if not swarm_enabled:
		return

	if swarm_pheromone_timer > 0.0:
		return

	swarm_pheromone_timer = randf_range(2.0, 4.0)

	_broadcast_pheromone()

	_receive_swarm_data()

func _broadcast_pheromone() -> void:

	if not is_instance_valid(target):
		return

	for n in neighbors_cache:

		if not is_instance_valid(n):
			continue

		if n == self:
			continue

		if not ("team_id" in n):
			continue

		if int(n.get("team_id")) != team_id:
			continue

		if not n.has_method("receive_pheromone"):
			continue

		var d : float = global_position.distance_to(n.global_position)

		if d > swarm_broadcast_radius:
			continue

		n.receive_pheromone(
			target.global_position,
			swarm_pheromone_strength
		)

func _receive_swarm_data() -> void:

	if swarm_leader == null:
		return

	if not is_instance_valid(swarm_leader):
		swarm_leader = null
		return

	if swarm_follow_leader and not is_instance_valid(target):

		if swarm_leader.has_method("get_target"):
			var leader_target : Node3D = swarm_leader.call("get_target")
			if is_instance_valid(leader_target):
				target = leader_target
				target_type = "unit"

# ============================================================
# AAA: RECEIVE PHEROMONE (PUBLIC)
# ============================================================

func receive_pheromone(
	pos: Vector3,
	strength: float
) -> void:

	swarm_pheromone_pos = pos
	swarm_pheromone_active = true
	swarm_pheromone_timer = maxf(
		swarm_pheromone_timer,
		2.0 * strength
	)

# ============================================================
# AAA: GET TARGET (PUBLIC for swarm)
# ============================================================

func get_target() -> Node3D:

	return target

# ============================================================
# DIE
# ============================================================

func _die() -> void:

	if is_dead:
		return

	is_dead = true

	velocity = Vector3.ZERO

	set_physics_process(false)

	_play_sound(death_sounds, 7.0)

	if anim_tree != null:
		anim_tree.set(
			"parameters/death_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
		)

	_award_gold()
	_drop_crystals()
	emit_signal("zombie_died", self)

	# Wait for death animation before freeing — 1.4s matches typical death anim length
	await get_tree().create_timer(1.4).timeout
	if is_instance_valid(self): queue_free()

# ============================================================
# GOLD
# ============================================================

func _drop_crystals() -> void:
	# Use crystal_drop_chance if available (set by subclass or inspector)
	var drop_chance : float = get("crystal_drop_chance") if "crystal_drop_chance" in self else 0.3
	if randf() > drop_chance: return
	var drop_pos : Vector3 = global_position
	# Try to use CrystalShard script
	for path in ["res://scripts/CrystalShard.gd","res://CrystalShard.gd",
				 "res://scenes/CrystalShard.gd","res://pickups/CrystalShard.gd"]:
		if ResourceLoader.exists(path):
			var shard : Node3D = Node3D.new()
			shard.set_script(load(path))
			get_tree().current_scene.add_child(shard)
			shard.global_position = drop_pos + Vector3(randf_range(-0.6,0.6), 1.2, randf_range(-0.6,0.6))
			return
	# Inline fallback crystal
	_spawn_inline_crystal(drop_pos + Vector3(randf_range(-0.5,0.5), 1.2, randf_range(-0.5,0.5)))


func _spawn_inline_crystal(pos: Vector3) -> void:
	var root := Node3D.new()
	get_tree().current_scene.add_child(root); root.global_position = pos
	var mi := MeshInstance3D.new(); var gem := CylinderMesh.new()
	gem.top_radius = 0.0; gem.bottom_radius = 0.18; gem.height = 0.38; gem.radial_segments = 5
	mi.mesh = gem; var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; mat.emission_enabled = true
	mat.emission = Color(0.55,0.2,1.0); mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(0.55,0.2,1.0,0.88); mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat; root.add_child(mi)
	var lt := OmniLight3D.new(); lt.light_color = Color(0.55,0.2,1.0)
	lt.light_energy = 1.5; lt.omni_range = 2.5; lt.shadow_enabled = false; root.add_child(lt)
	var tw := root.create_tween().set_loops()
	tw.tween_property(root,"position:y",pos.y+0.2,0.5).set_trans(Tween.TRANS_SINE)
	tw.tween_property(root,"position:y",pos.y,0.5).set_trans(Tween.TRANS_SINE)
	get_tree().create_timer(18.0).timeout.connect(func():
		if is_instance_valid(root): root.queue_free())


func _award_gold() -> void:

	var gm : Node = get_tree().get_first_node_in_group("game_manager")

	if gm == null:
		return

	var enemy_team : int = 2

	if team_id == 2:
		enemy_team = 1

	if gm.has_method("award_gold"):
		gm.award_gold(enemy_team, gold_reward)

# ============================================================
# STUCK
# ============================================================

func _update_stuck(delta: float) -> void:

	last_position_timer += delta

	if last_position_timer < 0.5:
		return

	last_position_timer = 0.0

	var moved : float = Vector2(
		global_position.x - last_position.x,
		global_position.z - last_position.z
	).length()

	last_position = global_position

	if moved < stuck_distance:

		stuck_timer += 0.5

		if stuck_timer >= stuck_time:
			stuck_timer = 0.0
			_unstuck()

	else:

		stuck_timer = 0.0

# ============================================================
# UNSTUCK
# ============================================================

func _unstuck() -> void:

	var dir := Vector3(
		randf_range(-1.0, 1.0),
		0.0,
		randf_range(-1.0, 1.0)
	)

	if dir.length_squared() <= 0.01:
		dir = Vector3.FORWARD

	dir = dir.normalized()

	global_position += dir * 1.5

	velocity.x += dir.x * 5.0
	velocity.z += dir.z * 5.0

	if is_on_floor():
		velocity.y = 4.0

# ============================================================
# HEALTH BAR — PRIMARY (ORIGINAL)
# ============================================================

func _build_health_bar() -> void:

	# Remove any pre-existing health bar (e.g. from scene editor) to prevent doubles
	var existing := find_child("HBar", true, false)
	if is_instance_valid(existing): existing.queue_free()
	var existing2 := find_child("HealthBar", true, false)
	if is_instance_valid(existing2): existing2.queue_free()

	var root := Node3D.new()
	root.name = "HBar"
	root.position = Vector3(0, 2.5, 0)

	add_child(root)

	health_bar_root = root

	var bg := MeshInstance3D.new()

	var bg_mesh := QuadMesh.new()

	bg_mesh.size = Vector2(1.2, 0.16)

	bg.mesh = bg_mesh

	var bg_mat := StandardMaterial3D.new()

	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.albedo_color = Color(0.05, 0.05, 0.05, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	bg.material_override = bg_mat

	root.add_child(bg)

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.1, 1.0, 0.1)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	root.add_child(fill)

	health_bar_fill = fill

	# ---- AAA: Shield bar slot (built on top) --------------

	_build_shield_bar(root)

# ============================================================
# AAA: SHIELD BAR (attached to primary bar root)
# ============================================================

var shield_bar_fill : MeshInstance3D = null

func _build_shield_bar(parent: Node3D) -> void:

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	fill.position.y = 0.0

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.5, 0.8, 1.0, 0.6)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	fill.visible = false

	parent.add_child(fill)

	shield_bar_fill = fill

# ============================================================
# HEALTH BAR — PHASE (DOUBLE BAR FOR PHASE ZOMBIES)
# ============================================================

func _build_phase_health_bar() -> void:

	var root := Node3D.new()

	# Positioned above the primary bar
	root.position = Vector3(0, 2.8, 0)

	add_child(root)

	phase_bar_root = root

	# ---- Background ---------------------------------------

	var bg := MeshInstance3D.new()

	var bg_mesh := QuadMesh.new()

	bg_mesh.size = Vector2(1.2, 0.16)

	bg.mesh = bg_mesh

	var bg_mat := StandardMaterial3D.new()

	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.albedo_color = Color(0.05, 0.02, 0.08, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	bg.material_override = bg_mat

	root.add_child(bg)

	# ---- Phase fill (purple tinted) ----------------------

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.7, 0.2, 1.0)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	root.add_child(fill)

	phase_bar_fill = fill

	# ---- Segment dividers (one per phase) -----------------

	_build_phase_segment_markers(root)

# ============================================================
# AAA: PHASE SEGMENT MARKERS
# ============================================================

func _build_phase_segment_markers(parent: Node3D) -> void:

	phase_bar_segment_markers.clear()

	if phase_count <= 1:
		return

	for i in range(1, phase_count):

		var marker := MeshInstance3D.new()

		var m_mesh := QuadMesh.new()

		m_mesh.size = Vector2(0.025, 0.18)

		marker.mesh = m_mesh

		var m_mat := StandardMaterial3D.new()

		m_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
		m_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		marker.material_override = m_mat

		# Position divider at the correct fraction of bar width
		var pct : float = float(i) / float(phase_count)

		marker.position.x = (pct - 0.5) * 1.0

		parent.add_child(marker)

		phase_bar_segment_markers.append(marker)

# ============================================================
# UPDATE HEALTH BAR (ORIGINAL + SHIELD OVERLAY)
# ============================================================

func _update_health_bar() -> void:

	if health_bar_fill == null:
		return

	var pct : float = clampf(
		health / maxf(max_health, 0.01),
		0.0,
		1.0
	)

	var qm := health_bar_fill.mesh as QuadMesh

	if qm != null:
		qm.size.x = pct

	health_bar_fill.position.x = (pct - 1.0) * 0.5

	var mat := health_bar_fill.material_override as StandardMaterial3D

	if mat != null:
		mat.albedo_color = Color(1.0 - pct, pct, 0.0)

	# ---- Shield bar overlay --------------------------------

	if shield_bar_fill != null:

		if shield_active and shield_max > 0.0:

			shield_bar_fill.visible = true

			var s_pct : float = clampf(
				shield_hp / shield_max,
				0.0,
				1.0
			)

			var s_qm := shield_bar_fill.mesh as QuadMesh

			if s_qm != null:
				s_qm.size.x = s_pct * pct

			shield_bar_fill.position.x = health_bar_fill.position.x

		else:

			shield_bar_fill.visible = false

# ============================================================
# UPDATE PHASE BAR
# ============================================================

func _update_phase_bar() -> void:

	if not is_phase_zombie:
		return

	if phase_bar_fill == null:
		return

	# ---- Show how much of the current phase remains -------

	var phase_total : int = phase_health_thresholds.size()

	if phase_total == 0:
		return

	var current_phase_top : float = max_health

	if phase_current > 0:
		current_phase_top = phase_health_thresholds[phase_current - 1]

	var current_phase_bottom : float = 0.0

	if phase_current < phase_health_thresholds.size():
		current_phase_bottom = phase_health_thresholds[phase_current]

	var span : float = current_phase_top - current_phase_bottom

	var within : float = health - current_phase_bottom

	var pct : float = clampf(
		within / maxf(span, 0.01),
		0.0,
		1.0
	)

	var qm := phase_bar_fill.mesh as QuadMesh

	if qm != null:
		qm.size.x = pct

	phase_bar_fill.position.x = (pct - 1.0) * 0.5

	# ---- Pulse purple when transitioning ------------------

	var mat := phase_bar_fill.material_override as StandardMaterial3D

	if mat != null:

		if phase_transitioning:

			var pulse : float = 0.5 + 0.5 * sin(
				Time.get_ticks_msec() * 0.012
			)

			mat.albedo_color = Color(
				0.7 + pulse * 0.3,
				0.1,
				1.0
			)

		else:

			mat.albedo_color = Color(0.7, 0.2, 1.0)

# ============================================================
# ENERGY ICON (ORIGINAL)
# ============================================================

func _build_energy_icon() -> void:

	var orb := MeshInstance3D.new()

	var sphere := SphereMesh.new()

	sphere.radius = 0.16

	orb.mesh = sphere

	var mat := StandardMaterial3D.new()

	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.8, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(0.3, 0.8, 1.0, 0.7)

	orb.material_override = mat

	orb.position = Vector3(0, 3.0, 0)

	add_child(orb)

	energy_icon = orb

# ============================================================
# UPDATE ENERGY (ORIGINAL)
# ============================================================

func _update_energy_icon() -> void:

	if energy_icon == null:
		return

	var mat := energy_icon.material_override as StandardMaterial3D

	if mat == null:
		return

	if energized_timer > 0.0:

		var pulse : float = 2.0 + sin(
			Time.get_ticks_msec() * 0.008
		)

		mat.emission_energy_multiplier = pulse

		# Color matches enchant type
		var _my_e : int = get_meta("enchantment") if has_meta("enchantment") else 0
		var _ecols : Array = [Color(0.3,0.8,1.0),Color(1.0,0.35,0.0),Color(0.3,0.8,1.0),
			Color(0.2,0.9,0.1),Color(1.0,0.95,0.1),Color(0.5,0.0,0.8),Color(0.8,0.0,0.2)]
		mat.albedo_color = _ecols[clampi(_my_e, 0, 6)]

	else:

		mat.emission_energy_multiplier = 0.4

		mat.albedo_color = Color(0.3, 0.3, 0.3, 0.4)

# ============================================================
# RECEIVE ENERGY (ORIGINAL)
# ============================================================

var energized_stacks : int = 0  # each stack adds 15% bonus (cap 5)

func receive_energy(duration: float) -> void:
	if energized_timer > 0.0:
		energized_stacks = mini(energized_stacks + 1, 5)
	else:
		energized_stacks = 1
	energized_timer = maxf(energized_timer, duration)

# ============================================================
# ANIMATION (ORIGINAL + AAA STATES)
# ============================================================

func _update_animation() -> void:

	if anim_tree == null:
		return

	var speed : float = Vector2(
		velocity.x,
		velocity.z
	).length()

	var blend : float = clampf(speed / move_speed, 0.0, 1.0)

	anim_tree.set("parameters/move_blend/blend_position", blend)

	# ---- AAA: Advanced state tracking --------------------

	if speed > 0.2:
		anim_state_current = "walk"
	else:
		anim_state_current = "idle"

	if is_stunned or is_frozen:
		anim_state_current = "stunned"

	anim_blend_speed = speed

# ============================================================
# SOUND (ORIGINAL)
# ============================================================

func _play_sound(
	arr: Array,
	volume: float,
	category: String = ""
) -> void:

	if not audio_enabled:
		return

	if sfx == null:
		return

	if arr.is_empty():
		return

	var valid : Array = []

	for s in arr:
		if s != null:
			valid.append(s)

	if valid.is_empty():
		return

	if category != "":
		var am := get_node_or_null("/root/AudioManager")
		if is_instance_valid(am) and not am.claim_voice(category, sfx):
			return

	sfx.stream = valid.pick_random()
	sfx.volume_db = volume
	sfx.pitch_scale = randf_range(0.92, 1.08)
	sfx.play()

# ============================================================
# AAA: PLAY SOUND ON SPECIFIC PLAYER
# ============================================================

func _play_sound_on(
	player: AudioStreamPlayer3D,
	arr: Array,
	volume: float,
	category: String = ""
) -> void:

	if not audio_enabled:
		return

	if player == null:
		return

	if arr.is_empty():
		return

	var valid : Array = []

	for s in arr:
		if s != null:
			valid.append(s)

	if valid.is_empty():
		return

	if category != "":
		var am := get_node_or_null("/root/AudioManager")
		if is_instance_valid(am) and not am.claim_voice(category, player):
			return

	player.stream = valid.pick_random()
	player.volume_db = volume
	player.pitch_scale = randf_range(0.9, 1.1)
	player.play()

# ============================================================
# AAA: DEBUG OVERLAY
# ============================================================

func _build_debug_overlay() -> void:

	# Uses Label3D if available, otherwise skips gracefully

	var label_class := ClassDB.get_class_list()

	if not ClassDB.class_exists("Label3D"):
		return

	debug_label = ClassDB.instantiate("Label3D")

	if debug_label == null:
		return

	debug_label.set("pixel_size", 0.012)
	debug_label.set("billboard", 3)
	debug_label.set("no_depth_test", true)
	debug_label.set("position", Vector3(0, 3.6, 0))
	debug_label.set("font_size", 20)

	add_child(debug_label)

func _tick_debug_overlay(delta: float) -> void:

	debug_draw_timer -= delta

	if debug_draw_timer > 0.0:
		return

	debug_draw_timer = 0.15

	if debug_label == null:
		return

	var lines : Array = []

	if debug_show_ai_mode:
		lines.append("MODE: " + AIMode.keys()[ai_mode])

	if debug_show_target_line and is_instance_valid(target):
		lines.append("TGT: " + target_type + " @ " + str(
			snapped(global_position.distance_to(target.global_position), 0.1)
		) + "m")

	if debug_show_status:

		var status_str : String = ""

		for s in status_effects.keys():
			status_str += StatusType.keys()[s].substr(0, 3) + " "

		if status_str != "":
			lines.append("SFX: " + status_str)

		if boss_enraged:
			lines.append("!! ENRAGED !!")

		if shield_active:
			lines.append("SHIELD: " + str(snapped(shield_hp, 1)))

	debug_label.set("text", "\n".join(lines))

# ============================================================
# AAA: NETWORK SYNC
# ============================================================

func _tick_network_sync(delta: float) -> void:

	if not network_sync_enabled:
		return

	net_sync_timer -= delta

	if net_sync_timer > 0.0:
		return

	net_sync_timer = network_sync_rate

	_emit_sync_snapshot()

func _emit_sync_snapshot() -> void:

	var snapshot : Dictionary = {
		"pos": global_position,
		"vel": velocity,
		"hp": health,
		"phase": phase_current,
		"ai_mode": int(ai_mode),
		"target_id": -1,
		"status": status_effects.keys(),
		"boss_phase": boss_phase,
		"enraged": boss_enraged
	}

	if is_instance_valid(target) and target.has_method("get_instance_id"):
		snapshot["target_id"] = target.get_instance_id()

	net_last_snapshot = snapshot

	emit_signal("sync_snapshot_ready", snapshot)

func apply_sync_snapshot(snapshot: Dictionary) -> void:

	if snapshot.has("pos"):
		global_position = snapshot["pos"]

	if snapshot.has("vel"):
		velocity = snapshot["vel"]

	if snapshot.has("hp"):
		health = snapshot["hp"]

	if snapshot.has("phase"):
		phase_current = snapshot["phase"]

	if snapshot.has("ai_mode"):
		ai_mode = snapshot["ai_mode"] as AIMode

	if snapshot.has("boss_phase"):
		boss_phase = snapshot["boss_phase"]

	if snapshot.has("enraged"):
		boss_enraged = snapshot["enraged"]

func get_sync_snapshot() -> Dictionary:

	return net_last_snapshot

# ============================================================
# PUBLIC API (ORIGINAL, ALL RETAINED)
# ============================================================

func set_lane(
	points: Array,
	lane_id: int = -1
) -> void:

	lane_waypoints.clear()

	for p in points:
		lane_waypoints.append(Vector3(p))

	current_waypoint = 0

	# Only reset to lane push if no command is active
	if squad_order == SquadOrder.NONE:
		ai_mode = AIMode.LANE_PUSH

func set_ai_mode(mode: int) -> void:

	ai_mode = mode

func set_target(t: Node3D) -> void:

	target = t

func push_neighbors(arr: Array) -> void:

	neighbors_cache = arr

func set_lod(level: int) -> void:

	match level:

		0:
			lod = LOD.FULL
			set_physics_process(true)

		1:
			lod = LOD.CHEAP
			set_physics_process(true)

		2:
			lod = LOD.SLEEP
			set_physics_process(false)

func set_mesh_near(near: bool) -> void:
	if _mesh_near == near: return
	_mesh_near = near
	var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in _body_meshes:
		if is_instance_valid(m): m.cast_shadow = shadow

func reset(pos: Vector3) -> void:

	global_position = pos

	health = max_health

	is_dead = false

	target = null
	target_type = ""

	velocity = Vector3.ZERO

	stuck_timer = 0.0

	last_position = pos

	energized_timer = 0.0

	# ---- AAA state reset ----------------------------------

	phase_current = 0
	phase_transitioning = false
	phase_transition_timer = 0.0

	status_effects.clear()

	is_stunned = false
	is_frozen = false
	current_slow = 0.0

	boss_phase = 0
	boss_enraged = false

	for i in boss_phase_triggered.size():
		boss_phase_triggered[i] = false

	enrage_damage_mult = 1.0
	enrage_speed_mult = 1.0

	if elite_ability == EliteAbility.SHIELD_BURST:
		shield_hp = shield_max
		shield_active = true

	elite_ability_timer = elite_ability_cooldown

	swarm_pheromone_active = false

	set_physics_process(true)

func apply_upgrade(
	stat: String,
	amount: float
) -> void:

	match stat:

		"max_health":
			max_health += amount
			health += amount

		"damage":
			damage += amount

		"move_speed":
			move_speed += amount

		"attack_cooldown":
			attack_cooldown = maxf(0.2, attack_cooldown - amount)

		# ---- AAA: Extended upgrade stats ------------------

		"armor_physical":
			armor_physical += amount

		"armor_magic":
			armor_magic += amount

		"armor_fire":
			armor_fire += amount

		"life_steal":
			life_steal_pct = clampf(life_steal_pct + amount, 0.0, 0.5)

		"shield_max":
			shield_max += amount
			if shield_active:
				shield_hp += amount

		"aggro_range":
			aggro_range += amount

		"swarm_strength":
			swarm_pheromone_strength += amount

# ============================================================
# AAA: PUBLIC STATUS API
# ============================================================

func clear_status(type: int) -> void:

	if status_effects.has(type):
		_expire_status(type)
		status_effects.erase(type)

func has_status(type: int) -> bool:

	return status_effects.has(type)

func get_status_timer(type: int) -> float:

	if status_effects.has(type):
		return status_effects[type].get("timer", 0.0)

	return 0.0

# ============================================================
# AAA: PUBLIC TIER API
# ============================================================

func set_tier(tier: int) -> void:

	zombie_tier = tier as ZombieTier

	match zombie_tier:

		ZombieTier.ELITE:
			is_elite = true
			gold_reward = int(gold_reward * 2.5)
			max_health *= 1.8
			health = max_health
			damage *= 1.5

		ZombieTier.BOSS:
			is_boss = true
			gold_reward = int(gold_reward * 6.0)
			max_health *= 4.0
			health = max_health
			damage *= 2.2
			armor_physical = 20.0
			armor_magic = 15.0

		ZombieTier.PHASE:
			is_phase_zombie = true
			gold_reward = int(gold_reward * 3.5)
			max_health *= 2.2
			health = max_health
			_init_phase_system()
func _clear_unreachable_target() -> void:
	# Blacklist this target for 4s so we don't immediately re-chase
	if is_instance_valid(target):
		_unreachable_blacklist[target.get_instance_id()] = 4.0
	unreachable_timer = 0.0
	target_progress_timer = 0.0
	last_target_distance = INF
	target = null
	target_type = ""
	ai_mode = AIMode.LANE_PUSH
func _can_reach_position(pos: Vector3) -> bool:

	var nav_map : RID = get_world_3d().navigation_map

	# invalid nav map
	if nav_map == RID():
		return true

	var path := NavigationServer3D.map_get_path(
		nav_map,
		global_position,
		pos,
		true
	)

	# no valid path
	if path.size() <= 1:
		return false

	var total_distance := 0.0

	for i in range(path.size() - 1):
		total_distance += path[i].distance_to(path[i + 1])

	var direct_distance := global_position.distance_to(pos)

	# unreachable / extremely inefficient path
	if total_distance > direct_distance * 3.0:
		return false

	return true
# ============================================================
# SIGNALS
# ============================================================

signal zombie_died(zombie)
signal phase_started(phase_index)
signal phase_completed(phase_index)
signal boss_phase_started(phase_index)

signal sync_snapshot_ready(snapshot)
