# ============================================================
# HiveNode.gd
# ============================================================
# Attach to any Node3D in the scene to make it a hive spawner.
#
# Setup:
#   1. Place a Node3D (or use an existing mesh node) in the scene.
#   2. Attach this script.
#   3. Set hive_tier (1 / 2 / 3) in the Inspector.
#   4. Optional: add HiveEgg.gd children manually, or let
#      egg_count > 0 auto-build them in _ready().
#   5. Hives start INACTIVE. The tier manager in game_phase_script
#      calls activate() when this tier becomes live.
#
# Signals:
#   hive_died(hive)  — emitted just before queue_free()
# ============================================================
extends Node3D

# ── Inspector knobs ──────────────────────────────────────────
@export var hive_tier       : int   = 1     # 1 = first active tier, 2, 3 = later
@export var max_health      : float = 400.0
@export var team_id         : int   = 2     # enemy team
@export var spawn_interval  : float = 30.0  # seconds between auto-pulses
@export var units_per_spawn : int   = 3     # enemies per pulse
@export var egg_count       : int   = 4     # procedural eggs (0 = use manual children)
@export var egg_spacing     : float = 2.2   # radius for procedural egg ring

signal hive_died(hive: Node3D)

# ── State ────────────────────────────────────────────────────
var health    : float = 0.0
var is_active : bool  = false
var is_dead   : bool  = false

var _spawn_timer : float = 0.0
var _eggs        : Array = []

# Visual mesh so hive is visible without art assets
var _mesh_inst   : MeshInstance3D = null
var _pulse_t     : float = 0.0


# ── Lifecycle ────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("hive_clusters")
	health = max_health
	_build_visual()
	if egg_count > 0:
		_build_eggs()
	else:
		# Collect manually-placed HiveEgg children
		for child in get_children():
			if child.get_script() != null and child.has_method("take_damage"):
				_eggs.append(child)
	set_process(false)   # dormant until activate() is called


func _process(delta: float) -> void:
	if not is_active or is_dead:
		return
	# Pulse visual
	_pulse_t += delta
	if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
		var glow := 0.35 + 0.15 * sin(_pulse_t * 2.5)
		(_mesh_inst.material_override as StandardMaterial3D).emission = Color(0.6, 0.05, 0.0) * glow

	# Auto-spawn wave
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = spawn_interval
		_do_spawn_pulse()


# ── Public API ───────────────────────────────────────────────

func activate() -> void:
	if is_dead:
		return
	is_active    = true
	_spawn_timer = 6.0   # short initial delay before first pulse
	set_process(true)
	# Turn indicator red-orange to signal activation
	if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
		(_mesh_inst.material_override as StandardMaterial3D).albedo_color = Color(0.7, 0.12, 0.02)
	print("[HiveNode] Tier %d hive activated at %s" % [hive_tier, global_position])


func deactivate() -> void:
	is_active = false
	set_process(false)


func take_damage(amount: float, _source = null) -> void:
	if is_dead:
		return
	health -= amount
	# Flash white on hit
	if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
		(_mesh_inst.material_override as StandardMaterial3D).albedo_color = Color(1.0, 1.0, 1.0)
		get_tree().create_timer(0.15).timeout.connect(func():
			if is_dead: return
			if is_instance_valid(_mesh_inst) and _mesh_inst.material_override is StandardMaterial3D:
				(_mesh_inst.material_override as StandardMaterial3D).albedo_color = \
					Color(0.7, 0.12, 0.02) if is_active else Color(0.15, 0.35, 0.08)
		, CONNECT_ONE_SHOT)
	if health <= 0.0:
		_die()


## Called by HiveEgg children when they crack open.
func spawn_units_at_pos(pos: Vector3, count: int) -> void:
	_zhm_spawn_at(pos, count)


## Called by game_phase_script to trigger a manual wave pulse from this hive.
func spawn_wave_pulse(count: int) -> void:
	_zhm_spawn_at(global_position, count)


func get_tier() -> int:
	return hive_tier


# ── Internals ────────────────────────────────────────────────

func _do_spawn_pulse() -> void:
	if not is_active or is_dead:
		return
	_zhm_spawn_at(global_position, units_per_spawn)
	_vfx_pulse()


