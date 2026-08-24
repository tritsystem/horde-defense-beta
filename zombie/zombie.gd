# ============================================================
# ⚠ NOT LIVE — NOT ATTACHED TO ANY SCENE (2026-07-25) ⚠
# zombie.tscn's script is res://assets/weapons/resources/Player/zombie.gd,
# NOT this file. This BaseZombie class only still matters because ~20 files
# under "assets/zombies/scripts for creeps/" extend it — none of THOSE are
# wired into any live scene or reachable from CreepDeckManager either
# (their referenced .tscn paths don't exist). Editing this file has ZERO
# effect on actual gameplay. If you're trying to change zombie behavior,
# edit assets/weapons/resources/Player/zombie.gd instead. This file (and its
# AIMode enum, which is ordered DIFFERENTLY than the live script's) is kept
# only because it has real uncommitted work in progress — do not delete
# without checking with the user first.
# ============================================================
# zombie.gd — Optimized BaseZombie
# ============================================================
# PERFORMANCE DESIGN:
#   • 4-tier LOD — full AI only within 25m of camera
#   • NO per-frame get_nodes_in_group() calls — neighbors
#     are pushed by ZombieHordeManager spatial hash
#   • NavigationAgent3D is SHARED (one per LOD0 zombie,
#     disabled above LOD0)
#   • Awareness raycasts throttled to 100ms intervals
#   • All timers packed into one _process block
#   • Object pool compatible — reset() fully reinitialises
#   • Animation blend updated only when speed changes
# ============================================================
extends CharacterBody3D
class_name BaseZombie

# ── AI MODE ─────────────────────────────────────────────────
enum AIMode { FOLLOW_OWNER, ATTACK, DEFEND, PATROL, STAY, LANE_PUSH }

# ── LOD ──────────────────────────────────────────────────────
# LOD0 = full AI + nav agent + audio
# LOD1 = simplified steering, no audio
# LOD2 = direct position move, no physics queries
# LOD3 = sleeping, zero cost
enum LOD { FULL, MOVE_ONLY, POSITION_ONLY, SLEEPING }

# ── TUNING CONSTANTS ─────────────────────────────────────────
# All per-frame behaviour knobs live here — change a number once,
# it propagates to every function that references the constant.
const NAV_REFRESH_RATE    : float = 0.25  # seconds between nav-path recalcs (LOD0 only)
const CHIP_DAMAGE_PCT     : float = 0.47  # damage fraction vs units without player aura (~7/15)
const SEP_RADIUS          : float = 2.2   # radius at which zombies push each other apart
const SEP_FORCE           : float = 18.0  # separation push strength
const SEP_MAX_FORCE       : float = 10.0  # per-frame cap on combined separation force
const LOD1_SPEED_MULT     : float = 0.85  # speed fraction at LOD1 (simplified steering)
const LOD2_SPEED_MULT     : float = 0.60  # speed fraction at LOD2 (position-only movement)
const COMBAT_DECEL_RATE   : float = 0.60  # move_toward braking rate when inside attack range
const STRUCT_ATTACK_RANGE : float = 5.5   # effective melee range vs turrets / bases
const TARGET_LOCK_SECS    : float = 3.0   # seconds a spotted or chased target is held
const HIT_AGGRO_SECS      : float = 2.5   # target-lock duration granted on taking damage
const UNSTUCK_SIDE_VEL    : float = 6.0   # sideways velocity component in stuck-recovery push
const UNSTUCK_FWD_VEL     : float = 4.0   # forward velocity component in stuck-recovery push
const UNSTUCK_JUMP_MULT   : float = 0.60  # jump_height fraction used for stuck-recovery jump
const AGGRO_BURST_MULT    : float = 8.00  # velocity lerp alpha when surging onto a spotted target
const CAUTION_DAMP_MULT   : float = 0.50  # speed fraction in cautious STAY (hold-position) mode
const BLOCKER_RANGE       : float = 6.00  # extra detection radius beyond detection_range for lane-blocking structures
const KNOCKBACK_DURATION  : float = 0.10  # seconds to brake from full speed at melee commit (braking step = move_speed / KNOCKBACK_DURATION)

# ── IDENTITY ─────────────────────────────────────────────────
var team_id      : int    = 1
var owner_id     : int    = -1
var owner_player : Node3D = null
var enemy_base   : Node3D = null
var friendly_base: Node3D = null

# ── LANE (MOBA push system) ───────────────────────────────────
var _lane_id          : int          = -1
var _wp_stuck_timer   : float         = 0.0   # skip waypoint if stuck too long
var _spawn_immunity   : float         = 3.0   # can't attack for N seconds after spawn
var lane_waypoints    : Array[Vector3] = []
var _current_wp_index : int          = 0
var _lane_width       : float        = 12.0

# ── STATS ────────────────────────────────────────────────────
@export var max_health      : float = 350.0  # 7 headshots at 25dmg×2 to kill
@export var move_speed      : float = 4.0
@export var attack_range    : float = 1.8  # CharacterBody3D stops at nav desired_distance
@export var damage          : float = 15.0  # base attack damage
@export var attack_cooldown : float = 0.9  # faster attacks = more turret pressure
@export var detection_range : float = 14.0
@export var aggro_range     : float = 8.0
@export var gold_reward     : int   = 25
@export var crystal_drop_chance : float = 0.35  # 35% chance to drop a crystal on death
@export var crystal_min : int = 1
@export var crystal_max : int = 2
@export var gravity         : float = 20.0
@export var jump_height     : float = 0.8
@export var jump_cooldown   : float = 2.5
@export var stuck_threshold : float = 0.35
@export var stuck_time      : float = 1.5

# ── AUDIO ────────────────────────────────────────────────────
@export_group("Audio")
@export var audio_enabled     : bool  = true
@export var attack_sounds     : Array[AudioStream] = []
@export var death_sounds      : Array[AudioStream] = []
@export var footstep_sounds   : Array[AudioStream] = []
@export var idle_sounds       : Array[AudioStream] = []
@export var hurt_sounds       : Array[AudioStream] = []
@export var footstep_interval : float = 0.5
@export var idle_interval_min : float = 5.0
@export var idle_interval_max : float = 14.0

