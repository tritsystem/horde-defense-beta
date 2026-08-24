# ============================================================
# ⚠ NOT LIVE IN THE MAIN GAME (2026-07-25) ⚠
# Only referenced by "main (2).tscn", which is a stale duplicate scene —
# the game actually boots main.tscn (via MainMenu.tscn), which uses
# LaneSpawner.gd for all zombie delivery instead. Editing this file has
# no effect on the real game. Zombies should only ever come from
# eggs/nests (Egg.gd / HiveCluster.gd) now — this spawner (and its
# per-lane wave logic) is legacy and should not be wired back in.
# ============================================================
# CreepSpawner.gd
# ============================================================
# Place one per team per lane. Assign enemy_base and
# friendly_base in the Inspector. enemy_base MUST be the
# opposite team's base node.
# ============================================================
extends Node3D

enum Lane { TOP, MID, BOT }

@export var lane_id          : Lane       = Lane.MID
@export var team_id          : int        = 2
@export var enemy_base       : Node3D     = null
@export var friendly_base    : Node3D     = null
@export var active           : bool       = false
@export var creep_scene      : PackedScene
@export var wave_size        : int        = 6
@export var wave_interval    : float      = 30.0
@export var spawn_delay      : float      = 0.25
@export var wave_spread      : float      = 1.0
@export var wave_scaling     : bool       = true
@export var scaling_interval : float      = 5.0
@export var waypoint_nodes   : Array[Node3D] = []

var wave_number         : int   = 0
var timer               : float = 0.0
var spawning            : bool  = false
var _computed_waypoints : Array[Vector3] = []


func _ready() -> void:
	add_to_group("creep_spawner")
	add_to_group("lane_" + Lane.keys()[lane_id].to_lower())
	timer = wave_interval
	call_deferred("_init_waypoints")
	call_deferred("_validate")


func _validate() -> void:
	# Critical: warn if enemy_base is same team as this spawner
	if is_instance_valid(enemy_base) and "team_id" in enemy_base:
		if int(enemy_base.get("team_id")) == team_id:
			push_error("[Spawner:%s] ❌ enemy_base '%s' has same team_id=%d as spawner! Fix in Inspector." % [
				name, enemy_base.name, team_id])
	if is_instance_valid(friendly_base) and "team_id" in friendly_base:
		if int(friendly_base.get("team_id")) != team_id:
			push_error("[Spawner:%s] ❌ friendly_base '%s' has team_id=%d but spawner is team %d!" % [
				name, friendly_base.name, int(friendly_base.get("team_id")), team_id])
	print("[Spawner:%s] team=%d  enemy_base=%s  friendly_base=%s  waypoints=%d" % [
		name, team_id,
		enemy_base.name    if is_instance_valid(enemy_base)    else "NULL",
		friendly_base.name if is_instance_valid(friendly_base) else "NULL",
		waypoint_nodes.size()])


func _init_waypoints() -> void:
	_computed_waypoints.clear()

	# Use Inspector-assigned waypoint nodes if provided
	if not waypoint_nodes.is_empty():
		for wp in waypoint_nodes:
			if is_instance_valid(wp):
				_computed_waypoints.append(wp.global_position)
		if not _computed_waypoints.is_empty(): return

	if not is_instance_valid(enemy_base):
		push_warning("[Spawner:%s] No enemy_base — cannot generate waypoints." % name)
		return

	# Auto-generate lane paths — each lane takes a different curved route
	var start : Vector3 = global_position
	var end_p : Vector3 = enemy_base.global_position
	var mid   : Vector3 = start.lerp(end_p, 0.5)

	# Perpendicular offset direction (XZ plane)
	var lane_dir   := (end_p - start)
	lane_dir.y     = 0.0
	var perp       := Vector3(-lane_dir.z, 0.0, lane_dir.x).normalized()

	# Lane offset: TOP = hard left, MID = center, BOT = hard right
	var offsets : Array = [-1.0, 0.0, 1.0]   # TOP, MID, BOT
	var lane_scale : float = lane_dir.length() * 0.3   # 30% of total distance

	var offset_vec : Vector3 = perp * offsets[int(lane_id)] * lane_scale
	var bulge      := mid + offset_vec

	# Generate 6 waypoints along the curved lane path
	for i in range(6):
		var t : float = float(i) / 5.0
		# Quadratic bezier: start → bulge → end
		var p : Vector3 = start.lerp(bulge, t).lerp(bulge.lerp(end_p, t), t)
		_computed_waypoints.append(p)

	print("[Spawner:%s] Lane=%s waypoints: %s → %s (bulge offset=%.1fm)" % [
		name, Lane.keys()[lane_id],
		str(start.snapped(Vector3.ONE)), str(end_p.snapped(Vector3.ONE)),
		offset_vec.length()])


func _process(delta: float) -> void:
	if not active or spawning or creep_scene == null: return
	if not is_instance_valid(enemy_base): return
	timer -= delta
	if timer <= 0.0:
		timer = wave_interval
		spawn_wave()


func spawn_wave() -> void:
	wave_number += 1
	spawning = true
	print("[Spawner:%s] Wave %d | team:%d" % [name, wave_number, team_id])
	await _spawn_all()
	spawning = false


func _spawn_all() -> void:
	var count : int = wave_size
	if wave_scaling:
		count += int(float(wave_number) / scaling_interval)
	for i in range(count):
		_spawn_single(global_position + _line_offset(i, count), i, null)
		if i < count - 1:
			await get_tree().create_timer(spawn_delay).timeout


func _spawn_single(pos: Vector3, index: int, owner_player: Node) -> Node:
	if creep_scene == null: return null
	var creep = creep_scene.instantiate()
	if creep == null: return null

	# Identity BEFORE add_child so _ready()/_find_bases() sees correct values
	_apply_identity(creep, owner_player)
	get_tree().current_scene.add_child(creep)
	creep.global_position = pos
	creep.add_to_group("units")
	creep.add_to_group("lane_" + Lane.keys()[lane_id].to_lower())
	_apply_lane(creep)
	return creep


func spawn_purchased_creep(scene: PackedScene, owner_player: Node) -> Node:
	if scene == null or not is_instance_valid(enemy_base): return null
	var creep = scene.instantiate()
	if creep == null: return null
	_apply_identity(creep, owner_player)
	get_tree().current_scene.add_child(creep)
	creep.global_position = global_position + _line_offset(0, 1)
	creep.add_to_group("units")
	creep.add_to_group("lane_" + Lane.keys()[lane_id].to_lower())
	_apply_lane(creep)
	return creep


func _apply_identity(creep: Node, owner_player: Node) -> void:
	if "team_id"       in creep: creep.set("team_id",       team_id)
	if "enemy_base"    in creep: creep.set("enemy_base",    enemy_base)
	if "friendly_base" in creep: creep.set("friendly_base", friendly_base)
	if is_instance_valid(owner_player):
		if "owner_player" in creep: creep.set("owner_player", owner_player)
		if "owner_id"     in creep: creep.set("owner_id",     owner_player.get_instance_id())


func _apply_lane(creep: Node) -> void:
	if _computed_waypoints.is_empty(): _init_waypoints()
	if _computed_waypoints.is_empty(): return
	if creep.has_method("set_lane"):
		creep.set_lane(_computed_waypoints, int(lane_id))


func start_spawning() -> void:
	active = true
	timer  = 3.0
	print("[Spawner:%s] starting — first wave in 3s" % name)


func _line_offset(i: int, count: int) -> Vector3:
	var right : Vector3 = -global_transform.basis.x
	var half  : float   = (count - 1) * wave_spread * 0.5
	return right * (i * wave_spread - half)
