class_name HiveCluster
extends Node3D
# ============================================================
# HiveCluster.gd — one nest: hive structure + patrol guards + eggs.
#
# Performance design:
#   - _process is removed entirely. Guard LOD runs every 2 s via a
#     SceneTreeTimer chain — no per-frame cost for 8-12 clusters.
#   - Guards use PROCESS_MODE_DISABLED when >LOD_GUARD_DIST from camera.
#
# Wave mechanism: eggs ARE the wave source. On hatch they spawn creeps
# at their world position. The hive spawns a fresh egg after a delay.
# ============================================================

@export var tier              : int   = 1
@export var hive_hp           : float = 500.0
@export var patrol_count      : int   = 2
@export var max_eggs          : int   = 2
@export var egg_spawn_interval: float = 60.0
@export var egg_hatch_time    : float = 60.0
@export var egg_wave_size     : int   = 6
@export var patrol_radius     : float = 16.0

# Set by HiveNestManager before adding to tree
var attack_target : Node3D = null
var creep_pool    : Array  = ["zombie"]

signal cluster_cleared

var health : float = 0.0

var _cleared       : bool  = false
var _patrol_units  : Array = []
var _eggs          : Array = []
var _hive_mat      : StandardMaterial3D = null
var _guards_active : bool  = true

var _hp_bar_root : Node3D             = null
var _hp_fill_mi  : MeshInstance3D     = null
var _hp_fill_mat : StandardMaterial3D = null
var _hp_label    : Label3D            = null

const GUARD_SCENE    := "res://zombie/zombie.tscn"
const PATROL_AIMODE  := 3
const ATTACK_AIMODE  := 1
const LOD_GUARD_DIST : float = 200.0


func _ready() -> void:
	health = hive_hp
	_build_hive_structure()
	add_to_group("hive_clusters")
	call_deferred("_deferred_init")


func _deferred_init() -> void:
	_snap_to_ground()
	_spawn_initial_eggs()
	_spawn_patrol_guards()
	_schedule_guard_lod()
	_spawn_hive_heart()


# ── Guard LOD poll (replaces _process) ───────────────────────
func _schedule_guard_lod() -> void:
	get_tree().create_timer(2.0).timeout.connect(_guard_lod_poll)


func _guard_lod_poll() -> void:
	if _cleared: return
	_update_guard_lod()
	_schedule_guard_lod()


func _update_guard_lod() -> void:
	var cam_pos : Vector3 = _get_camera_pos()
	var dist    : float   = global_position.distance_to(cam_pos)
	var want    : bool    = dist < LOD_GUARD_DIST
	if want == _guards_active: return
	_guards_active = want
	var mode : int = Node.PROCESS_MODE_INHERIT if want else Node.PROCESS_MODE_DISABLED
	for g in _patrol_units:
		if is_instance_valid(g):
			g.process_mode = mode


func _get_camera_pos() -> Vector3:
	var vp := get_viewport()
	if vp:
		var cam := vp.get_camera_3d()
		if is_instance_valid(cam): return cam.global_position
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node3D: return (p as Node3D).global_position
	return global_position


# ── Ground-snapping ──────────────────────────────────────────
func _snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	var ray   := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 120.0,
		global_position + Vector3.DOWN * 60.0)
	ray.collision_mask = 1
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		global_position.y = hit.position.y


# ── Hive structure ───────────────────────────────────────────
func _build_hive_structure() -> void:
	var r : float = 2.0 + tier * 0.55

	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = r; mesh.height = r * 1.35
	mi.mesh = mesh
	_hive_mat = StandardMaterial3D.new()
	_hive_mat.albedo_color = Color(0.08, 0.42, 0.08).lerp(Color(0.26, 0.04, 0.30), float(tier - 1) / 4.0)
	_hive_mat.roughness    = 0.88
	mi.material_override   = _hive_mat
	mi.position.y          = r * 0.5
	add_child(mi)

	var body  := StaticBody3D.new()
	var coll  := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius    = r
	coll.shape      = shape
	body.position.y = r * 0.5
	body.add_child(coll)
	add_child(body)
	body.add_to_group("hive_structures")

	_build_glow_ring(r)
	_build_tier_label(tier, r)
	_build_hp_display(r)


