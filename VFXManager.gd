# ============================================================
# VFXManager.gd — AUTOLOAD
# ============================================================
# Cinematic GPU-based VFX: explosions, blood, trails, shockwaves.
# Register as Autoload: VFXManager
# ============================================================
extends Node

const MAX_POOL_SIZE : int = 64
var _particle_pool  : Array = []


var _splitscreen : bool = false
var _active_fx   : int  = 0
const MAX_ACTIVE_FX : int = 12   # hard cap on concurrent particle systems

func _ready() -> void:
	add_to_group("vfx_manager")
	var gs := get_node_or_null("/root/GameSettings")
	_splitscreen = int(gs.get("player_count") if is_instance_valid(gs) and "player_count" in gs else 1) > 1


# ── PUBLIC API ───────────────────────────────────────────────

func explosion(pos: Vector3, scale: float = 1.0, col: Color = Color(1.0, 0.55, 0.1)) -> void:
	if _active_fx >= MAX_ACTIVE_FX: return
	if _splitscreen:
		# Lightweight explosion for splitscreen
		_gpu_burst(pos, col, 30, scale * 10.0, 0.9)
		_shockwave_ring(pos, col, scale * 7.0, 0.4)
		_spawn_light(pos, col * Color(2,1.5,1), scale * 14.0, 0.4)
		return
	_gpu_burst(pos, col, 120, scale * 12.0, 1.4)
	_gpu_burst(pos, Color(1.0, 1.0, 0.6), 40, scale * 6.0, 0.6)
	_shockwave_ring(pos, col, scale * 9.0, 0.5)
	_debris_burst(pos, scale)
	_spawn_light(pos, col * Color(2,1.5,1), scale * 18.0, 0.6)
	_smoke_plume(pos, scale)


func blood_spray(pos: Vector3, direction: Vector3 = Vector3.UP, amount: float = 1.0) -> void:
	var col := Color(0.75, 0.05, 0.05)
	_gpu_burst(pos + direction * 0.3, col, int(30 * amount), 3.5, 0.9)
	_gpu_burst(pos, Color(0.5, 0.02, 0.02, 0.6), int(15 * amount), 1.8, 1.4)


func magic_burst(pos: Vector3, col: Color, scale: float = 1.0) -> void:
	_gpu_burst(pos, col, 80, scale * 8.0, 1.0)
	_gpu_burst(pos, Color(1,1,1,0.9), 20, scale * 3.0, 0.4)
	_shockwave_ring(pos, col, scale * 7.0, 0.6)
	_spawn_light(pos, col, scale * 14.0, 0.8)
	_mana_sparks(pos, col, scale)


func death_burst(pos: Vector3, col: Color = Color(0.8, 0.1, 0.1)) -> void:
	if _splitscreen:
		_spawn_light(pos, col, 5.0, 0.2)
		return
	blood_spray(pos, Vector3.UP, 1.8)
	_gpu_burst(pos + Vector3.UP * 0.5, col, 50, 5.0, 1.2)
	_spawn_light(pos, col, 8.0, 0.35)


func flame_trail(pos: Vector3, velocity: Vector3) -> void:
	_gpu_burst(pos, Color(1.0, 0.4, 0.05), 8, velocity.length() * 0.4, 0.25)
	_spawn_light(pos, Color(1.0, 0.5, 0.1), 3.0, 0.15)


func lightning_strike(from: Vector3, to: Vector3) -> void:
	_gpu_beam(from, to, Color(0.5, 0.85, 1.0))
	_spawn_light(to, Color(0.4, 0.8, 1.0), 12.0, 0.3)
	_gpu_burst(to, Color(0.6, 0.9, 1.0), 40, 5.0, 0.5)


func heal_burst(pos: Vector3) -> void:
	_gpu_burst(pos + Vector3.UP * 0.5, Color(0.2, 1.0, 0.4), 60, 4.0, 1.2)
	_rising_sparks(pos, Color(0.3, 1.0, 0.5))
	_spawn_light(pos, Color(0.1, 1.0, 0.3), 10.0, 0.8)


func level_up(pos: Vector3) -> void:
	_gpu_burst(pos + Vector3.UP, Color(1.0, 0.9, 0.1), 100, 8.0, 1.5)
	_shockwave_ring(pos, Color(1.0, 0.85, 0.1), 6.0, 0.8)
	_rising_sparks(pos, Color(1.0, 1.0, 0.4))
	_spawn_light(pos, Color(1.0, 0.9, 0.1), 16.0, 1.2)


