# ============================================================
# RocketProjectile.gd — Fixed for Minion system
# ============================================================
extends Node3D
class_name RocketProjectile

@export var explosion_radius : float = 6.5
@export var explosion_damage : float = 90.0
@export var knockback_force  : float = 28.0
@export var lifetime         : float = 6.0

@export_group("Travel")
@export var speed        : float = 45.0
@export var gravity_scale: float = 3.8
@export var max_speed    : float = 55.0

@export_group("Damage Falloff")
@export var min_falloff      : float = 0.1
@export var falloff_exp      : float = 2.0
@export var direct_hit_bonus : float = 1.6

@export_group("Self Damage")
@export var self_damage_multiplier   : float = 0.4
@export var self_knockback_multiplier: float = 1.0

@export_group("Collision")
@export_flags_3d_physics var hit_mask: int = 0xFFFFFFFF  # all layers

@export_group("Visuals")
@export var rocket_texture: Texture2D = null

@export_group("Audio")
@export var fly_stream      : AudioStream = null
@export var explosion_stream: AudioStream = null

var velocity : Vector3 = Vector3.ZERO
var shooter  : Node    = null

var _exploded : bool = false
var _last_pos : Vector3

var _mesh       : MeshInstance3D
var _fly_audio  : AudioStreamPlayer3D
var _boom_audio : AudioStreamPlayer3D

# Pending init params (set before add_child)
var _init_origin  : Vector3 = Vector3.ZERO
var _init_dir     : Vector3 = Vector3.FORWARD
var _init_pending : bool    = false

func _ready() -> void:
	set_physics_process(false)
	if _init_pending: _apply_init()

func init(origin: Vector3, dir: Vector3, p_shooter: Node,
		dmg: float = -1.0, radius: float = -1.0, knockback: float = -1.0) -> void:
	shooter = p_shooter
	if dmg      > 0.0: explosion_damage = dmg
	if radius   > 0.0: explosion_radius = radius
	if knockback > 0.0: knockback_force  = knockback
	_init_origin  = origin
	_init_dir     = dir.normalized()
	_init_pending = true
	if is_inside_tree(): _apply_init()

func _apply_init() -> void:
	_init_pending   = false
	global_position = _init_origin
	_last_pos       = _init_origin
	velocity        = _init_dir * speed
	_build_visuals()
	_build_audio()
	if is_instance_valid(_fly_audio) and fly_stream: _fly_audio.play()
	get_tree().create_timer(lifetime).timeout.connect(_on_timeout)
	set_physics_process(true)

func _build_visuals() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04; cyl.bottom_radius = 0.08; cyl.height = 0.6
	_mesh.mesh = cyl
	_mesh.rotation_degrees.x = 90.0
	var mat := StandardMaterial3D.new()
	if rocket_texture: mat.albedo_texture = rocket_texture
	else: mat.albedo_color = Color(0.8, 0.4, 0.1)
	_mesh.material_override = mat
	add_child(_mesh)

	# Smoke + fire trail
	var trail := GPUParticles3D.new()
	trail.amount = 24; trail.lifetime = 0.55
	trail.local_coords = false; trail.emitting = true; trail.fixed_fps = 0
	var tpm := ParticleProcessMaterial.new()
	tpm.direction = Vector3(0, 0, 1); tpm.spread = 10.0
	tpm.initial_velocity_min = 1.5; tpm.initial_velocity_max = 4.0
	tpm.scale_min = 0.1; tpm.scale_max = 0.28
	var tg := Gradient.new()
	tg.add_point(0.0, Color(1.0, 0.6, 0.1, 1.0))
	tg.add_point(0.3, Color(0.5, 0.5, 0.5, 0.7))
	tg.add_point(1.0, Color(0.2, 0.2, 0.2, 0.0))
	var tgt := GradientTexture1D.new(); tgt.gradient = tg; tpm.color_ramp = tgt
	var tq := QuadMesh.new(); tq.size = Vector2(0.22, 0.22)
	var tmat := StandardMaterial3D.new()
	tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	tq.material = tmat; trail.draw_pass_1 = tq; trail.process_material = tpm
	add_child(trail)

func _physics_process(delta: float) -> void:
	if _exploded: return
	velocity.y -= gravity_scale * 9.8 * delta
	if velocity.length() > max_speed: velocity = velocity.normalized() * max_speed
	var next_pos := global_position + velocity * delta
	var space    := get_world_3d().direct_space_state
	var ray      := PhysicsRayQueryParameters3D.create(_last_pos, next_pos)
	ray.collide_with_bodies = true; ray.collide_with_areas = true
	ray.collision_mask = hit_mask
	if is_instance_valid(shooter): ray.exclude = _get_shooter_rids(shooter)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		global_position = hit.position; explode(); return
	global_position = next_pos; _last_pos = global_position; _orient()

