# ============================================================
# Flamethrower.gd
# ============================================================
extends Node3D
class_name Flamethrower

@export var max_ammo                  : int   = 120
@export var fire_rate                 : float = 0.15
@export var reload_time               : float = 2.0
@export var damage                    : float = 25.0
@export var recoil                    : float = 2.0
@export var projectile_scene          : PackedScene = null

@export_group("Viewmodel")
@export var vm_position : Vector3 = Vector3(0.3, -0.25, -0.5)
@export var vm_rotation : Vector3 = Vector3(0.0, 180.0, 0.0)
@export var vm_scale    : Vector3 = Vector3.ONE
@export var vm_kick     : float   = 0.25
@export_group("")

@export var shoot_sound               : AudioStream = null
@export var shoot_volume_db           : float = 0.0
@export var shoot_pitch_scale         : float = 1.0
@export var shoot_pitch_randomness    : float = 0.0
@export var shoot_volume_randomness   : float = 0.0

@export var reload_sound              : AudioStream = null
@export var reload_volume_db          : float = 0.0
@export var reload_pitch_scale        : float = 1.0
@export var reload_pitch_randomness   : float = 0.0
@export var reload_volume_randomness  : float = 0.0

var current_ammo : int                  = 0
var reloading    : bool                 = false
var cooldown     : bool                 = false
var camera       : Camera3D             = null
var player       : CharacterBody3D      = null
var audio_player : AudioStreamPlayer3D  = null

signal ammo_changed(current: int, maximum: int)

@export var flame_scene     : PackedScene = null
@export var cone_angle      : float = 8.0    # tight stream, not wide cone
@export var tick_rate       : float = 0.08   # slower tick = less ammo per second
@export var ray_count       : int   = 3      # fewer rays = less ammo drain
@export var damage_per_tick : float = 6.0
@export var range           : float = 10.0

@export_group("Audio")
@export var loop_stream   : AudioStream = null
@export var ignite_stream : AudioStream = null

# Ammo drains 1 per tick, tick_rate=0.08 → ~12 ticks/sec → 120 ammo = ~10 seconds of fire
# Hold mouse to fire continuously, release to stop

var _firing      : bool  = false
var _tick_timer  : float = 0.0
var _loop_player : AudioStreamPlayer3D = null
var _pool        : Array = []
const _POOL_SIZE : int   = 12


func _ready() -> void:
	_loop_player = AudioStreamPlayer3D.new()
	_loop_player.max_distance = 20.0
	_loop_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
	add_child(_loop_player)
	if not is_instance_valid(loop_stream):
		for p in ["res://audio/flamethrower_loop.ogg","res://sounds/flamethrower_loop.ogg",
				"res://audio/fire_loop.ogg","res://sounds/fire_loop.ogg",
				"res://audio/flamethrower_loop.wav","res://sounds/fire_loop.wav"]:
			if ResourceLoader.exists(p): loop_stream = load(p); break
	if not is_instance_valid(ignite_stream):
		for p in ["res://audio/flamethrower_start.ogg","res://sounds/flamethrower_start.ogg",
				"res://audio/fire_start.ogg","res://audio/flamethrower_start.wav"]:
			if ResourceLoader.exists(p): ignite_stream = load(p); break
	if not is_instance_valid(flame_scene):
		for path in ["res://scenes/FlameProjectile.tscn",
				"res://scenes/weapons/FlameProjectile.tscn",
				"res://weapons/FlameProjectile.tscn",
				"res://FlameProjectile.tscn"]:
			if ResourceLoader.exists(path):
				flame_scene = load(path)
				break
	for _i in _POOL_SIZE: _pool.append(_make_particle())


func unequip() -> void:
	visible = false
	camera  = null
	player  = null
	_stop_firing()
	if is_instance_valid(audio_player) and audio_player.playing:
		audio_player.stop()

func reload() -> void:
	if reloading or current_ammo == max_ammo: return
	reloading = true
	_play_sound(reload_sound, reload_volume_db, reload_pitch_scale,
				reload_pitch_randomness, reload_volume_randomness)
	get_tree().create_timer(reload_time).timeout.connect(
		_on_reload_finished, CONNECT_ONE_SHOT)

func _on_reload_finished() -> void:
	current_ammo = max_ammo
	reloading    = false
	ammo_changed.emit(current_ammo, max_ammo)

func get_ammo() -> int: return current_ammo

func _play_sound(sound: AudioStream, vol: float, pitch: float,
				pr: float, vr: float) -> void:
	if not is_instance_valid(audio_player) or not sound: return
	audio_player.pitch_scale = pitch + randf_range(-pr, pr)
	audio_player.volume_db   = vol   + randf_range(-vr, vr)
	audio_player.stream      = sound
	audio_player.play()

