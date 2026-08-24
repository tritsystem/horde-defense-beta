# ============================================================
# CorruptionManager.gd — AUTOLOAD
# ============================================================
# Spawns large corruption zones on every hive cluster and egg.
# Players deploy purifier beacons manually (key P, 45s CD).
# ============================================================
extends Node

signal zone_spawned(position: Vector3)
signal zone_purified(position: Vector3)
signal beacon_captured(position: Vector3)

const ZONE_DAMAGE_PER_SEC : float = 10.0
const ZONE_RADIUS         : float = 35.0   # large — covers whole nest area
const BEACON_PURIFY_RADIUS: float = 40.0
const CAPTURE_TIME        : float = 3.0    # 3s stand time to activate

var _zones   : Array = []
var _beacons : Array = []
var _active  : bool  = false


func _ready() -> void:
	add_to_group("corruption_manager")
	set_process(false)


func start() -> void:
	_active = true
	set_process(true)
	# Spawn zones on all existing hives and eggs
	await get_tree().process_frame
	for hive in get_tree().get_nodes_in_group("hive_clusters"):
		if is_instance_valid(hive) and hive is Node3D:
			_spawn_zone((hive as Node3D).global_position)
	for egg in get_tree().get_nodes_in_group("eggs"):
		if is_instance_valid(egg) and egg is Node3D:
			_spawn_zone_on_egg(egg as Node3D)
	# Connect to future hive/egg spawns
	get_tree().node_added.connect(_on_node_added)


func stop() -> void:
	_active = false
	set_process(false)


func _on_node_added(node: Node) -> void:
	if not _active: return
	if node.is_in_group("hive_clusters") and node is Node3D:
		await get_tree().process_frame
		_spawn_zone((node as Node3D).global_position)
	elif node.is_in_group("eggs") and node is Node3D:
		await get_tree().process_frame
		_spawn_zone_on_egg(node as Node3D)


func _process(delta: float) -> void:
	if not _active: return
	_tick_zones(delta)
	_tick_beacons(delta)