func _build_glow_ring(r: float) -> void:
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = r + 0.15
	mesh.outer_radius = r + 0.60
	ring.mesh = mesh
	var mat := StandardMaterial3D.new()
	var col  : Color = Color(0.2, 1.0, 0.2).lerp(Color(0.8, 0.0, 1.0), float(tier - 1) / 4.0)
	mat.albedo_color     = Color(col.r, col.g, col.b, 0.55)
	mat.emission_enabled = true
	mat.emission         = col * 0.9
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = mat
	ring.position.y      = 0.06
	add_child(ring)


func _build_tier_label(t: int, r: float) -> void:
	var label := Label3D.new()
	label.text          = "T%d" % t
	label.font_size     = 48
	label.modulate      = Color(1.0, 0.9, 0.3)
	label.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position.y    = r * 1.4 + 1.2
	add_child(label)


func _build_hp_display(r: float) -> void:
	var bar_y : float = r * 1.4 + 2.6

	_hp_bar_root = Node3D.new()
	_hp_bar_root.position.y = bar_y
	add_child(_hp_bar_root)

	# HP number
	_hp_label = Label3D.new()
	_hp_label.text         = "%d / %d" % [int(hive_hp), int(hive_hp)]
	_hp_label.font_size    = 28
	_hp_label.modulate     = Color(1.0, 0.85, 0.85, 1.0)
	_hp_label.billboard    = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.no_depth_test = true
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.position.y   = 0.38
	_hp_bar_root.add_child(_hp_label)

	var bar_w : float = 2.2
	var bar_h : float = 0.18

	# Background
	var bg_mi   := MeshInstance3D.new()
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(bar_w, bar_h)
	bg_mi.mesh = bg_mesh
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color   = Color(0.1, 0.1, 0.1, 0.9)
	bg_mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.no_depth_test  = true
	bg_mi.material_override = bg_mat
	_hp_bar_root.add_child(bg_mi)

	# Fill
	_hp_fill_mi       = MeshInstance3D.new()
	var fill_mesh     := QuadMesh.new()
	fill_mesh.size     = Vector2(bar_w, bar_h)
	_hp_fill_mi.mesh   = fill_mesh
	_hp_fill_mat       = StandardMaterial3D.new()
	_hp_fill_mat.albedo_color   = Color(0.2, 0.8, 0.2)
	_hp_fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hp_fill_mat.no_depth_test  = true
	_hp_fill_mi.material_override = _hp_fill_mat
	_hp_bar_root.add_child(_hp_fill_mi)


func _update_hp_display() -> void:
	if not is_instance_valid(_hp_label): return
	var h   : float = maxf(0.0, health)
	var pct : float = clampf(h / hive_hp, 0.0, 1.0)
	_hp_label.text = "%d / %d" % [int(h), int(hive_hp)]
	if is_instance_valid(_hp_fill_mi):
		_hp_fill_mi.scale.x    = pct
		_hp_fill_mi.position.x = (pct - 1.0) * 1.1
	if is_instance_valid(_hp_fill_mat):
		_hp_fill_mat.albedo_color = (
			Color(0.2, 0.8, 0.2).lerp(Color(0.9, 0.8, 0.0), (1.0 - pct) * 2.0)
			if pct > 0.5 else
			Color(0.9, 0.8, 0.0).lerp(Color(0.85, 0.1, 0.05), (0.5 - pct) * 2.0)
		)


# ── Eggs ─────────────────────────────────────────────────────
func _spawn_initial_eggs() -> void:
	for _i in max_eggs:
		_spawn_single_egg()