func apply_player_upgrade(stat: String, amount: float) -> void:
	match stat:
		"damage":       damage_per_tick += amount
		"fire_rate":    tick_rate  = maxf(tick_rate  - amount * 0.005, 0.04)
		"reload_speed": reload_time = maxf(reload_time - amount, 0.5)

func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera    = cam
	player    = ply
	visible   = true
	reloading = false
	cooldown  = false
	if current_ammo <= 0: current_ammo = max_ammo
	set_process(true)

# ── shoot() is called every frame while held — _process gates by tick_rate ──
func shoot() -> void:
	if reloading or current_ammo <= 0: return
	if not _firing:
		_firing = true
		_start_fire_sound()

func stop_shoot() -> void:
	_stop_firing()

func _stop_firing() -> void:
	if not _firing: return
	_firing     = false
	_tick_timer = 0.0
	_stop_fire_sound()

func _process(delta: float) -> void:
	if not _firing: return
	_tick_timer += delta
	if _tick_timer < tick_rate: return
	_tick_timer -= tick_rate   # subtract not zero — keeps fractional time
	_fire_tick()


func _fire_tick() -> void:
	if not is_instance_valid(camera):
		push_warning("[Flamethrower] _fire_tick: camera is null — was equip() called?")
		_stop_firing(); return
	if current_ammo <= 0:
		_stop_firing()
		reload()
		return

	var b       : Basis   = camera.global_transform.basis
	var forward : Vector3 = -b.z
	var right   : Vector3 = b.x
	var up_vec  : Vector3 = b.y

	# Gun barrel origin — forward enough to never clip into screen
	var origin : Vector3 = camera.global_position \
		+ forward * 0.9 \
		+ right   * 0.18 \
		+ up_vec  * -0.14

	var is_auth := multiplayer.is_server() or not multiplayer.has_multiplayer_peer()
	var space   := get_world_3d().direct_space_state

	var excl : Array[RID] = []
	if is_instance_valid(player):
		var pn := player as Node
		while is_instance_valid(pn):
			if pn is CollisionObject3D:
				excl.append((pn as CollisionObject3D).get_rid())
			pn = pn.get_parent()

	for _i in ray_count:
		var dir : Vector3 = _cone_dir(forward, right, up_vec)

		# Damage ray from camera center (true crosshair)
		var q := PhysicsRayQueryParameters3D.create(
			camera.global_position,
			camera.global_position + dir * range)
		q.collision_mask = 0xFFFFFFFF
		q.exclude        = excl
		var hit := space.intersect_ray(q)

		if not hit.is_empty() and is_auth:
			var tgt := _resolve(hit.collider)
			if is_instance_valid(tgt) and not _friendly(tgt):
				tgt.take_damage(damage_per_tick, player)
				for h in get_tree().get_nodes_in_group("hud"):
					if h.has_method("show_hitmarker"):
						h.show_hitmarker(false); break
		elif not hit.is_empty() and is_instance_valid(player):
			# Non-host networked client: relay to the server (see
			# CombatRelay.gd / basegun.gd's identical pattern) instead of
			# resolving damage locally.
			var tgt_b := _resolve(hit.collider)
			if is_instance_valid(tgt_b) and not _friendly(tgt_b):
				for h in get_tree().get_nodes_in_group("hud"):
					if h.has_method("show_hitmarker"):
						h.show_hitmarker(false); break
				CombatRelay.request_hit.rpc_id(1, player.get_path(), tgt_b.get_path(), get_path(),
												hit.position, hit.normal, "")

		# Visual flame from barrel to hit point or max range
		var end_pos   : Vector3 = hit.position if not hit.is_empty() \
			else camera.global_position + dir * range
		var flame_vel : Vector3 = (end_pos - origin).normalized() * 8.0
		_spawn_flame(origin, flame_vel)

	# Drain 1 ammo per tick regardless of ray_count
	current_ammo -= 1
	ammo_changed.emit(current_ammo, max_ammo)