func _spawn_zone(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return

	var zone := Node3D.new()
	zone.global_position = pos
	zone.add_to_group("corruption_zone")
	zone.set_meta("radius", ZONE_RADIUS)
	zone.set_meta("purified", false)

	# Visual — a real puddle-of-corruption ground decal, not a raised
	# cylinder: near-flat, shaded (not unshaded, since a wet/liquid look
	# needs real lighting response to show any sheen at all) glossy
	# surface, with a procedural ripple normal map (FastNoiseLite via
	# NoiseTexture2D -- no art sourced, generated in code, same
	# placeholder-but-real precedent as every other procedural mesh in
	# this codebase) so it reads as liquid rather than a flat color disc.
	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius    = ZONE_RADIUS
	mesh.bottom_radius = ZONE_RADIUS
	mesh.height        = 0.04
	mi.mesh = mesh

	var ripple_noise := FastNoiseLite.new()
	ripple_noise.noise_type   = FastNoiseLite.TYPE_SIMPLEX
	ripple_noise.frequency    = 0.15
	var ripple_tex := NoiseTexture2D.new()
	ripple_tex.noise         = ripple_noise
	ripple_tex.as_normal_map = true
	ripple_tex.bump_strength = 3.0
	ripple_tex.width  = 128
	ripple_tex.height = 128
	ripple_tex.seamless = true

	var mat := StandardMaterial3D.new()
	mat.albedo_color        = Color(0.30, 0.0, 0.45, 0.55)
	mat.transparency        = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.metallic            = 0.6
	mat.roughness           = 0.12   # glossy/wet, not matte
	mat.normal_enabled      = true
	mat.normal_texture      = ripple_tex
	mat.normal_scale        = 1.4
	mat.emission_enabled    = true
	mat.emission            = Color(0.5, 0.0, 0.7) * 0.25
	mat.no_depth_test       = true   # prevents z-fighting when zones overlap
	mi.material_override = mat
	# Slight Y offset per zone count so layers don't overlap exactly
	mi.position.y = 0.02 + _zones.size() * 0.01
	zone.add_child(mi)

	var lbl := Label3D.new()
	lbl.text      = "☠ CORRUPTED — Deploy Purifier [P]"
	lbl.font_size = 20
	lbl.modulate  = Color(0.8, 0.3, 1.0)
	lbl.position.y = 2.0
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	zone.add_child(lbl)

	scene.add_child(zone)
	_zones.append(zone)
	zone_spawned.emit(pos)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("☠ Corruption zone! Deploy purifier [P]", Color(0.7, 0.2, 1.0))
	print("[CorruptionManager] Zone spawned at %s (r=%.0f)" % [str(pos.snapped(Vector3.ONE)), ZONE_RADIUS])


func _spawn_zone_on_egg(egg: Node3D) -> void:
	_spawn_zone(egg.global_position)
	# Remove zone when egg is destroyed
	if egg.has_signal("egg_destroyed"):
		egg.egg_destroyed.connect(func(_e): _remove_zone_near(egg.global_position), CONNECT_ONE_SHOT)
	elif egg.has_signal("hatched"):
		egg.hatched.connect(func(_e): _remove_zone_near(egg.global_position), CONNECT_ONE_SHOT)


func _remove_zone_near(pos: Vector3) -> void:
	for zone in _zones:
		if not is_instance_valid(zone): continue
		if zone.global_position.distance_to(pos) < 5.0:
			zone.queue_free()


# ── Called by player when they deploy a purifier beacon ──────
func deploy_beacon(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return

	var beacon_node := Node3D.new()
	beacon_node.global_position = pos
	beacon_node.add_to_group("purifier_beacon")

	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.4; mesh.bottom_radius = 0.5; mesh.height = 2.4
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.1, 0.6, 1.0)
	mat.emission_enabled = true
	mat.emission         = Color(0.1, 0.6, 1.0) * 1.2
	mi.material_override = mat
	beacon_node.add_child(mi)

	var lbl := Label3D.new()
	lbl.text = "⬟ PURIFIER\nStand nearby…"
	lbl.font_size = 18; lbl.position.y = 3.0
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(0.4, 0.9, 1.0)
	beacon_node.add_child(lbl)

	scene.add_child(beacon_node)
	_beacons.append({"node": beacon_node, "pos": pos, "progress": 0.0, "lbl": lbl})
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("⬟ Purifier deployed — stand on it to activate!", Color(0.4, 0.9, 1.0))


func _tick_zones(delta: float) -> void:
	# Collect which players are inside any zone — damage each player once only
	var damaged_players : Array = []
	for zone in _zones:
		if not is_instance_valid(zone): continue
		if bool(zone.get_meta("purified", false)): continue
		var zone3d := zone as Node3D
		if not is_instance_valid(zone3d): continue
		for player in get_tree().get_nodes_in_group("players"):
			if not is_instance_valid(player): continue
			if player in damaged_players: continue
			if player is Node3D:
				var dist : float = zone3d.global_position.distance_to((player as Node3D).global_position)
				if dist < ZONE_RADIUS and player.has_method("take_damage"):
					player.take_damage(ZONE_DAMAGE_PER_SEC * delta)
					damaged_players.append(player)


func _tick_beacons(delta: float) -> void:
	var to_remove : Array = []
	for bdata in _beacons:
		var bnode : Node3D = bdata.get("node") as Node3D
		if not is_instance_valid(bnode):
			to_remove.append(bdata)
			continue
		var near_player := false
		for player in get_tree().get_nodes_in_group("players"):
			if player is Node3D:
				if bnode.global_position.distance_to((player as Node3D).global_position) < 5.0:
					near_player = true; break
		var lbl : Label3D = bdata.get("lbl") as Label3D
		if near_player:
			bdata["progress"] = minf(float(bdata["progress"]) + delta, CAPTURE_TIME)
			var pct : float = float(bdata["progress"]) / CAPTURE_TIME
			if is_instance_valid(lbl):
				lbl.text = "⬟ PURIFIER\n%.0f%%" % (pct * 100.0)
			if float(bdata["progress"]) >= CAPTURE_TIME:
				var captured_pos : Vector3 = bnode.global_position
				_purify_nearby_zones(captured_pos)
				beacon_captured.emit(captured_pos)
				for hud in get_tree().get_nodes_in_group("hud"):
					if hud.has_method("show_message"):
						hud.show_message("✅ Zone purified!", Color(0.4, 1.0, 0.6))
				bnode.queue_free()
				to_remove.append(bdata)
		else:
			bdata["progress"] = maxf(0.0, float(bdata["progress"]) - delta * 0.4)
			if is_instance_valid(lbl): lbl.text = "⬟ PURIFIER\nStand nearby…"
	for entry in to_remove:
		_beacons.erase(entry)


func _purify_nearby_zones(_beacon_pos: Vector3) -> void:
	# Purify ALL active zones on the map
	for zone in _zones:
		if not is_instance_valid(zone): continue
		if bool(zone.get_meta("purified", false)): continue
		zone.set_meta("purified", true)
		zone_purified.emit(zone.global_position)
		var mi : Node = zone.get_child(0) if zone.get_child_count() > 0 else null
		if is_instance_valid(mi) and mi is MeshInstance3D:
			var tw := get_tree().create_tween()
			tw.tween_property(mi, "modulate:a", 0.0, 1.5)
			tw.tween_callback(zone.queue_free)
		else:
			get_tree().create_timer(1.5).timeout.connect(zone.queue_free)
	_zones.clear()