func _spawn_single_egg() -> void:
	if _cleared: return
	if _eggs.size() >= max_eggs: return

	var space := get_world_3d().direct_space_state
	var angle : float   = randf() * TAU
	var dist  : float   = patrol_radius * 0.42 + randf() * 3.5
	var wpos  : Vector3 = global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)

	var ray := PhysicsRayQueryParameters3D.create(
		wpos + Vector3.UP * 60.0, wpos + Vector3.DOWN * 30.0)
	ray.collision_mask = 1
	var hit := space.intersect_ray(ray)
	if not hit.is_empty(): wpos.y = hit.position.y

	var egg := Egg.new()
	egg.tier          = tier
	egg.max_hp        = 55.0 + tier * 22.0
	egg.hatch_time    = egg_hatch_time
	egg.wave_size     = egg_wave_size
	egg.attack_target = attack_target
	egg.creep_ids     = creep_pool.duplicate()
	get_tree().current_scene.add_child(egg)
	egg.global_position = wpos
	egg.hatched.connect(_on_egg_gone)
	egg.egg_destroyed.connect(_on_egg_gone)
	_eggs.append(egg)


# ── Patrol guards ─────────────────────────────────────────────
func _spawn_patrol_guards() -> void:
	if not ResourceLoader.exists(GUARD_SCENE):
		push_warning("[HiveCluster] Guard scene not found: %s" % GUARD_SCENE)
		return
	var guard_scene : PackedScene    = load(GUARD_SCENE)
	var circle      : Array[Vector3] = _patrol_circle(global_position, patrol_radius, max(8, patrol_count * 2))
	var space       := get_world_3d().direct_space_state

	for i in patrol_count:
		var angle     : float   = (float(i) / float(patrol_count)) * TAU
		var spawn_pos : Vector3 = global_position + Vector3(cos(angle) * patrol_radius * 0.6, 0.5, sin(angle) * patrol_radius * 0.6)

		var ray := PhysicsRayQueryParameters3D.create(
			spawn_pos + Vector3.UP * 30.0, spawn_pos + Vector3.DOWN * 15.0)
		ray.collision_mask = 1
		var hit := space.intersect_ray(ray)
		if not hit.is_empty(): spawn_pos.y = hit.position.y + 0.3

		var guard : Node = guard_scene.instantiate()
		if "team_id"       in guard: guard.set("team_id",       2)
		if "ai_mode"       in guard: guard.set("ai_mode",       PATROL_AIMODE)
		if "enemy_base"    in guard and is_instance_valid(attack_target):
			guard.set("enemy_base", attack_target)
		if "patrol_points" in guard: guard.set("patrol_points", circle)
		if "max_health"    in guard: guard.set("max_health",    180.0 + tier * 90.0)
		if "health"        in guard: guard.set("health",        180.0 + tier * 90.0)
		if "move_speed"    in guard: guard.set("move_speed",    2.2   + tier * 0.35)
		if "damage"        in guard: guard.set("damage",        12.0  + tier * 9.0)
		if "gold_reward"   in guard: guard.set("gold_reward",   15    + tier * 8)

		get_tree().current_scene.add_child(guard)
		if guard is Node3D: (guard as Node3D).global_position = spawn_pos
		_patrol_units.append(guard)


func _patrol_circle(center: Vector3, radius: float, points: int) -> Array[Vector3]:
	var result : Array[Vector3] = []
	for i in points:
		var a : float = (float(i) / float(points)) * TAU
		result.append(center + Vector3(cos(a) * radius, 0.0, sin(a) * radius))
	return result


# ── Damage ────────────────────────────────────────────────────
func take_damage(amount: float, _source = null) -> void:
	if _cleared: return
	health -= amount
	if is_instance_valid(_hive_mat):
		var ratio : float = clampf(health / hive_hp, 0.0, 1.0)
		_hive_mat.albedo_color = _hive_mat.albedo_color.lerp(Color(0.9, 0.08, 0.04), (1.0 - ratio) * 0.55)
	_update_hp_display()
	if health <= 0.0:
		_on_hive_killed()


func _on_hive_killed() -> void:
	print("[Hive T%d] Hive destroyed!" % tier)
	for g in _patrol_units:
		if is_instance_valid(g) and "ai_mode" in g:
			g.set("ai_mode", ATTACK_AIMODE)
	_reveal_on_map(60.0)
	_check_cleared()


func _reveal_on_map(radius: float) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("reveal_minimap_area"):
			hud.call("reveal_minimap_area", global_position, radius)


func _on_egg_gone(egg: Node3D) -> void:
	_eggs.erase(egg)
	_check_cleared()
	if not _cleared and health > 0.0 and _eggs.size() < max_eggs:
		get_tree().create_timer(egg_spawn_interval).timeout.connect(_spawn_single_egg)