func _spawn_flame(origin: Vector3, vel: Vector3) -> void:
	if is_instance_valid(flame_scene):
		var flame := flame_scene.instantiate()
		get_tree().current_scene.add_child(flame)
		if flame.has_method("init"):
			var tid : int = int(player.get("team_id")) \
				if is_instance_valid(player) and "team_id" in player else -1
			flame.init(origin, vel, player, tid)
		else:
			flame.global_position = origin
			if "velocity" in flame: flame.velocity = vel
		return

	# Procedural fallback
	var p : GPUParticles3D = _get_pooled()
	if not is_instance_valid(p): return
	p.global_position = origin
	if vel.length_squared() > 0.01:
		var up := Vector3.UP if abs(vel.normalized().dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
		p.look_at(origin + vel.normalized(), up)
	if p.process_material is ParticleProcessMaterial:
		var pm := p.process_material as ParticleProcessMaterial
		pm.initial_velocity_min = 5.0
		pm.initial_velocity_max = 8.0
	p.emitting = true
	get_tree().current_scene.add_child(p)
	get_tree().create_timer(p.lifetime + 0.1).timeout.connect(func():
		if is_instance_valid(p):
			p.emitting = false
			if p.get_parent(): p.get_parent().remove_child(p)
			_pool.append(p))


func _get_pooled() -> GPUParticles3D:
	for p in _pool:
		if is_instance_valid(p) and not p.emitting:
			_pool.erase(p)
			return p as GPUParticles3D
	return _make_particle()


func _make_particle() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount       = 4          # tiny burst per tick
	p.lifetime     = 0.25
	p.one_shot     = true
	p.emitting     = false
	p.local_coords = false

	var pm := ParticleProcessMaterial.new()
	pm.direction            = Vector3(0, 0, -1)
	pm.spread               = 8.0               # tight stream
	pm.initial_velocity_min = 5.0
	pm.initial_velocity_max = 8.0
	pm.gravity              = Vector3(0, 0.8, 0)
	pm.scale_min            = 0.01              # 3x smaller than before
	pm.scale_max            = 0.025

	var grad := Gradient.new()
	grad.add_point(0.00, Color(1.0, 0.9, 0.3, 0.9))
	grad.add_point(0.35, Color(1.0, 0.4, 0.05, 0.7))
	grad.add_point(0.70, Color(0.3, 0.2, 0.1, 0.3))
	grad.add_point(1.00, Color(0.1, 0.1, 0.1, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp      = gt
	p.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.02, 0.02)   # 3x smaller than before (was 0.06)

	var mat := StandardMaterial3D.new()
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
	mat.depth_draw_mode            = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_color               = Color(1.0, 0.5, 0.1, 0.8)
	mat.emission_enabled           = true
	mat.emission                   = Color(1.0, 0.35, 0.0)
	mat.emission_energy_multiplier = 1.5
	quad.material = mat
	p.draw_pass_1 = quad
	return p


func _cone_dir(forward: Vector3, right: Vector3, up: Vector3) -> Vector3:
	var yaw   := deg_to_rad(randf_range(-cone_angle, cone_angle))
	var pitch := deg_to_rad(randf_range(-cone_angle * 0.5, cone_angle * 0.5))
	return (forward.rotated(up, yaw).rotated(right, pitch)).normalized()


func _resolve(node: Node) -> Node:
	var cur := node
	while is_instance_valid(cur):
		if cur.has_method("take_damage"): return cur
		cur = cur.get_parent()
	return null


func _friendly(target: Node) -> bool:
	if not is_instance_valid(player): return false
	var pt : int = int(player.get("team_id") if "team_id" in player else -1)
	var cur := target
	while is_instance_valid(cur):
		if "team_id" in cur: return int(cur.get("team_id")) == pt
		cur = cur.get_parent()
	return false


func _start_fire_sound() -> void:
	if not is_instance_valid(_loop_player): return
	if is_instance_valid(ignite_stream):
		_loop_player.stream      = ignite_stream
		_loop_player.volume_db   = shoot_volume_db
		_loop_player.pitch_scale = 1.0
		_loop_player.play()
		var ilen : float = ignite_stream.get_length() \
			if ignite_stream.has_method("get_length") else 0.3
		get_tree().create_timer(ilen).timeout.connect(func():
			if not _firing or not is_instance_valid(_loop_player): return
			if not is_instance_valid(loop_stream): return
			_loop_player.stream    = loop_stream
			_loop_player.volume_db = shoot_volume_db - 2.0
			_loop_player.play())
	elif is_instance_valid(loop_stream):
		_loop_player.stream    = loop_stream
		_loop_player.volume_db = shoot_volume_db - 2.0
		_loop_player.play()


func _stop_fire_sound() -> void:
	if not is_instance_valid(_loop_player) or not _loop_player.playing: return
	var tw := create_tween()
	tw.tween_property(_loop_player, "volume_db", -80.0, 0.15)
	tw.tween_callback(_loop_player.stop)
	tw.tween_callback(func():
		if is_instance_valid(_loop_player):
			_loop_player.volume_db = shoot_volume_db)