# ── AI STATE ─────────────────────────────────────────────────
var health         : float
var ai_mode        : AIMode   = AIMode.LANE_PUSH
var target         : Node3D   = null
var _target_lock   : float    = 0.0
var move_target    : Vector3  = Vector3.ZERO
var has_move_target: bool     = false
var patrol_points  : Array[Vector3] = []
var _patrol_index  : int      = 0
var _patrol_dir    : int      = 1

# ── LOD ──────────────────────────────────────────────────────
var lod            : LOD      = LOD.FULL
var _lod_int       : int      = 0   # mirrors lod as int for manager

# ── NAVIGATION ───────────────────────────────────────────────
# NavigationAgent only active at LOD0 — disabled at higher LODs
var _nav_agent     : NavigationAgent3D = null
var _nav_target_pos: Vector3  = Vector3.ZERO
var _nav_refresh   : float    = 0.0

# ── NEIGHBORS (pushed by ZombieHordeManager, not scanned) ───
# ZombieHordeManager writes to this array every grid rebuild.
# Zero per-frame group scans on this zombie's end.
var _neighbors_cache  : Array = []
var _neighbors_dirty  : bool  = false

# ── TIMERS (all packed, updated once per frame) ──────────────
var _attack_timer     : float = 0.0
var _jump_cd          : float = 0.0
var _stuck_timer      : float = 0.0
var _retarget_timer   : float = 0.0
var _los_timer        : float = 0.0
var _footstep_timer   : float = 0.0
var _idle_timer       : float = 0.0
var _last_pos_timer   : float = 0.0
var _last_pos         : Vector3
var _smooth_speed_mult: float = 1.0
# Exposed for CreepOverlay: counts down from 3.0 after each hit
var hud_hp_visible_timer : float = 0.0

# ── CACHED BLEND ─────────────────────────────────────────────
var _last_blend_val   : float = -1.0   # only write anim when changed

# ── DEAD ─────────────────────────────────────────────────────
var _is_dead          : bool  = false

# Energy aura — set by PlayerEnergyAura.gd each pulse
var energized_timer   : float = 0.0

# ── REFS ─────────────────────────────────────────────────────
var _sfx       : AudioStreamPlayer3D = null
var _anim_tree : AnimationTree       = null
var _horde_mgr                       = null   # set by ZombieHordeManager


# ============================================================
# READY — minimal work, pool-safe
# ============================================================
func _ready() -> void:
	health      = max_health
	_last_pos   = global_position
	_idle_timer = randf_range(idle_interval_min, idle_interval_max)

	add_to_group("units")
	add_to_group("zombies")

	_sfx              = AudioStreamPlayer3D.new()
	_sfx.max_distance = 28.0
	_sfx.bus          = "Master"
	add_child(_sfx)

	_anim_tree = _find_anim_tree()
	if _anim_tree: _anim_tree.active = true

	# NavigationAgent — created once, disabled until LOD0
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.path_desired_distance   = 0.5
	_nav_agent.target_desired_distance = 0.5  # stop very close; attack range handles the rest
	_nav_agent.path_max_distance       = 3.0
	_nav_agent.avoidance_enabled       = false   # avoidance done manually
	add_child(_nav_agent)

	call_deferred("_deferred_init")


func _deferred_init() -> void:
	_find_bases()
	call_deferred("_snap_to_ground")
	# Force LOD0 briefly so NavigationAgent gets an initial target set
	# Without this, zombies far from player stay at LOD2 and never navigate
	set_lod(0)
	set_physics_process(true)
	await get_tree().create_timer(0.5).timeout
	# Let ZHM take over LOD after initial navigation is established
	if is_instance_valid(self) and is_inside_tree():
		_tick_ai_mode(get_physics_process_delta_time())


func _find_anim_tree() -> AnimationTree:
	var t := get_node_or_null("AnimationTree") as AnimationTree
	if t: return t
	for c in get_children():
		if c is AnimationTree: return c
	return null


func _find_bases() -> void:
	# If spawner already set both bases correctly, don't overwrite
	if is_instance_valid(enemy_base) and is_instance_valid(friendly_base) \
			and enemy_base != friendly_base:
		# Ensure enemy base is in units group for targeting
		if not enemy_base.is_in_group("units"):
			enemy_base.add_to_group("units")
		return
	# Only fill in whatever is missing — never wipe a pre-set valid reference
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == team_id:
			if not is_instance_valid(friendly_base): friendly_base = b as Node3D
		else:
			if not is_instance_valid(enemy_base):   enemy_base    = b as Node3D
	if not is_instance_valid(enemy_base):
		enemy_base = get_tree().get_first_node_in_group("enemy_base") as Node3D
	# Safety: never attack own base
	if is_instance_valid(enemy_base) and enemy_base == friendly_base:
		push_error("[Zombie] team%d: enemy_base == friendly_base!" % team_id)
		enemy_base = null
	if is_instance_valid(enemy_base) and not enemy_base.is_in_group("units"):
		enemy_base.add_to_group("units")
	print("[Zombie:%s] _find_bases | team=%d | enemy=%s | friendly=%s" % [
		name, team_id,
		enemy_base.name if is_instance_valid(enemy_base) else "NULL",
		friendly_base.name if is_instance_valid(friendly_base) else "NULL"])


func _snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	if not space: return
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0,5,0), global_position + Vector3(0,-20,0))
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	if not hit.is_empty(): global_position.y = hit["position"].y + 0.1


# ============================================================
# LOD CONTROL — called by ZombieHordeManager
# ============================================================
func set_lod(new_lod: int) -> void:
	_lod_int = new_lod
	lod      = new_lod as LOD

	match new_lod:
		0:  # FULL — enable nav agent, audio
			_nav_agent.process_mode = Node.PROCESS_MODE_INHERIT
			if is_instance_valid(_sfx): _sfx.max_distance = 28.0
			set_physics_process(true)
		1:  # MOVE_ONLY — disable nav agent
			_nav_agent.process_mode = Node.PROCESS_MODE_DISABLED
			if is_instance_valid(_sfx): _sfx.max_distance = 0.0
			set_physics_process(true)
		2:  # POSITION_ONLY — cheap movement only, no nav agent, no AI
			_nav_agent.process_mode = Node.PROCESS_MODE_DISABLED
			if is_instance_valid(_sfx): _sfx.max_distance = 0.0
			set_physics_process(true)   # zombie drives itself — no ZHM needed
		3:  # SLEEPING
			_nav_agent.process_mode = Node.PROCESS_MODE_DISABLED
			set_physics_process(false)