func _orient() -> void:
	if velocity.length_squared() < 0.01: return
	var dir := velocity.normalized()
	var up  := Vector3.UP if abs(dir.dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
	look_at(global_position + dir, up)

func explode() -> void:
	# REAL BUG FIX: this guard used to sit AFTER the VFX/screenshake calls
	# below, so a second call to explode() (currently not reachable given
	# both real call sites already guard before calling, but fragile if a
	# future call site doesn't) would re-fire explosion VFX/screen shake a
	# second time even though damage/queue_free correctly only ran once.
	if _exploded: return
	_exploded = true
	var ie := get_tree().get_first_node_in_group("impact_effects")
	if is_instance_valid(ie) and ie.has_method("spawn_explosion"): ie.spawn_explosion(global_position, explosion_radius)
	var ss := get_tree().get_first_node_in_group("screen_shake")
	if is_instance_valid(ss) and ss.has_method("explosion"): ss.explosion()
	var pp := get_tree().get_first_node_in_group("post_processing")
	if is_instance_valid(pp) and pp.has_method("pulse_bloom"): pp.pulse_bloom(1.2, 0.25)
	set_physics_process(false)
	if is_instance_valid(_mesh): _mesh.visible = false
	if is_instance_valid(_fly_audio): _fly_audio.stop()
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		_apply_damage()
	_play_explosion_sound()
	queue_free()

func _on_timeout() -> void:
	if not _exploded: explode()

func _apply_damage() -> void:
	var space := get_world_3d().direct_space_state
	var shape        := SphereShape3D.new()
	shape.radius     = explosion_radius
	var query                  := PhysicsShapeQueryParameters3D.new()
	query.shape                = shape
	query.transform            = global_transform
	query.collide_with_bodies  = true
	query.collide_with_areas   = true
	query.collision_mask       = hit_mask
	var hit_map : Dictionary = {}
	for result in space.intersect_shape(query):
		var target := _resolve_damageable(result.collider)
		if not is_instance_valid(target) or hit_map.has(target): continue
		hit_map[target] = true

	# Group sweep fallback — catches minions/players missed by physics query
	for group in ["units", "minions", "player", "turrets"]:
		for unit in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(unit) or not unit.has_method("take_damage"): continue
			if hit_map.has(unit): continue
			if (unit as Node3D).global_position.distance_to(global_position) <= explosion_radius:
				hit_map[unit] = true

	for target in hit_map:
		if _is_self(target):     _deal_self_damage(target)
		elif _is_friendly(target): pass
		else:                      _deal_damage(target)

func _deal_damage(target: Node) -> void:
	var dist    : float = global_position.distance_to((target as Node3D).global_position)
	var falloff : float = _calc_falloff(dist)
	target.take_damage(explosion_damage * falloff, shooter)
	if is_instance_valid(shooter) and shooter.has_method("cancel_invisibility"): shooter.cancel_invisibility()
	_apply_knockback(target, falloff, knockback_force)

func _deal_self_damage(target: Node) -> void:
	if self_damage_multiplier <= 0.0 and self_knockback_multiplier <= 0.0: return
	var dist    : float = global_position.distance_to((target as Node3D).global_position)
	var falloff : float = _calc_falloff(dist)
	if self_damage_multiplier > 0.0:
		target.take_damage(explosion_damage * falloff * self_damage_multiplier, null)
	_apply_knockback(target, falloff, knockback_force * self_knockback_multiplier)

func _calc_falloff(dist: float) -> float:
	if dist <= 0.1: return minf(direct_hit_bonus, 1.0)
	var t : float = clampf(dist / explosion_radius, 0.0, 1.0)
	var f : float = clampf(pow(1.0 - t, falloff_exp), min_falloff, 1.0)
	if dist < explosion_radius * 0.15: f = minf(f * direct_hit_bonus, 1.0)
	return f

func _apply_knockback(target: Node, falloff: float, force: float) -> void:
	if not (target is CharacterBody3D): return
	var body := target as CharacterBody3D
	var dir  := (body.global_position - global_position).normalized()
	dir.y = clampf(dir.y + 0.6, 0.2, 1.0); dir = dir.normalized()
	body.velocity += dir * force * falloff

func _resolve_damageable(node: Node) -> Node:
	var current := node
	while is_instance_valid(current):
		if current.has_method("take_damage"): return current
		current = current.get_parent()
	return null

func _is_self(node: Node) -> bool:
	if not is_instance_valid(shooter): return false
	var current := node
	while is_instance_valid(current):
		if current == shooter: return true
		current = current.get_parent()
	return false

func _is_friendly(node: Node) -> bool:
	var s := _get_team_id(shooter); var t := _get_team_id(node)
	return s != -1 and t != -1 and s == t

func _get_team_id(node: Node) -> int:
	var current := node
	while is_instance_valid(current):
		if "team_id" in current: return int(current.get("team_id"))
		current = current.get_parent()
	return -1

func _get_shooter_rids(root: Node) -> Array[RID]:
	var rids : Array[RID] = []
	var current := root
	while is_instance_valid(current):
		if current is CollisionObject3D:
			rids.append((current as CollisionObject3D).get_rid())
		current = current.get_parent()
	return rids

func _build_audio() -> void:
	_fly_audio  = _make_audio_player(fly_stream,       -6.0, 60.0)
	_boom_audio = _make_audio_player(explosion_stream, -2.0, 80.0)

func _make_audio_player(stream: AudioStream, vol_db: float, max_dist: float) -> AudioStreamPlayer3D:
	if not stream: return null
	var p := AudioStreamPlayer3D.new()
	p.stream = stream; p.volume_db = vol_db; p.max_distance = max_dist
	add_child(p); return p

func _play_explosion_sound() -> void:
	if not is_instance_valid(_boom_audio): return
	var p := _boom_audio; remove_child(p); get_tree().root.add_child(p)
	p.global_position = global_position; p.play()
	get_tree().create_timer(3.0).timeout.connect(
		func(): if is_instance_valid(p): p.queue_free())
