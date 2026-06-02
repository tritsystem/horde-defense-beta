# ============================================================
# CorruptionManager.gd — AUTOLOAD
# ============================================================
# Spawns corruption zones that damage players over time.
# Purifier beacons (capture points) neutralize nearby zones.
#
# Register as Autoload: CorruptionManager
# ============================================================
extends Node

signal zone_spawned(position: Vector3)
signal zone_purified(position: Vector3)
signal beacon_captured(position: Vector3)

const ZONE_DAMAGE_PER_SEC : float = 8.0
const ZONE_RADIUS         : float = 12.0
const BEACON_PURIFY_RADIUS: float = 18.0
const CAPTURE_TIME        : float = 6.0
const SPAWN_INTERVAL      : float = 90.0   # new zone every 90s
const MAX_ZONES           : int   = 4

var _zones   : Array = []   # Array[Node3D]
var _beacons : Array = []   # Array[Dictionary] {node, pos, progress, team}
var _spawn_timer : float = 45.0  # first zone after 45s
var _active  : bool = false


func _ready() -> void:
	add_to_group("corruption_manager")


func start() -> void:
	_active = true
	set_process(true)


func stop() -> void:
	_active = false
	set_process(false)


func _process(delta: float) -> void:
	if not _active: return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and _zones.size() < MAX_ZONES:
		_spawn_timer = SPAWN_INTERVAL
		_spawn_zone()

	_tick_zones(delta)
	_tick_beacons(delta)


func _spawn_zone() -> void:
	# Pick a random position away from bases
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return
	var rx := randf_range(-60.0, 60.0)
	var rz := randf_range(-60.0, 60.0)
	var pos := Vector3(rx, 0.3, rz)

	var zone := Node3D.new()
	zone.global_position = pos
	zone.add_to_group("corruption_zone")
	zone.set_meta("radius", ZONE_RADIUS)
	zone.set_meta("damage_ps", ZONE_DAMAGE_PER_SEC)
	zone.set_meta("purified", false)

	# Visual — dark purple sphere
	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius    = ZONE_RADIUS
	mesh.bottom_radius = ZONE_RADIUS
	mesh.height        = 0.25
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.35, 0.0, 0.55, 0.45)
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission         = Color(0.4, 0.0, 0.6) * 0.5
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	zone.add_child(mi)

	# Label
	var lbl := Label3D.new()
	lbl.text = "☠ CORRUPTED"
	lbl.font_size = 22
	lbl.modulate = Color(0.8, 0.3, 1.0)
	lbl.position.y = 1.2
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	zone.add_child(lbl)

	scene.add_child(zone)
	_zones.append(zone)
	zone_spawned.emit(pos)

	# Announce
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("☠ Corruption zone appeared! Find a purifier beacon.", Color(0.7, 0.2, 1.0))

	# Also spawn a nearby purifier beacon
	_spawn_beacon(pos + Vector3(randf_range(20.0, 30.0), 0.0, randf_range(-10.0, 10.0)))
	print("[CorruptionManager] Zone spawned at %s" % str(pos.snapped(Vector3.ONE)))


func _spawn_beacon(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return

	var beacon_node := Node3D.new()
	beacon_node.global_position = pos
	beacon_node.add_to_group("purifier_beacon")

	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.4; mesh.bottom_radius = 0.5; mesh.height = 2.2
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.1, 0.6, 1.0)
	mat.emission_enabled = true
	mat.emission         = Color(0.1, 0.6, 1.0) * 0.8
	mi.material_override = mat
	beacon_node.add_child(mi)

	var lbl := Label3D.new()
	lbl.text = "⬟ PURIFIER"
	lbl.font_size = 20
	lbl.modulate = Color(0.4, 0.9, 1.0)
	lbl.position.y = 2.8
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	beacon_node.add_child(lbl)

	scene.add_child(beacon_node)
	_beacons.append({"node": beacon_node, "pos": pos, "progress": 0.0, "active": false})


func _tick_zones(delta: float) -> void:
	for zone in _zones:
		if not is_instance_valid(zone): continue
		if bool(zone.get_meta("purified", false)): continue
		# Damage any player inside the zone
		for player in get_tree().get_nodes_in_group("players"):
			if not is_instance_valid(player): continue
			if player is Node3D:
				var dist := zone.global_position.distance_to((player as Node3D).global_position)
				if dist < ZONE_RADIUS:
					if player.has_method("take_damage"):
						player.take_damage(ZONE_DAMAGE_PER_SEC * delta)


func _tick_beacons(delta: float) -> void:
	for bdata in _beacons:
		var bnode : Node3D = bdata["node"]
		if not is_instance_valid(bnode): continue
		# Check if any player is near beacon
		var near_player := false
		for player in get_tree().get_nodes_in_group("players"):
			if player is Node3D:
				if bnode.global_position.distance_to((player as Node3D).global_position) < 4.0:
					near_player = true; break
		if near_player:
			bdata["progress"] += delta
			if bdata["progress"] >= CAPTURE_TIME:
				_purify_nearby_zones(bnode.global_position)
				beacon_captured.emit(bnode.global_position)
				for hud in get_tree().get_nodes_in_group("hud"):
					if hud.has_method("show_message"): hud.show_message("✅ Purifier activated!", Color(0.4, 1.0, 0.6))
				bnode.queue_free()
		else:
			bdata["progress"] = maxf(0.0, bdata["progress"] - delta * 0.5)


func _purify_nearby_zones(beacon_pos: Vector3) -> void:
	for zone in _zones:
		if not is_instance_valid(zone): continue
		if zone.global_position.distance_to(beacon_pos) < BEACON_PURIFY_RADIUS:
			zone.set_meta("purified", true)
			zone_purified.emit(zone.global_position)
			# Fade out visual
			var mi := zone.get_child(0) if zone.get_child_count() > 0 else null
			if is_instance_valid(mi) and mi is MeshInstance3D:
				var tw := get_tree().create_tween()
				tw.tween_property(mi, "modulate:a", 0.0, 1.5)
				tw.tween_callback(zone.queue_free)
			else:
				get_tree().create_timer(1.5).timeout.connect(zone.queue_free)