func get_lod() -> int: return _lod_int


# ============================================================
# POOL RESET — called by ZombieHordeManager.spawn_*
# ============================================================
func reset(pos: Vector3) -> void:
	_horde_mgr        = null   # ZHM sets this via _horde_mgr property after calling reset()
	_is_dead          = false
	health            = max_health
	target            = null
	_target_lock      = 0.0
	has_move_target   = false
	_stuck_timer      = 0.0
	_retarget_timer   = 0.0
	velocity          = Vector3.ZERO
	_smooth_speed_mult = 1.0
	_last_blend_val      = -1.0
	hud_hp_visible_timer = 0.0
	_neighbors_cache.clear()
	_patrol_index     = 0
	_patrol_dir       = 1
	lane_waypoints.clear()
	_current_wp_index = 0
	_lane_id          = -1
	ai_mode           = AIMode.LANE_PUSH
	set_lod(0)
	global_position   = pos
	visible           = true
	_last_pos         = pos
	_idle_timer       = randf_range(idle_interval_min, idle_interval_max)
	_find_bases()
	call_deferred("_snap_to_ground")


func reset_position(pos: Vector3) -> void:
	global_position = pos
	_last_pos       = pos


# ============================================================
# PHYSICS PROCESS — gated hard by LOD
# ============================================================
func _physics_process(delta: float) -> void:
	if _is_dead: return

	# Gravity
	if not is_on_floor(): velocity.y -= gravity * delta
	elif velocity.y < 0.0: velocity.y = 0.0

	# Decrement timers once
	_attack_timer        = maxf(0.0, _attack_timer        - delta)
	_jump_cd             = maxf(0.0, _jump_cd             - delta)
	_target_lock         = maxf(0.0, _target_lock         - delta)
	_nav_refresh         = maxf(0.0, _nav_refresh         - delta)
	energized_timer      = maxf(0.0, energized_timer      - delta)
	hud_hp_visible_timer = maxf(0.0, hud_hp_visible_timer - delta)
	if _target_lock <= 0.0: target = null

	# ── Separation runs EVERY frame at all LODs ─────────────────
	# This prevents stacking even when zombies are stopped or attacking.
	# Uses physics overlap query — guaranteed accurate, not cache-dependent.
	_apply_separation_impulse()

	match lod:
		LOD.FULL:
			_tick_full(delta)
		LOD.MOVE_ONLY:
			_tick_move_only(delta)
		LOD.POSITION_ONLY:
			_tick_lod2_cheap(delta)

	_update_stuck(delta)
	_update_anim_blend()
	move_and_slide()


# ── LOD0 — full AI + NavigationAgent ─────────────────────────
func _tick_full(delta: float) -> void:
	if _spawn_immunity > 0.0: _spawn_immunity -= get_physics_process_delta_time()

	# ── MOBA LANE PUSH ───────────────────────────────────────────
	# Lane minions own their whole behaviour in _tick_lane_push:
	#   target priority (turrets → enemy units in aggro → base) AND
	#   waypoint advancement, all via direct steering (no NavMesh needed).
	# Do NOT run _retarget_from_cache here — it would set `target` and divert
	# the minion into nav-agent movement, which freezes with no baked NavMesh.
	if ai_mode == AIMode.LANE_PUSH:
		_tick_lane_push(delta)
		_tick_audio(delta)
		return

	# Retarget from neighbors cache (O(k) not O(n))
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = randf_range(0.3, 0.7)
		_retarget_from_cache()

	if is_instance_valid(target):
		_move_toward_target_full(delta)
	elif has_move_target:
		_move_to_point_full(move_target, delta)
		if global_position.distance_to(move_target) < 1.5:
			has_move_target = false
	else:
		_tick_ai_mode(delta)

	# Audio only at LOD0
	_tick_audio(delta)


# ── LOD1 — simplified steering, no nav agent, no audio ───────
func _tick_move_only(delta: float) -> void:
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = randf_range(0.5, 1.0)
		_retarget_from_cache()

	var dest : Vector3
	if is_instance_valid(target):
		dest = target.global_position
	elif has_move_target:
		dest = move_target
		if global_position.distance_to(dest) < 1.5: has_move_target = false
	elif is_instance_valid(enemy_base):
		dest = enemy_base.global_position
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8)
		return

	_steer_toward(dest, delta, move_speed * LOD1_SPEED_MULT)


# ── LOD2 — cheapest possible movement, no AI, no retarget ────
# Zombie drives itself — ZombieHordeManager is NOT involved in movement.
func _tick_lod2_cheap(delta: float) -> void:
	# Pick destination once and march straight there
	var dest : Vector3
	if has_move_target:
		dest = move_target
		if global_position.distance_to(dest) < 2.0: has_move_target = false; return
	elif is_instance_valid(enemy_base) and enemy_base != friendly_base:
		dest = enemy_base.global_position
	else:
		velocity.x = 0.0; velocity.z = 0.0; return

	var dir := (dest - global_position)
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		velocity.x = 0.0; velocity.z = 0.0; return
	dir = dir.normalized()
	var spd := move_speed * LOD2_SPEED_MULT
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd


# ── Retarget: cache first, then fallback to scene tree ─────────
func _retarget_from_cache() -> void:
	var best   : Node3D = null
	var best_d : float  = detection_range

	# 1. Check neighbor cache (fast)
	for n in _neighbors_cache:
		if not is_instance_valid(n): continue
		if n == friendly_base: continue              # never target own base
		if not ("team_id" in n): continue
		if int(n.team_id) == team_id: continue       # skip friendlies
		var d : float = global_position.distance_to((n as Node3D).global_position)
		if d < best_d: best_d = d; best = n as Node3D

	# 2. Player scan — always runs, ungated (players never in neighbor cache)
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p) or not (p is Node3D): continue
		if not ("team_id" in p) or int(p.get("team_id")) == team_id: continue
		if "is_dead" in p and p.get("is_dead"): continue
		var d : float = global_position.distance_to((p as Node3D).global_position)
		if d < best_d: best_d = d; best = p as Node3D

	# 3. Units group scan — gated by ai_mode to avoid every-frame cost
	if not is_instance_valid(best) and ai_mode == AIMode.ATTACK:
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or u == self: continue
			if u == friendly_base or u == enemy_base: continue
			if not ("team_id" in u): continue
			if int(u.team_id) == team_id: continue
			var d : float = global_position.distance_to((u as Node3D).global_position)
			if d < best_d: best_d = d; best = u as Node3D

	# 4. Enemy base as last resort
	if not is_instance_valid(best) and is_instance_valid(enemy_base) \
			and enemy_base != friendly_base:
		best = enemy_base

	if is_instance_valid(best):
		target       = best
		_target_lock = TARGET_LOCK_SECS


