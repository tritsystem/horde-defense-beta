# ============================================================
# ⚠ NOT LIVE — NEVER INSTANTIATED (2026-07-25) ⚠
# Nothing in the repo calls HiveGuard.new() or loads this script. The real
# HiveCluster.gd._spawn_patrol_guards() spawns res://zombie/zombie.tscn
# (assets/weapons/resources/Player/zombie.gd) and sets its ai_mode to
# PATROL instead. This class's public API was meant to be called by
# HiveCluster but never was. Editing this file has no effect on gameplay.
# ============================================================
# HiveGuard.gd
# Simple reliable AI for hive patrol guards.
# Replaces zombie.gd on guards spawned by HiveCluster.
#
# States:
#   PATROL   — walk the patrol circle, attack anything that wanders close
#   CHASE    — player/enemy detected, chase and attack
#   AGGRO    — hive destroyed, hunt nearest enemy permanently
# ============================================================
extends CharacterBody3D
class_name HiveGuard

enum State { PATROL, CHASE, AGGRO }

# ── Identity ─────────────────────────────────────────────────
var team_id     : int   = 2

# ── Stats (set by HiveCluster before add_child) ───────────────
var max_health      : float = 300.0
var health          : float = 300.0
var move_speed      : float = 3.2
var attack_range    : float = 2.2
var detection_range : float = 30.0
var damage          : float = 18.0
var attack_cooldown : float = 1.1
var gold_reward     : int   = 20
var gravity         : float = 20.0

# ── Patrol data (set by HiveCluster) ─────────────────────────
var patrol_points : Array[Vector3] = []
var enemy_base    : Node3D = null   # player base — used in AGGRO mode

# ── Runtime state ─────────────────────────────────────────────
var _state        : State   = State.PATROL
var _target       : Node3D  = null
var _patrol_idx   : int     = 0
var _attack_timer : float   = 0.0
var _scan_timer   : float   = 0.0
var _is_dead      : bool    = false

# ── Animation ─────────────────────────────────────────────────
var _anim_tree    : AnimationTree = null
var _last_blend   : float         = -1.0


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	health = max_health
	add_to_group("units")
	add_to_group("hive_units")
	_anim_tree = _find_anim_tree()
	if _anim_tree:
		_anim_tree.active = true


func _find_anim_tree() -> AnimationTree:
	var t := get_node_or_null("AnimationTree") as AnimationTree
	if t: return t
	for c in get_children():
		if c is AnimationTree: return c as AnimationTree
	return null


# ============================================================
# PHYSICS PROCESS
# ============================================================
func _physics_process(delta: float) -> void:
	if _is_dead: return

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	_attack_timer = maxf(0.0, _attack_timer - delta)

	# Periodic target scan
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.35
		_do_scan()

	match _state:
		State.PATROL: _tick_patrol(delta)
		State.CHASE:  _tick_chase(delta)
		State.AGGRO:  _tick_aggro(delta)

	_update_anim()
	move_and_slide()


# ============================================================
# TARGET SCAN
# ============================================================
func _do_scan() -> void:
	if _state == State.AGGRO:
		# In aggro mode: always hunt the nearest enemy, no range limit
		_target = _find_nearest_enemy(99999.0)
		if not is_instance_valid(_target) and is_instance_valid(enemy_base):
			_target = enemy_base
		return

	# PATROL / CHASE: detect within detection_range
	var found := _find_nearest_enemy(detection_range)
	if is_instance_valid(found):
		_target = found
		_state  = State.CHASE
	elif _state == State.CHASE:
		# Lost target — return to patrol
		_target = null
		_state  = State.PATROL


func _find_nearest_enemy(range_limit: float) -> Node3D:
	var best   : Node3D = null
	var best_d : float  = range_limit

	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p) or not (p is Node3D): continue
		if not ("team_id" in p) or int(p.get("team_id")) == team_id: continue
		# Skip dead players
		if "is_dead" in p and p.get("is_dead"): continue
		var d := global_position.distance_to((p as Node3D).global_position)
		if d < best_d: best_d = d; best = p as Node3D

	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u == self: continue
		if not ("team_id" in u) or int(u.get("team_id")) == team_id: continue
		if u == enemy_base: continue
		var d := global_position.distance_to((u as Node3D).global_position)
		if d < best_d: best_d = d; best = u as Node3D

	return best


