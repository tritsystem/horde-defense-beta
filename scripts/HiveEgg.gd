# ============================================================
# ⚠ NOT LIVE — NOT ATTACHED TO ANY SCENE (2026-07-25) ⚠
# Superseded by Egg.gd (repo root), which is what HiveCluster.gd actually
# instantiates (Egg.new()) in the live game. This file is only ever load()'d
# from the also-dead scripts/HiveNode.gd. Editing this file has no effect
# on gameplay — edit Egg.gd instead.
# ============================================================
# HiveEgg.gd
# ============================================================
# Attach to any Node3D inside a HiveNode to create a breakable
# egg. When reduced to 0 HP, units burst out at this position.
#
# Usage (scene editor):
#   1. Add a Node3D child inside your HiveNode scene.
#   2. Attach this script.
#   3. Set max_health and units_on_break in the Inspector.
#
# Usage (procedural, from HiveNode._build_eggs):
#   HiveNode creates these automatically if @export egg_count > 0.
# ============================================================
extends Node3D

@export var max_health    : float = 60.0
@export var units_on_break: int   = 2      # enemies spawned on destruction
@export var team_id       : int   = 2      # enemy team

var health  : float = 0.0
var is_dead : bool  = false

# Visual — a pulsing sphere so eggs are visible without art assets
var _mesh_inst : MeshInstance3D = null


func _ready() -> void:
	add_to_group("eggs")
	health = max_health
	_build_visual()


func _build_visual() -> void:
	_mesh_inst = MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius  = 0.45
	sp.height  = 0.9
	sp.radial_segments = 8
	sp.rings = 4
	_mesh_inst.mesh = sp

	var mat := StandardMaterial3D.new()
	mat.albedo_color   = Color(0.18, 0.55, 0.12)
	mat.emission_enabled = true
	mat.emission       = Color(0.05, 0.3, 0.05)
	mat.roughness      = 0.6
	_mesh_inst.material_override = mat
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_inst)


func take_damage(amount: float, _source = null) -> void:
	if is_dead:
		return
	health -= amount
	# Flash red on hit
	if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
		(_mesh_inst.material_override as StandardMaterial3D).albedo_color = Color(0.8, 0.1, 0.05)
		get_tree().create_timer(0.12).timeout.connect(func():
			if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
				(_mesh_inst.material_override as StandardMaterial3D).albedo_color = Color(0.18, 0.55, 0.12)
		, CONNECT_ONE_SHOT)
	if health <= 0.0:
		_crack()


func _crack() -> void:
	if is_dead:
		return
	is_dead  = true
	health   = 0.0

	# Spawn units via parent hive (keeps spawning logic in one place)
	var parent = get_parent()
	if is_instance_valid(parent) and parent.has_method("spawn_units_at_pos"):
		parent.spawn_units_at_pos(global_position, units_on_break)
	else:
		# Fallback: ask ZombieHordeManager directly
		_zhm_spawn_at(global_position, units_on_break)

	# Small VFX: green burst via a quick MeshInstance3D ring (no dependency on player.gd)
	_vfx_pop()
	queue_free()


func _zhm_spawn_at(pos: Vector3, count: int) -> void:
	if Engine.has_singleton("ZombieHordeManager"):
		var zhm = Engine.get_singleton("ZombieHordeManager")
		if zhm.has_method("spawn_horde"):
			# 1 × 1 area — units pop out right at the egg's cracked position
			var area := AABB(pos - Vector3(0.5, 0.0, 0.5), Vector3(1.0, 2.0, 1.0))
			zhm.spawn_horde(count, area)


func _vfx_pop() -> void:
	# Simple expanding ring that fades — no physics, no particles needed
	var ring := MeshInstance3D.new()
	var tor  := TorusMesh.new()
	tor.inner_radius  = 0.1
	tor.outer_radius  = 0.6
	tor.rings         = 8
	tor.ring_segments = 8
	ring.mesh = tor
	var mat := StandardMaterial3D.new()
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color     = Color(0.2, 1.0, 0.1, 0.9)
	mat.emission_enabled = true
	mat.emission         = Color(0.1, 0.8, 0.1)
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	get_parent().add_child(ring)
	ring.global_position = global_position + Vector3.UP * 0.3

	var tw := get_parent().create_tween()
	tw.tween_property(ring, "scale", Vector3(3.0, 3.0, 3.0), 0.35)
	tw.parallel().tween_property(mat, "albedo_color", Color(0.2, 1.0, 0.1, 0.0), 0.35)
	tw.tween_callback(ring.queue_free)