func void_tear(pos: Vector3, radius: float = 5.0) -> void:
	_gpu_burst(pos, Color(0.3, 0.0, 0.6), 80, radius, 1.2)
	_gpu_burst(pos, Color(0.8, 0.3, 1.0, 0.6), 30, radius * 0.5, 0.6)
	_shockwave_ring(pos, Color(0.5, 0.1, 0.9), radius, 0.7)
	_spawn_light(pos, Color(0.4, 0.0, 0.8), radius * 2.5, 0.9)


# ── INTERNAL BUILDERS ────────────────────────────────────────

func _gpu_burst(pos: Vector3, col: Color, count: int, speed: float, lifetime: float) -> void:
	if _active_fx >= MAX_ACTIVE_FX: return
	_active_fx += 1
	var p := GPUParticles3D.new()
	p.amount          = count if not _splitscreen else maxi(count / 3, 6)
	p.lifetime        = lifetime
	p.one_shot        = true
	p.explosiveness   = 0.92
	p.randomness      = 0.4
	p.visibility_aabb = AABB(Vector3(-20,-20,-20), Vector3(40,40,40))

	var mat := ParticleProcessMaterial.new()
	mat.direction          = Vector3(0, 1, 0)
	mat.spread             = 180.0
	mat.initial_velocity_min = speed * 0.4
	mat.initial_velocity_max = speed * 1.0
	mat.gravity            = Vector3(0, -6.0, 0)
	mat.scale_min          = 0.06
	mat.scale_max          = 0.22
	mat.color              = col
	# Fade out over lifetime
	var grad := Gradient.new()
	grad.colors     = PackedColorArray([col, Color(col.r, col.g, col.b, 0.0)])
	grad.offsets    = PackedFloat32Array([0.0, 1.0])
	var gtex        := GradientTexture1D.new()
	gtex.gradient   = grad
	mat.color_ramp  = gtex
	p.process_material = mat

	var mesh := SphereMesh.new()
	mesh.radius = 0.06; mesh.height = 0.12
	var mmesh := p.draw_pass_1
	p.draw_pass_1 = mesh
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color     = col
	mmat.emission_enabled = true
	mmat.emission         = col * 2.5
	mmat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material         = mmat
	p.position = pos
	get_tree().current_scene.add_child(p)
	p.restart()
	get_tree().create_timer(lifetime + 0.3).timeout.connect(func(): _active_fx -= 1; p.queue_free(), CONNECT_ONE_SHOT)


func _shockwave_ring(pos: Vector3, col: Color, radius: float, duration: float) -> void:
	var mi   := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.05; mesh.outer_radius = 0.2; mesh.rings = 8; mesh.ring_segments = 32
	mi.mesh  = mesh
	var mat  := StandardMaterial3D.new()
	mat.albedo_color     = Color(col.r, col.g, col.b, 0.85)
	mat.emission_enabled = true
	mat.emission         = col * 3.0
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test    = false
	mi.material_override = mat
	mi.position          = pos + Vector3.UP * 0.2
	get_tree().current_scene.add_child(mi)
	var tw := mi.create_tween().set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(radius, 0.05, radius), duration).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration * 0.7).set_delay(duration * 0.3)
	tw.chain().tween_callback(mi.queue_free)


func _spawn_light(pos: Vector3, col: Color, radius: float, duration: float) -> void:
	var light := OmniLight3D.new()
	light.position          = pos + Vector3.UP * 0.5
	light.light_color       = col
	light.omni_range        = radius
	light.light_energy      = 8.0
	light.shadow_enabled    = false
	get_tree().current_scene.add_child(light)
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, duration).set_trans(Tween.TRANS_EXPO)
	tw.tween_callback(light.queue_free)


func _debris_burst(pos: Vector3, scale: float) -> void:
	var count : int = int(12 * scale)
	for _i in mini(count, 20):
		var mi   := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		var s    := randf_range(0.04, 0.14) * scale
		mesh.size = Vector3(s, s, s)
		mi.mesh   = mesh
		var mat   := StandardMaterial3D.new()
		mat.albedo_color = Color(0.3, 0.25, 0.2)
		mat.roughness    = 0.85
		mi.material_override = mat
		mi.position = pos + Vector3(randf_range(-0.3,0.3), 0.2, randf_range(-0.3,0.3))
		get_tree().current_scene.add_child(mi)
		var vel  := Vector3(randf_range(-1,1), randf_range(0.5,1.5), randf_range(-1,1)).normalized() * randf_range(3.0, 8.0) * scale
		var tw   := mi.create_tween()
		var end  := mi.position + vel * 0.8
		end.y    = maxf(pos.y, mi.position.y - 0.2)
		tw.tween_property(mi, "position", end, 0.7).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(mi, "scale", Vector3.ZERO, 0.3)
		tw.tween_callback(mi.queue_free)


