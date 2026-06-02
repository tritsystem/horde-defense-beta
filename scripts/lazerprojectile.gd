# ============================================================
# LaserBolt.gd — Fixed collision mask + team_id
# ============================================================
extends Node3D

@export var speed: float = 85.0
@export var lifetime: float = 2.5
@export var damage: float = 25.0

@export_group("Visuals")
@export var color: Color = Color(1.0, 0.25, 0.1)
@export var glow_intensity: float = 8.0

@export_group("Audio")
@export var fly_stream: AudioStream = null
@export var impact_stream: AudioStream = null
@export var fly_volume_db: float = -8.0
@export var impact_volume_db: float = -3.0

var velocity: Vector3 = Vector3.ZERO
var shooter: Node = null

var _dead: bool = false
var _time: float = 0.0
var _mesh: MeshInstance3D
var _trail: GPUParticles3D
var _fly_player: AudioStreamPlayer3D
var _impact_player: AudioStreamPlayer3D

var _init_pending : bool    = false
var _init_origin  : Vector3 = Vector3.ZERO
var _init_dir     : Vector3 = Vector3.FORWARD

func init(origin: Vector3, dir: Vector3, new_shooter: Node, dmg: float = -1.0) -> void:
	shooter = new_shooter
	if dmg > 0.0: damage = dmg
	_init_origin  = origin
	_init_dir     = dir.normalized()
	_init_pending = true
	if is_inside_tree(): _apply_init()

func _apply_init() -> void:
	_init_pending   = false
	global_position = _init_origin
	velocity        = _init_dir * speed

func _ready() -> void:
	_build_visuals()
	_build_audio()
	if _init_pending: _apply_init()
	if is_instance_valid(_fly_player) and fly_stream: _fly_player.play()
	get_tree().create_timer(lifetime).timeout.connect(_die.bind(false))

func _physics_process(delta: float) -> void:
	if _dead: return
	_time += delta
	var from := global_position
	var side := velocity.cross(Vector3.UP).normalized()
	global_position += velocity * delta + side * sin(_time * 45.0) * 0.018
	_orient_to_velocity()
	_check_collision(from, global_position)

func _orient_to_velocity() -> void:
	if velocity.length_squared() < 0.01: return
	var up := Vector3.UP if abs(velocity.normalized().dot(Vector3.UP)) < 0.96 else Vector3.FORWARD
	look_at(global_position + velocity.normalized(), up)

func _check_collision(from: Vector3, to: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFFFFFF  # all layers

	if is_instance_valid(shooter):
		var rids : Array[RID] = []
		var node := shooter
		while is_instance_valid(node):
			if node is CollisionObject3D: rids.append((node as CollisionObject3D).get_rid())
			node = node.get_parent()
		if not rids.is_empty(): query.exclude = rids

	var hit := space.intersect_ray(query)
	if hit.is_empty(): return

	var target := _resolve_damageable(hit.collider)
	if target == null or _is_friendly(target): return

	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		var dmg : float = damage
		if is_instance_valid(shooter) and shooter.has_method("get_damage_multiplier"):
			dmg *= shooter.get_damage_multiplier()
		# Headshot — hit point above target center
		var is_headshot : bool = false
		if target is Node3D:
			if hit.position.y >= (target as Node3D).global_position.y + 1.25:
				dmg *= 2.0; is_headshot = true
		target.take_damage(dmg, shooter)
		if is_instance_valid(shooter) and shooter.has_method("cancel_invisibility"): shooter.cancel_invisibility()
		# Hitmarker + damage number
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("show_hitmarker"): h.show_hitmarker(is_headshot); break
		var _etp2 : int = int(shooter.get("enchantment")) if is_instance_valid(shooter) and "enchantment" in shooter else 0
		var _dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(_dn) and _dn.has_method("spawn_number"):
			_dn.spawn_number(dmg, (target as Node3D).global_position + Vector3(0,1.8,0), _etp2, is_headshot)

	_die(true)

func _resolve_damageable(node: Node) -> Node:
	var current := node
	while is_instance_valid(current):
		if current.has_method("take_damage"): return current
		current = current.get_parent()
	return null

func _is_friendly(target: Node) -> bool:
	if not is_instance_valid(shooter): return false
	var s_team := _get_team_id(shooter)
	var t_team := _get_team_id(target)
	return s_team != -1 and t_team != -1 and s_team == t_team

func _get_team_id(node: Node) -> int:
	var current := node
	while is_instance_valid(current):
		if "team_id" in current: return int(current.get("team_id"))
		current = current.get_parent()
	return -1

func _die(was_hit: bool) -> void:
	if _dead: return
	_dead = true
	set_physics_process(false)
	if is_instance_valid(_mesh): _mesh.visible = false
	if is_instance_valid(_trail): _trail.emitting = false
	_play_impact_sound(was_hit)
	_detach_fly_sound()
	queue_free()

func _build_audio() -> void:
	_fly_player    = _make_audio_player(fly_stream,    fly_volume_db,    45.0)
	_impact_player = _make_audio_player(impact_stream, impact_volume_db, 50.0)

func _make_audio_player(stream: AudioStream, vol_db: float, max_dist: float) -> AudioStreamPlayer3D:
	if not stream: return null
	var p := AudioStreamPlayer3D.new()
	p.stream = stream; p.volume_db = vol_db; p.max_distance = max_dist
	p.attenuation_filter_cutoff_hz = 7000
	add_child(p); return p

func _detach_fly_sound() -> void:
	if not is_instance_valid(_fly_player): return
	var p := _fly_player; remove_child(p); get_tree().root.add_child(p)
	p.global_position = global_position
	get_tree().create_timer(2.0).timeout.connect(func(): if is_instance_valid(p): p.queue_free())

func _play_impact_sound(was_hit: bool) -> void:
	if not was_hit or not is_instance_valid(_impact_player) or not impact_stream: return
	var p := _impact_player; remove_child(p); get_tree().root.add_child(p)
	p.global_position = global_position; p.play()
	get_tree().create_timer(1.5).timeout.connect(func(): if is_instance_valid(p): p.queue_free())

func _build_visuals() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.025; cyl.bottom_radius = 0.035; cyl.height = 1.1
	_mesh.mesh = cyl; _mesh.rotation_degrees.x = 90.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true; mat.emission = color
	mat.emission_energy_multiplier = glow_intensity
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.95)
	_mesh.material_override = mat; add_child(_mesh)

	_trail = GPUParticles3D.new()
	_trail.amount = 15; _trail.lifetime = 0.18
	_trail.local_coords = false; _trail.emitting = true
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 0.0, -1.0); pm.spread = 4.0
	pm.initial_velocity_min = 0.5; pm.initial_velocity_max = 2.0
	pm.scale_min = 0.03; pm.scale_max = 0.08; pm.color = color
	var grad := Gradient.new()
	grad.set_color(0, color); grad.set_color(1, Color(color.r, color.g, color.b, 0.0))
	var grad_tex := GradientTexture1D.new(); grad_tex.gradient = grad
	pm.color_ramp = grad_tex; _trail.process_material = pm
	var quad := QuadMesh.new(); quad.size = Vector2(0.08, 0.4)
	_trail.draw_pass_1 = quad; add_child(_trail)