# ── Full nav-agent movement ───────────────────────────────────
func _move_toward_target_full(delta: float) -> void:
	if not is_instance_valid(target):
		target = null; return
	var dist := global_position.distance_to(target.global_position)
	if dist <= attack_range:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta / KNOCKBACK_DURATION)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta / KNOCKBACK_DURATION)
		_try_attack(target)
		return
	# When nav path is finished but target not in range, force path refresh.
	# Do NOT direct-steer here — it causes circular orbit around the target.
	if _nav_agent.is_navigation_finished():
		_nav_refresh = 0.0   # triggers path recalculation next frame
	_move_to_point_full(target.global_position, delta)


func _move_to_point_full(pos: Vector3, delta: float) -> void:
	# Always update if target is origin (uninitialized) or position changed
	var force := _nav_target_pos == Vector3.ZERO or pos.distance_to(_nav_target_pos) > 0.8
	if _nav_refresh <= 0.0 or force:
		_nav_agent.target_position = pos
		_nav_target_pos = pos
		_nav_refresh    = NAV_REFRESH_RATE

	# When the NavAgent has no path (no/partial NavMesh over the play area),
	# is_navigation_finished() returns true immediately. Direct-steer instead
	# of returning — otherwise the zombie freezes in place forever.
	if _nav_agent.is_navigation_finished():
		_steer_toward(pos, delta, move_speed)
		return

	var next := _nav_agent.get_next_path_position()
	var dir  := (next - global_position)
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		_steer_toward(pos, delta, move_speed)
		return
	dir = dir.normalized()

	# Separation from neighbor cache (cheap — no group scan)
	var sep := _calc_separation()
	var final_dir := (dir + sep * 0.4).normalized()

	_smooth_speed_mult = lerpf(_smooth_speed_mult, 1.0, delta * AGGRO_BURST_MULT)
	velocity.x = lerp(velocity.x, final_dir.x * move_speed * _smooth_speed_mult, delta * AGGRO_BURST_MULT)
	velocity.z = lerp(velocity.z, final_dir.z * move_speed * _smooth_speed_mult, delta * AGGRO_BURST_MULT)
	rotation.y = lerp_angle(rotation.y, atan2(final_dir.x, final_dir.z), 0.15)


func _move_to(pos: Vector3, delta: float) -> void:
	# For LANE_PUSH: use direct steering — waypoints define the path already.
	# NavAgent fails when spawn/target positions are outside the baked NavMesh,
	# which is the case here (bases at X=133 and X=0 are outside coverage).
	if ai_mode == AIMode.LANE_PUSH:
		_steer_toward(pos, delta, move_speed)
	else:
		_move_to_point_full(pos, delta)


func _tick_lane_push(delta: float) -> void:
	# ── MOBA priority: turrets/structures → enemy units → base ──
	var tgt := _find_lane_target()
	if is_instance_valid(tgt):
		var d := global_position.distance_to(tgt.global_position)
		var _is_struct : bool = tgt.is_in_group("bases") or tgt.is_in_group("turrets")
		var _eff : float = STRUCT_ATTACK_RANGE if _is_struct else attack_range
		if d <= _eff:
			var dir := tgt.global_position - global_position
			dir.y = 0.0
			if dir.length_squared() > 0.01:
				rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.85)  # snap to face target
			_try_attack(tgt)
			# Decelerate smoothly — avoids snap and jitter
			velocity.x = move_toward(velocity.x, 0.0, move_speed * COMBAT_DECEL_RATE)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * COMBAT_DECEL_RATE)
		else:
			# Face target while moving toward it
			var face_dir := tgt.global_position - global_position
			face_dir.y = 0.0
			if face_dir.length_squared() > 0.01:
				rotation.y = lerp_angle(rotation.y, atan2(face_dir.x, face_dir.z), 0.35)
			_move_to(tgt.global_position, delta)
		return

	# No target in range — advance along lane waypoints
	if not lane_waypoints.is_empty():
		var wp := lane_waypoints[_current_wp_index]
		var dist_to_wp := global_position.distance_to(wp)
		if dist_to_wp < 2.5:
			_current_wp_index = mini(_current_wp_index + 1, lane_waypoints.size() - 1)
			_wp_stuck_timer   = 0.0
			wp = lane_waypoints[_current_wp_index]
		else:
			# Stuck detection: if nav agent finishes but we're not near waypoint,
			# the NavMesh has a gap. Skip to next waypoint after timeout.
			if _nav_agent.is_navigation_finished() and dist_to_wp > 2.5:
				_wp_stuck_timer += delta
				if _wp_stuck_timer > 3.0:
					print("[Zombie:%s] waypoint %d unreachable (NavMesh gap?) — skipping" % [name, _current_wp_index])
					_current_wp_index = mini(_current_wp_index + 1, lane_waypoints.size() - 1)
					_wp_stuck_timer   = 0.0
					# Direct steer past the gap
					_steer_toward(lane_waypoints[_current_wp_index], delta, move_speed)
					return
			else:
				_wp_stuck_timer = 0.0
		# Face the waypoint while advancing
		var wp_dir := wp - global_position
		wp_dir.y = 0.0
		if wp_dir.length_squared() > 0.01:
			rotation.y = lerp_angle(rotation.y, atan2(wp_dir.x, wp_dir.z), 0.08)
		_move_to(wp, delta)
		return

	# No waypoints — march straight to enemy base using direct steering
	if lane_waypoints.is_empty():
		push_warning("[Zombie:%s] no lane_waypoints" % name)
	if not is_instance_valid(enemy_base) or enemy_base == friendly_base:
		_find_bases()  # retry — base may not have been in group at spawn time
	if is_instance_valid(enemy_base) and enemy_base != friendly_base:
		_steer_toward(enemy_base.global_position, delta, move_speed)
	else:
		# Still no base found — wander forward so we don't idle
		var fwd2 := -global_transform.basis.z
		velocity.x = fwd2.x * move_speed * 0.5
		velocity.z = fwd2.z * move_speed * 0.5


