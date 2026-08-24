# ============================================================
# CrystalShard.gd — extends Node3D, proximity pickup
# ============================================================
extends Node3D

@export var lifetime       : float = 18.0
@export var bob_speed      : float = 2.2
@export var bob_height     : float = 0.18
@export var spin_speed     : float = 1.8
@export var pickup_radius  : float = 1.2
@export var attract_radius : float = 3.5
@export var attract_speed  : float = 9.0

var _time      : float = 0.0
var _origin_y  : float = 0.0
var _collected : bool  = false
var _mesh      : MeshInstance3D
var _light     : OmniLight3D

const CRYSTAL_COLOR := Color(0.55, 0.2, 1.0)

# REAL LAG FIX (2026-07-23): _process() was calling
# get_tree().get_nodes_in_group("player") every single frame, for every
# crystal shard on the ground -- each call allocates a fresh Array. During
# a heavy wave with many kills dropping shards, this compounds into real
# per-frame allocation/GC pressure. The nearest-player lookup is now
# throttled to SCAN_INTERVAL; the actual magnet-pull movement still runs
# every frame off the cached reference so the motion itself stays smooth,
# not stepped.
const SCAN_INTERVAL : float = 0.12
var _scan_cd    : float = 0.0
var _cached_player : Node3D = null


func _ready() -> void:
	_origin_y = global_position.y
	_build_visuals()
	get_tree().create_timer(lifetime * 0.75).timeout.connect(_start_blink)
	get_tree().create_timer(lifetime).timeout.connect(
		func(): if not _collected and is_instance_valid(self): queue_free())


func _process(delta: float) -> void:
	if _collected: return
	_time += delta

	global_position.y = _origin_y + sin(_time * bob_speed) * bob_height
	rotation.y += spin_speed * delta

	if is_instance_valid(_light):
		_light.light_energy = 1.2 + sin(_time * 4.0) * 0.4

	# Proximity check — no Area3D needed. Nearest-player lookup is throttled
	# (see SCAN_INTERVAL note above); movement itself still runs every frame.
	_scan_cd -= delta
	if _scan_cd <= 0.0:
		_scan_cd = SCAN_INTERVAL
		_cached_player = null
		var best_dist : float = attract_radius
		for p in get_tree().get_nodes_in_group("player"):
			if not (p is Node3D): continue
			var d : float = global_position.distance_to((p as Node3D).global_position)
			if d < best_dist:
				best_dist = d
				_cached_player = p as Node3D

	if is_instance_valid(_cached_player):
		var dist : float = global_position.distance_to(_cached_player.global_position)
		if dist < attract_radius:
			var pull : Vector3 = (_cached_player.global_position - global_position).normalized()
			global_position += pull * attract_speed * delta
		if dist < pickup_radius:
			_collect(_cached_player)
			return


func _collect(p: Node) -> void:
	_collected = true
	if p.has_method("add_crystal"):
		p.add_crystal(1)
	elif "crystals" in p:
		p.set("crystals", int(p.get("crystals")) + 1)
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("show_crystal_pickup"): h.show_crystal_pickup(); break
	queue_free()


func _start_blink() -> void:
	if _collected or not is_instance_valid(self): return
	var tw := create_tween().set_loops(8)
	tw.tween_property(self, "modulate:a", 0.2, 0.25)
	tw.tween_property(self, "modulate:a", 1.0, 0.25)


func _build_visuals() -> void:
	_mesh = MeshInstance3D.new()
	var gem := CylinderMesh.new()
	gem.top_radius     = 0.0
	gem.bottom_radius  = 0.18
	gem.height         = 0.38
	gem.radial_segments = 5
	_mesh.mesh = gem
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = CRYSTAL_COLOR
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color               = Color(CRYSTAL_COLOR.r, CRYSTAL_COLOR.g, CRYSTAL_COLOR.b, 0.88)
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh.material_override = mat
	add_child(_mesh)

	var shard2 := MeshInstance3D.new()
	shard2.mesh = gem
	shard2.material_override = mat
	shard2.rotation_degrees = Vector3(180, 45, 0)
	shard2.scale = Vector3(0.7, 0.7, 0.7)
	add_child(shard2)

	_light = OmniLight3D.new()
	_light.light_color    = CRYSTAL_COLOR
	_light.light_energy   = 1.4
	_light.omni_range     = 2.2
	_light.shadow_enabled = false
	add_child(_light)