# ============================================================
# STATE TICKS
# ============================================================
func _tick_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 6)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 6)
		return

	var dest := patrol_points[_patrol_idx]

	# XZ-only distance — patrol points have hive Y which may not match terrain
	var xz_dist := Vector2(global_position.x - dest.x, global_position.z - dest.z).length()
	if xz_dist < 2.0:
		_patrol_idx = (_patrol_idx + 1) % patrol_points.size()
		dest = patrol_points[_patrol_idx]

	_steer_toward(dest, delta, move_speed * 0.75)


func _tick_chase(delta: float) -> void:
	if not is_instance_valid(_target):
		_target = null
		_state  = State.PATROL
		return

	var dist := global_position.distance_to(_target.global_position)

	# Lost sight — give up
	if dist > detection_range * 1.5:
		_target = null
		_state  = State.PATROL
		return

	if dist <= attack_range:
		_decelerate(delta)
		_face(_target.global_position)
		_try_attack(_target)
	else:
		_steer_toward(_target.global_position, delta, move_speed)


func _tick_aggro(delta: float) -> void:
	if not is_instance_valid(_target):
		_target = _find_nearest_enemy(99999.0)
		if not is_instance_valid(_target) and is_instance_valid(enemy_base):
			_target = enemy_base

	if not is_instance_valid(_target):
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 6)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 6)
		return

	var dist := global_position.distance_to(_target.global_position)
	if dist <= attack_range:
		_decelerate(delta)
		_face(_target.global_position)
		_try_attack(_target)
	else:
		_steer_toward(_target.global_position, delta, move_speed * 1.3)


# ============================================================
# MOVEMENT HELPERS
# ============================================================
func _steer_toward(dest: Vector3, delta: float, speed: float) -> void:
	var dir := dest - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.01: return
	dir = dir.normalized()
	velocity.x = lerp(velocity.x, dir.x * speed, 0.2)
	velocity.z = lerp(velocity.z, dir.z * speed, 0.2)
	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.2)


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 8)
	velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 8)


func _face(pos: Vector3) -> void:
	var dir := pos - global_position
	dir.y = 0.0
	if dir.length_squared() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.3)


# ============================================================
# COMBAT
# ============================================================
func _try_attack(t: Node3D) -> void:
	if _attack_timer > 0.0 or not is_instance_valid(t): return
	if "team_id" in t and int(t.get("team_id")) == team_id: return
	if global_position.distance_to(t.global_position) > attack_range + 0.5: return
	_attack_timer = attack_cooldown
	if _anim_tree:
		_anim_tree.set("parameters/attack_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	if t.has_method("take_damage"):
		t.take_damage(damage, self)


# ============================================================
# ANIMATION
# ============================================================
func _update_anim() -> void:
	if not is_instance_valid(_anim_tree): return
	var flat  := Vector2(velocity.x, velocity.z).length()
	var blend := clampf(flat / maxf(move_speed, 0.01), 0.0, 1.0)
	if blend < 0.05: blend = 0.0
	if absf(blend - _last_blend) < 0.02: return
	_last_blend = blend
	_anim_tree.set("parameters/move_blend/blend_position", blend)


# ============================================================
# PUBLIC API (called by HiveCluster)
# ============================================================

## Called when the hive is destroyed — guard permanently hunts enemies.
func enter_aggro_mode() -> void:
	_state  = State.AGGRO
	_target = _find_nearest_enemy(99999.0)
	if not is_instance_valid(_target) and is_instance_valid(enemy_base):
		_target = enemy_base


# ============================================================
# DAMAGE / DEATH
# ============================================================
func take_damage(amount: float, source = null) -> void:
	if _is_dead: return
	if source != null and "team_id" in source:
		if int(source.get("team_id")) == team_id: return
	health -= amount
	# Aggro on hit: switch to CHASE if patrolling and attacker is visible
	if _state == State.PATROL and is_instance_valid(source) and source is Node3D:
		_target = source as Node3D
		_state  = State.CHASE
	if health <= 0.0:
		_die()


func _die() -> void:
	if _is_dead: return
	_is_dead = true
	velocity  = Vector3.ZERO
	set_physics_process(false)
	if _anim_tree:
		_anim_tree.set("parameters/death_shot/request",
			AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_award_gold()
	get_tree().create_timer(1.8).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _award_gold() -> void:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if is_instance_valid(gm) and gm.has_method("award_gold"):
		gm.award_gold(1, gold_reward)