# MOBA target priority:
#   1. Enemy turrets/structures blocking the lane   (closest, in lane)
#   2. Enemy units in aggro range                   (closest)
#   3. Enemy base                                   (always valid fallback)
func _find_lane_target() -> Node3D:
	var best_turret : Node3D = null
	var best_unit   : Node3D = null
	var turret_d    : float  = detection_range + BLOCKER_RANGE   # structures visible beyond normal detection
	var unit_d      : float  = aggro_range

	# ── Priority 1: structures/turrets ───────────────────────────
	# Check scene group first — turrets may not be in neighbors cache
	for s in get_tree().get_nodes_in_group("turrets"):
		if not is_instance_valid(s) or not ("team_id" in s): continue
		if int(s.get("team_id")) == team_id: continue
		var d := global_position.distance_to((s as Node3D).global_position)
		if d < turret_d and _is_ahead_of_me(s as Node3D):
			turret_d = d; best_turret = s as Node3D

	for s in get_tree().get_nodes_in_group("structures"):
		if not is_instance_valid(s) or not ("team_id" in s): continue
		if int(s.get("team_id")) == team_id: continue
		var d := global_position.distance_to((s as Node3D).global_position)
		if d < turret_d and _is_ahead_of_me(s as Node3D):
			turret_d = d; best_turret = s as Node3D

	if is_instance_valid(best_turret): return best_turret

	# ── Priority 2: enemy units in aggro range ────────────────────
	# Use neighbors cache first (fast), fall back to full scan
	for n in _neighbors_cache:
		if not is_instance_valid(n) or not ("team_id" in n): continue
		if int(n.get("team_id")) == team_id: continue
		if n == enemy_base: continue  # base is priority 3
		var d := global_position.distance_to((n as Node3D).global_position)
		if d < unit_d: unit_d = d; best_unit = n as Node3D

	if not is_instance_valid(best_unit):
		# Full scan fallback — fires when cache is sparse
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or u == self: continue
			if not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			if u == enemy_base: continue
			var d := global_position.distance_to((u as Node3D).global_position)
			if d < unit_d: unit_d = d; best_unit = u as Node3D
		for u in get_tree().get_nodes_in_group("player"):
			if not is_instance_valid(u): continue
			if not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			var d := global_position.distance_to((u as Node3D).global_position)
			if d < unit_d: unit_d = d; best_unit = u as Node3D

	if is_instance_valid(best_unit): return best_unit

	# ── Priority 3: enemy base ────────────────────────────────────
	# Always target base once past second-to-last waypoint, regardless of distance.
	# Base nodes are often offset from lane endpoints so distance gates fail.
	if is_instance_valid(enemy_base) and enemy_base != friendly_base:
		var at_end : bool = lane_waypoints.is_empty() or 			_current_wp_index >= lane_waypoints.size() - 2
		if at_end: return enemy_base

	return null


# True if the target is generally in the direction we're heading (toward enemy base)
func _is_ahead_of_me(node: Node3D) -> bool:
	if not is_instance_valid(enemy_base): return true
	# Target is "ahead" if it's closer to enemy base than we are
	var my_dist     := global_position.distance_to(enemy_base.global_position)
	var target_dist := node.global_position.distance_to(enemy_base.global_position)
	return target_dist < my_dist + detection_range


func _tick_stay() -> void:
	velocity.x = move_toward(velocity.x, 0.0, move_speed * CAUTION_DAMP_MULT)
	velocity.z = move_toward(velocity.z, 0.0, move_speed * CAUTION_DAMP_MULT)
	var near := _scan_for_enemy()
	if is_instance_valid(near):
		var dist := global_position.distance_to(near.global_position)
		var dir  := near.global_position - global_position
		dir.y = 0.0
		if dir.length_squared() > 0.01:
			rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.2)
		if dist <= attack_range:
			_try_attack(near)


func _steer_toward(dest: Vector3, delta: float, speed: float) -> void:
	var dir := dest - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.01: return
	dir = dir.normalized()
	var sep := _calc_separation()
	var final_dir := (dir + sep * 0.3).normalized()
	velocity.x = lerp(velocity.x, final_dir.x * speed, 0.15)
	velocity.z = lerp(velocity.z, final_dir.z * speed, 0.15)
	rotation.y = lerp_angle(rotation.y, atan2(final_dir.x, final_dir.z), 0.30)


# Called every frame — pushes apart zombies that are too close.
# Uses neighbor cache (pushed by ZombieHordeManager) — NO physics
# queries so no re-entrant callbacks and no stack overflow.
func _apply_separation_impulse() -> void:
	var force := Vector3.ZERO

	# Cache-based separation (safe inside _physics_process)
	for n in _neighbors_cache:
		if not is_instance_valid(n) or n == self: continue
		var diff := global_position - (n as Node3D).global_position
		diff.y = 0.0
		var d := diff.length()
		if d < 0.01:
			# Exactly stacked — scatter randomly
			diff = Vector3(randf_range(-1,1), 0.0, randf_range(-1,1))
			d    = diff.length()
			if d < 0.01: diff = Vector3(1,0,0); d = 1.0
		if d < SEP_RADIUS:
			force += diff.normalized() * (1.0 - d / SEP_RADIUS) * SEP_FORCE

	if force.length() > SEP_MAX_FORCE:
		force = force.normalized() * SEP_MAX_FORCE

	velocity.x += force.x
	velocity.z += force.z


func _calc_separation() -> Vector3:
	return Vector3.ZERO   # separation handled by _apply_separation_impulse


# ── AI modes (only active when no explicit target/move_target) ─
func _tick_ai_mode(delta: float) -> void:
	match ai_mode:
		AIMode.LANE_PUSH:    _tick_lane_push(delta)
		AIMode.ATTACK:       _tick_attack(delta)
		AIMode.DEFEND:       _tick_defend(delta)
		AIMode.PATROL:       _tick_patrol(delta)
		AIMode.STAY:         _tick_stay()
		AIMode.FOLLOW_OWNER: _tick_follow(delta)