func _zhm_spawn_at(pos: Vector3, count: int) -> void:
	if count <= 0:
		return
	if Engine.has_singleton("ZombieHordeManager"):
		var zhm = Engine.get_singleton("ZombieHordeManager")
		if zhm.has_method("spawn_horde"):
			# Tight 2 × 2 area — units burst out right at the hive position
			var area := AABB(pos - Vector3(1.0, 0.0, 1.0), Vector3(2.0, 2.0, 2.0))
			zhm.spawn_horde(count, area)
			return

	# No ZombieHordeManager — nothing else to fall back to.
	push_warning("[HiveNode] ZombieHordeManager not found; cannot spawn %d units at %s" % [count, pos])


func _die() -> void:
	if is_dead:
		return
	is_dead   = true
	is_active = false
	health    = 0.0
	set_process(false)

	# Destroy remaining eggs
	for egg in _eggs:
		if is_instance_valid(egg):
			egg.queue_free()
	_eggs.clear()

	hive_died.emit(self)
	_vfx_death()

	get_tree().create_timer(0.6).timeout.connect(queue_free, CONNECT_ONE_SHOT)


func _on_egg_removed(egg: Node) -> void:
	_eggs.erase(egg)


# ── Visual builders ──────────────────────────────────────────

func _build_visual() -> void:
	# Chunky irregular cluster — three overlapping cylinders
	_mesh_inst = MeshInstance3D.new()
	var cyl    := CylinderMesh.new()
	cyl.top_radius    = 1.0
	cyl.bottom_radius = 1.3
	cyl.height        = 2.2
	cyl.radial_segments = 6
	_mesh_inst.mesh = cyl

	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.15, 0.35, 0.08)   # dark moss-green when dormant
	mat.emission_enabled = true
	mat.emission         = Color(0.02, 0.15, 0.01)
	mat.roughness        = 0.85
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_mesh_inst.material_override = mat
	add_child(_mesh_inst)
	_mesh_inst.position = Vector3.UP * 1.1


func _build_eggs() -> void:
	var egg_script = load("res://scripts/HiveEgg.gd")
	if not egg_script:
		push_warning("[HiveNode] Could not load res://scripts/HiveEgg.gd — skipping egg build")
		return
	for i in egg_count:
		var angle  := (float(i) / float(egg_count)) * TAU
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * egg_spacing

		var egg_node := Node3D.new()
		egg_node.name = "Egg%d" % i
		egg_node.set_script(egg_script)
		egg_node.position = offset
		add_child(egg_node)
		_eggs.append(egg_node)
		# Notify us when egg frees itself
		egg_node.tree_exiting.connect(_on_egg_removed.bind(egg_node), CONNECT_ONE_SHOT)


# ── VFX (no dependency on player.gd) ─────────────────────────

func _vfx_pulse() -> void:
	var ring := MeshInstance3D.new()
	var tor  := TorusMesh.new()
	tor.inner_radius  = 0.2
	tor.outer_radius  = 1.2
	tor.rings         = 8
	tor.ring_segments = 12
	ring.mesh = tor
	var mat := StandardMaterial3D.new()
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color     = Color(0.9, 0.2, 0.0, 0.85)
	mat.emission_enabled = true
	mat.emission         = Color(0.9, 0.15, 0.0)
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	add_child(ring)
	ring.global_position = global_position + Vector3.UP * 0.3

	var tw := create_tween()
	tw.tween_property(ring, "scale", Vector3(5.0, 5.0, 5.0), 0.5)
	tw.parallel().tween_property(mat, "albedo_color", Color(0.9, 0.2, 0.0, 0.0), 0.5)
	tw.tween_callback(ring.queue_free)


func _vfx_death() -> void:
	# Larger death burst ring
	var ring := MeshInstance3D.new()
	var tor  := TorusMesh.new()
	tor.inner_radius  = 0.3
	tor.outer_radius  = 1.6
	tor.rings         = 10
	tor.ring_segments = 16
	ring.mesh = tor
	var mat := StandardMaterial3D.new()
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color     = Color(1.0, 0.5, 0.0, 1.0)
	mat.emission_enabled = true
	mat.emission         = Color(1.0, 0.4, 0.0)
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	var parent = get_parent()
	if is_instance_valid(parent):
		parent.add_child(ring)
		ring.global_position = global_position + Vector3.UP * 0.5
		var tw := parent.create_tween()
		tw.tween_property(ring, "scale", Vector3(8.0, 8.0, 8.0), 0.7)
		tw.parallel().tween_property(mat, "albedo_color", Color(1.0, 0.5, 0.0, 0.0), 0.7)
		tw.tween_callback(ring.queue_free)