func _smoke_plume(pos: Vector3, scale: float) -> void:
	var p := GPUParticles3D.new()
	p.amount       = int(20 * scale)
	p.lifetime     = 2.5
	p.one_shot     = true
	p.explosiveness = 0.3
	p.randomness   = 0.8
	var mat := ParticleProcessMaterial.new()
	mat.direction            = Vector3(0, 1, 0)
	mat.spread               = 25.0
	mat.initial_velocity_min = 1.5 * scale
	mat.initial_velocity_max = 3.5 * scale
	mat.gravity              = Vector3(0, 0.3, 0)
	mat.scale_min            = 0.5 * scale
	mat.scale_max            = 2.0 * scale
	mat.color                = Color(0.18, 0.16, 0.14, 0.55)
	p.process_material = mat
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.6, 0.6) * scale
	var smat := StandardMaterial3D.new()
	smat.albedo_color        = Color(0.15, 0.13, 0.11, 0.5)
	smat.transparency        = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode        = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.billboard_mode      = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material            = smat
	p.draw_pass_1 = mesh
	p.position    = pos + Vector3.UP * 0.3
	get_tree().current_scene.add_child(p)
	p.restart()
	get_tree().create_timer(3.5).timeout.connect(p.queue_free, CONNECT_ONE_SHOT)


func _mana_sparks(pos: Vector3, col: Color, scale: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = int(40 * scale); p.lifetime = 1.2; p.one_shot = true; p.explosiveness = 0.7
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0,1,0); mat.spread = 120.0
	mat.initial_velocity_min = 2.0; mat.initial_velocity_max = 5.0 * scale
	mat.gravity = Vector3(0, 2.0, 0)
	mat.scale_min = 0.03; mat.scale_max = 0.09
	mat.color = col
	p.process_material = mat
	var mesh := SphereMesh.new(); mesh.radius = 0.04; mesh.height = 0.08
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color = col; mmat.emission_enabled = true; mmat.emission = col * 4.0
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mmat
	p.draw_pass_1 = mesh; p.position = pos
	get_tree().current_scene.add_child(p); p.restart()
	get_tree().create_timer(1.8).timeout.connect(p.queue_free, CONNECT_ONE_SHOT)


func _rising_sparks(pos: Vector3, col: Color) -> void:
	var p := GPUParticles3D.new()
	p.amount = 30; p.lifetime = 1.8; p.one_shot = true; p.explosiveness = 0.2
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0,1,0); mat.spread = 15.0
	mat.initial_velocity_min = 2.0; mat.initial_velocity_max = 5.0
	mat.gravity = Vector3(0, 0.5, 0)
	mat.scale_min = 0.02; mat.scale_max = 0.06; mat.color = col
	p.process_material = mat
	var mesh := SphereMesh.new(); mesh.radius = 0.03; mesh.height = 0.06
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color = col; mmat.emission_enabled = true; mmat.emission = col * 5.0
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mmat
	p.draw_pass_1 = mesh; p.position = pos + Vector3.UP * 0.2
	get_tree().current_scene.add_child(p); p.restart()
	get_tree().create_timer(2.5).timeout.connect(p.queue_free, CONNECT_ONE_SHOT)


func _gpu_beam(from: Vector3, to: Vector3, col: Color) -> void:
	var dist := from.distance_to(to)
	if dist < 0.1: return
	var mid  := from.lerp(to, 0.5)
	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.height = dist; mesh.top_radius = 0.04; mesh.bottom_radius = 0.04
	mesh.radial_segments = 8
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col; mat.emission_enabled = true; mat.emission = col * 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.position = mid
	mi.look_at(to, Vector3.UP)
	mi.rotation.x += PI * 0.5
	get_tree().current_scene.add_child(mi)
	var tw := mi.create_tween().set_parallel(true)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.4)
	tw.tween_property(mi, "scale:x", 3.0, 0.15)
	tw.chain().tween_property(mi, "scale:x", 0.0, 0.2)
	tw.chain().tween_callback(mi.queue_free)