func _tick_attack(delta: float) -> void:
	# Try to find any enemy target in scene
	var scan_target := _scan_for_enemy()
	if is_instance_valid(scan_target):
		target       = scan_target
		_target_lock = TARGET_LOCK_SECS
		_move_toward_target_full(delta)
		return
	# Fall back to marching toward enemy base — never friendly base
	if is_instance_valid(enemy_base) and enemy_base != friendly_base:
		_move_to_point_full(enemy_base.global_position, delta)
	else:
		velocity.x = 0.0; velocity.z = 0.0

func _scan_for_enemy() -> Node3D:
	var best   : Node3D = null
	var best_d : float  = detection_range

	# Check neighbors cache first (fast path)
	for n in _neighbors_cache:
		if not is_instance_valid(n) or n == self: continue
		if not ("team_id" in n): continue
		if int(n.get("team_id")) == team_id: continue   # never friendly
		if n == friendly_base: continue                  # never own base
		var d := global_position.distance_to((n as Node3D).global_position)
		if d < best_d: best_d = d; best = n as Node3D

	if is_instance_valid(best): return best

	# Fallback: scene scan (sparse cache or first frame)
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u == self: continue
		if not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if u == friendly_base: continue
		var d := global_position.distance_to((u as Node3D).global_position)
		if d < best_d: best_d = d; best = u as Node3D

	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p): continue
		if not ("team_id" in p): continue
		if int(p.get("team_id")) == team_id: continue
		var d := global_position.distance_to((p as Node3D).global_position)
		if d < best_d: best_d = d; best = p as Node3D

	# Enemy base as last resort
	if is_instance_valid(enemy_base) and enemy_base != friendly_base:
		if not is_instance_valid(best):
			best = enemy_base

	return best


func _tick_defend(delta: float) -> void:
	if is_instance_valid(friendly_base):
		var d := global_position.distance_to(friendly_base.global_position)
		if d > 5.0:
			_move_to_point_full(friendly_base.global_position, delta)
		else:
			velocity.x = 0.0; velocity.z = 0.0


func _tick_follow(delta: float) -> void:
	if not is_instance_valid(owner_player):
		velocity.x = 0.0; velocity.z = 0.0; return
	var d := global_position.distance_to(owner_player.global_position)
	if d > 2.5: _move_to_point_full(owner_player.global_position, delta)
	else: velocity.x = 0.0; velocity.z = 0.0


func _tick_patrol(delta: float) -> void:
	if patrol_points.is_empty(): velocity.x = 0.0; velocity.z = 0.0; return
	var dest := patrol_points[_patrol_index]
	if global_position.distance_to(dest) < 1.2:
		_patrol_index += _patrol_dir
		if _patrol_index >= patrol_points.size():
			_patrol_index = patrol_points.size() - 2; _patrol_dir = -1
		elif _patrol_index < 0:
			_patrol_index = 1; _patrol_dir = 1
		_patrol_index = clampi(_patrol_index, 0, patrol_points.size() - 1)
	else:
		_move_to_point_full(dest, delta)


# ============================================================
# STUCK RECOVERY
# ============================================================
func _update_stuck(delta: float) -> void:
	_last_pos_timer += delta
	if _last_pos_timer < 0.5: return
	_last_pos_timer = 0.0
	var moved := Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	_last_pos = global_position
	if moved < stuck_threshold * 0.5:
		_stuck_timer += 0.5
		if _stuck_timer >= stuck_time:
			_stuck_timer = 0.0
			_unstuck()
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - 0.3)


func _unstuck() -> void:
	if not is_on_floor(): return
	# Never jump while in attack range of a target — looks unnatural
	var _near := _scan_for_enemy()
	if is_instance_valid(_near):
		var _nd := global_position.distance_to(_near.global_position)
		if _nd <= attack_range * 2.0: return  # too close — just push sideways
	# Try jump only when truly stuck far from target
	if _jump_cd <= 0.0:
		velocity.y = sqrt(2.0 * gravity * jump_height * UNSTUCK_JUMP_MULT)
		_jump_cd   = jump_cooldown
		return
	# Push sideways via velocity only — no position teleport
	var side_dir : float = 1.0 if randf() > 0.5 else -1.0
	var side := global_transform.basis.x * side_dir
	var fwd  := -global_transform.basis.z
	velocity.x = side.x * UNSTUCK_SIDE_VEL + fwd.x * UNSTUCK_FWD_VEL
	velocity.z = side.z * UNSTUCK_SIDE_VEL + fwd.z * UNSTUCK_FWD_VEL
	_nav_refresh = 0.0
	_wp_stuck_timer = 0.0