func _check_cleared() -> void:
	if _cleared: return
	if health > 0.0: return
	if not _eggs.is_empty(): return
	_cleared = true
	print("[Hive T%d] Cluster CLEARED — awarding gold" % tier)
	_award_gold()
	cluster_cleared.emit()
	get_tree().create_timer(3.0).timeout.connect(queue_free)


func _award_gold() -> void:
	var gold : int = 40 * tier
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p): continue
		if p.has_method("add_gold"):
			p.add_gold(gold)
		elif "gold" in p:
			p.set("gold", int(p.get("gold")) + gold)


# ── Hive Heart objective ─────────────────────────────────────
var _heart_node         : Node3D = null
var _heart_channeling   : bool   = false
var _heart_channel_time : float  = 0.0
const HEART_CHANNEL_DURATION : float = 20.0
const HEART_BUFF_DURATION    : float = 20.0

func _spawn_hive_heart() -> void:
	_heart_node = Node3D.new()
	_heart_node.global_position = global_position + Vector3(0.0, 1.5, 0.0)
	_heart_node.add_to_group("hive_heart")
	_heart_node.set_meta("cluster", self)

	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.55; mesh.height = 1.1
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.65, 0.0, 0.15)
	mat.emission_enabled = true
	mat.emission         = Color(1.0, 0.0, 0.2) * 0.9
	mi.material_override = mat
	_heart_node.add_child(mi)

	var lbl := Label3D.new()
	lbl.text = "❤ HIVE HEART\n[Hold F to channel]"
	lbl.font_size = 18; lbl.position.y = 1.2
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(1.0, 0.4, 0.4)
	_heart_node.add_child(lbl)

	add_child(_heart_node)


func try_channel_heart(player: Node, delta: float) -> void:
	if not is_instance_valid(_heart_node): return
	if _cleared: return
	if not (player is Node3D): return
	var dist : float = _heart_node.global_position.distance_to((player as Node3D).global_position)
	if dist > 3.5:
		_heart_channeling = false
		_heart_channel_time = 0.0
		return

	_heart_channeling    = true
	_heart_channel_time += delta

	# Spawn extra zombies every 4s while channeling
	if int(_heart_channel_time) % 4 == 0 and int(_heart_channel_time) > 0:
		_spawn_extra_zombies(2)

	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			var pct := _heart_channel_time / HEART_CHANNEL_DURATION
			if int(pct * 10) % 3 == 0:
				hud.show_message("⚡ Channeling hive heart… %.0f%%" % (pct * 100.0), Color(1.0, 0.7, 0.1))

	if _heart_channel_time >= HEART_CHANNEL_DURATION:
		_activate_heart_buff(player)
		_heart_node.queue_free()
		_heart_node = null


func _activate_heart_buff(player: Node) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("🔥 INFINITE AMMO for 20 seconds!", Color(1.0, 0.85, 0.1))
	# Grant infinite ammo buff to player
	if player.has_method("apply_upgrade"):
		player.set_meta("infinite_ammo", true)
		get_tree().create_timer(HEART_BUFF_DURATION).timeout.connect(func():
			if is_instance_valid(player): player.set_meta("infinite_ammo", false)
			for hud2 in get_tree().get_nodes_in_group("hud"):
				if hud2.has_method("show_message"): hud2.show_message("Infinite ammo expired.", Color(0.7, 0.7, 0.7)))
	print("[HiveCluster] Hive Heart channeled — infinite ammo buff granted")


func _spawn_extra_zombies(count: int) -> void:
	if not ResourceLoader.exists("res://zombie/zombie.tscn"): return
	var packed : PackedScene = load("res://zombie/zombie.tscn")
	for _i in count:
		var z := packed.instantiate()
		if "team_id" in z: z.set("team_id", 2)
		if "enemy_base" in z and is_instance_valid(attack_target):
			z.set("enemy_base", attack_target)
		get_tree().current_scene.add_child(z)
		if z is Node3D:
			(z as Node3D).global_position = global_position + Vector3(randf_range(-4,4), 0.5, randf_range(-4,4))