# ============================================================
# COMBAT
# ============================================================
func _try_attack(t: Node3D) -> void:
	if _spawn_immunity > 0.0: return
	if _attack_timer > 0.0 or not is_instance_valid(t): return
	# Hard friendly-fire guard
	if "team_id" in t and int(t.get("team_id")) == team_id: return
	if t == friendly_base: return

	var is_structure : bool = t.is_in_group("bases") or t.is_in_group("turrets")
	# Wider effective range for base/turret nodes whose origin may be inside mesh
	var eff_range : float = attack_range if not is_structure else maxf(attack_range, STRUCT_ATTACK_RANGE)
	var dist : float = global_position.distance_to(t.global_position)
	if dist > eff_range: return

	# LINE-OF-SIGHT: never deal damage through solid walls
	# Check BEFORE setting _attack_timer so the cooldown isn't wasted on blocked attacks
	if not _has_line_of_sight(t): return

	# Committed — start cooldown, play VFX/audio
	_attack_timer = attack_cooldown
	_play(attack_sounds, 5.0, 0.85, 1.15, "zombie_attack")
	if _anim_tree:
		_anim_tree.set("parameters/attack_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

	# Damage calculation
	var actual_dmg : float
	if is_structure or energized_timer > 0.0:
		actual_dmg = damage   # full damage on structures or when energized
	else:
		actual_dmg = damage * CHIP_DAMAGE_PCT   # chip damage vs units without player aura

	if t.has_method("take_damage"): t.take_damage(actual_dmg, self)


## Returns true when there is clear line-of-sight between this zombie and the target.
## Only tests collision layer 1 (terrain / walls) — ignores other units.
## Throttle: called only when actually attacking (not every frame).
func _has_line_of_sight(t: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	if not space: return true   # no physics world — assume clear
	var eye := global_position + Vector3(0, 0.9, 0)
	var tgt := t.global_position + Vector3(0, 0.9, 0)
	var ray := PhysicsRayQueryParameters3D.create(eye, tgt)
	ray.exclude       = [self]
	ray.collision_mask = 1   # layer 1 = terrain / static walls only
	var hit := space.intersect_ray(ray)
	# Clear if nothing hit OR if the only thing hit IS the target
	return hit.is_empty() or (hit.get("collider") == t)


func _show_health_bar() -> void:
	hud_hp_visible_timer = 3.0


func receive_energy(duration: float) -> void:
	energized_timer = maxf(energized_timer, duration)


## Dominated-zombie conversion (called by Gravemind ability).
## Switches this zombie to the given team, re-finds bases,
## and clears all targeting state so it immediately hunts enemies.
func convert_team(new_team_id: int = 1) -> void:
	team_id = new_team_id
	# Drop current target — it was our ally a moment ago
	target       = null
	_target_lock = 0.0
	has_move_target = false
	# Clear lane / waypoint state
	lane_waypoints.clear()
	_current_wp_index = 0
	_wp_stuck_timer   = 0.0
	# Force ATTACK so it immediately charges the nearest enemy
	ai_mode = AIMode.ATTACK
	# Re-discover enemy/friendly bases with the new team identity
	enemy_base    = null
	friendly_base = null
	_find_bases()
	# Fix group membership: no longer an enemy zombie
	remove_from_group("zombies")
	if not is_in_group("units"):
		add_to_group("units")
	print("[Zombie:%s] converted → team %d" % [name, new_team_id])


func take_damage(amount: float, instigator = null) -> void:
	if _is_dead: return
	# Guard: instigator may be a freed object (projectile outlived shooter)
	var safe_instigator : Object = instigator if (instigator != null and instigator is Object and is_instance_valid(instigator)) else null
	# Friendly fire — reject damage from same team
	if safe_instigator != null:
		var it : int = int(safe_instigator.get("team_id")         if "team_id"         in safe_instigator else
						   safe_instigator.get("shooter_team_id") if "shooter_team_id" in safe_instigator else -1)
		if it == team_id: return
	health -= amount
	var actual_dealt : float = amount if health >= 0.0 else amount + health
	if is_instance_valid(safe_instigator) and safe_instigator.has_method("on_damage_dealt"):
		safe_instigator.on_damage_dealt(actual_dealt)
	_play(hurt_sounds, 3.0, 0.9, 1.1)
	_show_health_bar()
	# Floating damage number
	var _ins_z = safe_instigator
	var _dtype_z : int = 0
	if is_instance_valid(_ins_z):
		if _ins_z.is_in_group("zombies") or _ins_z.is_in_group("minions"): _dtype_z = 8
		elif "enchantment" in _ins_z: _dtype_z = int(_ins_z.get("enchantment"))
	var _dn_node := get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(_dn_node) and _dn_node.has_method("spawn_number"):
		_dn_node.spawn_number(amount, global_position + Vector3(0, 2.0, 0), _dtype_z, false)
	if is_instance_valid(instigator) and instigator is Node3D:
		target       = instigator as Node3D
		_target_lock = HIT_AGGRO_SECS
	if health <= 0.0: _start_death()


# ============================================================
# ANIMATION BLEND — only write when value changes
# ============================================================
func _update_anim_blend() -> void:
	if not is_instance_valid(_anim_tree): return
	var flat : float = Vector2(velocity.x, velocity.z).length()
	var blend: float = clampf(flat / maxf(move_speed, 0.01), 0.0, 1.0)
	if blend < 0.05: blend = 0.0
	if absf(blend - _last_blend_val) < 0.02: return   # skip write if unchanged
	_last_blend_val = blend
	_anim_tree.set("parameters/move_blend/blend_position", blend)


# ============================================================
# AUDIO — LOD0 only
# ============================================================
func _tick_audio(delta: float) -> void:
	if not audio_enabled: return
	_idle_timer     -= delta
	_footstep_timer -= delta
	var moving := Vector2(velocity.x, velocity.z).length() > 0.3
	if _idle_timer <= 0.0 and not moving:
		_play_soft(idle_sounds, -2.0, 0.9, 1.1)
		_idle_timer = randf_range(idle_interval_min, idle_interval_max)
	if moving and is_on_floor() and _footstep_timer <= 0.0:
		_play_soft(footstep_sounds, -3.0, 0.8, 1.2)
		_footstep_timer = footstep_interval


func _play(arr: Array, vol: float, pmin: float, pmax: float, category: String = "") -> void:
	if not audio_enabled or arr.is_empty() or not is_instance_valid(_sfx): return
	var valid := arr.filter(func(s): return s != null)
	if valid.is_empty(): return
	if category != "":
		var am := get_node_or_null("/root/AudioManager")
		if is_instance_valid(am) and not am.claim_voice(category, _sfx):
			return
	_sfx.stream = valid[randi() % valid.size()]
	_sfx.volume_db = vol; _sfx.pitch_scale = randf_range(pmin, pmax)
	_sfx.play()


func _play_soft(arr: Array, vol: float, pmin: float, pmax: float) -> void:
	if is_instance_valid(_sfx) and _sfx.playing: return
	_play(arr, vol, pmin, pmax)


# ============================================================
# DEATH
# ============================================================
func _start_death() -> void:
	if _is_dead: return
	_is_dead = true
	velocity = Vector3.ZERO
	set_physics_process(false)
	_play(death_sounds, 8.0, 0.8, 1.2)
	var _ss := get_node_or_null("/root/ScreenShake")
	if is_instance_valid(_ss): _ss.enemy_death(max_health)
	if _anim_tree:
		_anim_tree.set("parameters/death_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	await get_tree().create_timer(1.6).timeout
	var _death_pos : Vector3 = global_position  # capture before pool return moves us
	_award_gold()
	# Drop crystals using captured position (pool return may move node)
	_drop_crystals_at(_death_pos)
	if _horde_mgr and _horde_mgr.has_method("return_to_pool"):
		_horde_mgr.return_to_pool(self)
	else:
		queue_free()


func _drop_crystals() -> void:
	_drop_crystals_at(global_position)

func _drop_crystals_at(drop_pos: Vector3) -> void:
	if randf() > crystal_drop_chance: return
	var count : int = randi_range(crystal_min, crystal_max)
	for _i in count:
		var spawn_pos : Vector3 = drop_pos + Vector3(randf_range(-0.8,0.8), 1.5, randf_range(-0.8,0.8))
		var shard : Node3D = Node3D.new()
		var script : Script = null
		for path in ["res://scripts/CrystalShard.gd","res://CrystalShard.gd",
				"res://scenes/CrystalShard.gd","res://pickups/CrystalShard.gd"]:
			if ResourceLoader.exists(path): script = load(path); break
		if is_instance_valid(script):
			shard.set_script(script)
			get_tree().current_scene.add_child(shard)
			shard.global_position = spawn_pos
		else:
			_spawn_inline_crystal(spawn_pos)


func _spawn_inline_crystal(pos: Vector3) -> void:
	# Inline crystal when CrystalShard.gd script isn't found at expected path
	var root := Node3D.new()
	get_tree().current_scene.add_child(root)
	root.global_position = pos
	# Build gem mesh
	var mi   := MeshInstance3D.new()
	var gem  := CylinderMesh.new()
	gem.top_radius = 0.0; gem.bottom_radius = 0.18; gem.height = 0.38; gem.radial_segments = 5
	mi.mesh = gem
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true; mat.emission = Color(0.55, 0.2, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(0.55, 0.2, 1.0, 0.88)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat; root.add_child(mi)
	var lt := OmniLight3D.new(); lt.light_color = Color(0.55,0.2,1.0)
	lt.light_energy = 1.2; lt.omni_range = 2.0; lt.shadow_enabled = false
	root.add_child(lt)
	# Animate + collect
	var origin_y : float = pos.y
	var t_ref    : float = 0.0
	var _collected := false
	root.set_process(true)
	# Use a lightweight script-less approach via a timer+tween combo
	var tw := root.create_tween().set_loops()
	tw.tween_property(root, "position:y", pos.y + 0.18, 0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_property(root, "position:y", pos.y,        0.45).set_trans(Tween.TRANS_SINE)
	# Attract + collect via repeated timer
	var _pick_timer := get_tree().create_timer(0.1)
	_pick_timer.timeout.connect(func(): _crystal_tick(root, origin_y, _collected))


func _crystal_tick(crystal: Node3D, _oy: float, collected: bool) -> void:
	if collected or not is_instance_valid(crystal): return
	crystal.rotation.y += 0.18
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node3D): continue
		var d : float = crystal.global_position.distance_to((p as Node3D).global_position)
		if d < 3.5:
			var pull : Vector3 = ((p as Node3D).global_position - crystal.global_position).normalized()
			crystal.global_position += pull * 9.0 * 0.1
		if d < 1.2:
			if p.has_method("add_crystal"): p.add_crystal(1)
			elif "crystals" in p: p.set("crystals", int(p.get("crystals")) + 1)
			for h in get_tree().get_nodes_in_group("hud"):
				if h.has_method("show_crystal_pickup"): h.show_crystal_pickup(); break
			crystal.queue_free(); return
	var next := get_tree().create_timer(0.1)
	next.timeout.connect(func(): _crystal_tick(crystal, _oy, false))
	# Auto-expire after 18s
	get_tree().create_timer(18.0).timeout.connect(func():
		if is_instance_valid(crystal): crystal.queue_free())



# Energy icon and health bar are drawn by CreepOverlay (single CanvasItem pass).

func _award_gold() -> void:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if not is_instance_valid(gm): return
	var receiving_team : int = 2 if team_id == 1 else 1
	gm.award_gold(receiving_team, gold_reward)
	# Notify trinket spawner for drop chance
	var ts := get_tree().get_first_node_in_group("trinket_spawner")
	if is_instance_valid(ts) and ts.has_method("on_zombie_died"):
		ts.on_zombie_died(self, receiving_team)
	# Drop crystals
	_drop_crystals()


# ============================================================
# PUBLIC API — all commands work via these
# ============================================================

## Called by ZombieHordeManager command functions
func set_ai_mode(mode: int) -> void:
	ai_mode      = mode as AIMode
	target       = null
	_target_lock = 0.0
	has_move_target = false
	_stuck_timer = 0.0
	_nav_refresh = 0.0   # force path refresh on next frame


func set_move_target(pos: Vector3) -> void:
	move_target     = pos
	has_move_target = true
	target          = null
	_target_lock    = 0.0
	_nav_refresh    = 0.0


func set_forced_target(new_target: Node3D, duration: float) -> void:
	target       = new_target
	_target_lock = duration


func set_patrol_points(points: Array) -> void:
	patrol_points.clear()
	for p in points: patrol_points.append(p as Vector3)
	_patrol_index = 0
	_patrol_dir   = 1


## Called by ZombieHordeManager every grid rebuild — zero group scan cost
func push_neighbors(neighbors: Array) -> void:
	_neighbors_cache = neighbors

## Called by ZombieHordeManager with nearby player refs (optional enhancement)
func push_players(_players: Array) -> void:
	pass   # player detection handled by ungated scan in _retarget_from_cache


func apply_upgrade(stat: String, amount: float) -> void:
	match stat:
		"max_health":
			max_health += amount
			health      = minf(health + amount, max_health)
		"damage":          damage          += amount
		"attack_cooldown": attack_cooldown  = maxf(0.3, attack_cooldown + amount)
		"move_speed":      move_speed      += amount


func set_lane(waypoints: Array, lane_id: int = -1) -> void:
	_lane_id = lane_id
	lane_waypoints.clear()
	for p in waypoints: lane_waypoints.append(Vector3(p))
	_current_wp_index = 0
	_wp_stuck_timer   = 0.0
	_lane_width = 12.0
	ai_mode = AIMode.LANE_PUSH
	target = null; _target_lock = 0.0
	# Diagnostic: confirm direction
	if lane_waypoints.size() >= 2:
		print("[Zombie:%s] lane set | team=%d | wp0=%s → wpN=%s | enemy=%s" % [
			name, team_id,
			str(lane_waypoints[0].snapped(Vector3.ONE)),
			str(lane_waypoints[-1].snapped(Vector3.ONE)),
			enemy_base.name if is_instance_valid(enemy_base) else "NULL"])

	# Skip waypoints too close to spawn so zombie doesn't idle next to own base
	while _current_wp_index < lane_waypoints.size() - 1 \
			and global_position.distance_to(lane_waypoints[_current_wp_index]) < 10.0:
		_current_wp_index += 1

	# (teleport-to-start removed — caused visible pops)


func get_lane() -> int: return _lane_id
