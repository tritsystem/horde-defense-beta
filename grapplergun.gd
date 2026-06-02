# ============================================================
# GrapplerGun.gd — Just Cause 2 style grapple
# X = take out/put away
# LMB = fire / zip to surface (auto-pulls like JC2)
# RMB = release while attached
# While zipping: move keys add swing force
# On reach: instant re-fire available for chaining
# 30s cooldown after release
# ============================================================
extends Node3D

@export var rope_length     : float = 35.0
@export var zip_speed       : float = 22.0
@export var zip_accel       : float = 5.0
@export var swing_force     : float = 14.0
@export var active_window   : float = 10.0  # seconds grapple stays active after first fire
@export var cooldown_time   : float = 45.0  # cooldown after window expires
@export var arc_segments    : int   = 32

var player  : CharacterBody3D = null
var camera  : Camera3D        = null

enum State { IDLE, ZIPPING, ATTACHED, CLINGING }
var _state          : State   = State.IDLE
var _hook_pos       : Vector3 = Vector3.ZERO
var _rope_len       : float   = 0.0
var _cooldown       : float   = 0.0
var _zip_vel        : Vector3 = Vector3.ZERO
var _window_active  : bool    = false   # 10s active window
var _window_timer   : float   = 0.0    # counts down from active_window

# Rope visuals
var _rope_mesh  : ImmediateMesh  = null
var _rope_inst  : MeshInstance3D = null
var _hook_node  : Node3D         = null
var _arc_mesh   : ImmediateMesh  = null
var _arc_inst   : MeshInstance3D = null
var _sfx        : AudioStreamPlayer3D = null

signal cooldown_updated(remaining: float, total: float)
signal grapple_state_changed(state_name: String)


func _ready() -> void:
	_build_gun_model()
	_build_rope()
	_build_arc()
	_sfx = AudioStreamPlayer3D.new(); _sfx.max_distance = 40.0; add_child(_sfx)
	set_physics_process(false)


func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera = cam; player = ply
	# Position in hand
	position = Vector3(0.18, -0.12, -0.32)
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	# Active window countdown
	if _window_active:
		_window_timer -= delta
		if _window_timer <= 0.0:
			_window_active = false
			_window_timer  = 0.0
			_cooldown      = cooldown_time
			_force_release()
			if is_instance_valid(player):
				player._show_message("🪝 Grapple expired — %.0fs cooldown" % cooldown_time, Color(1.0, 0.5, 0.2))
		else:
			cooldown_updated.emit(_window_timer, active_window)

	# Cooldown tick (after window expires)
	elif _cooldown > 0.0:
		_cooldown = maxf(0.0, _cooldown - delta)
		cooldown_updated.emit(_cooldown, cooldown_time)
		if _cooldown <= 0.0 and is_instance_valid(player):
			player._show_message("🪝 Grapple READY", Color(0.3, 1.0, 0.5))

	if not is_instance_valid(player): return

	match _state:
		State.ZIPPING:  _tick_zip(delta)
		State.ATTACHED: _tick_attached(delta)
		State.CLINGING: _tick_cling(delta)

	_update_rope()
	_update_arc()

	# Glow ring reflects cooldown
	var ring := get_node_or_null("CooldownRing") as MeshInstance3D
	if is_instance_valid(ring):
		var mat := ring.material_override as StandardMaterial3D
		if is_instance_valid(mat):
			var ratio : float
			if _window_active:
				ratio = _window_timer / active_window  # green draining
				mat.emission = Color(0.3, 0.9, 0.5) * ratio + Color(0.9, 0.8, 0.1) * (1.0 - ratio)
			elif _cooldown > 0.0:
				ratio = 1.0 - _cooldown / cooldown_time
				mat.emission = Color(0.8, 0.2, 0.1) * (1.0 - ratio) + Color(0.3, 0.9, 0.5) * ratio
			else:
				mat.emission = Color(0.3, 0.9, 0.5)  # full green = ready
			mat.emission_energy_multiplier = 3.0 + ratio * 3.0


func fire() -> void:
	if _cooldown > 0.0:
		player._show_message("🪝 %.0fs cooldown" % _cooldown, Color(1.0, 0.5, 0.2))
		return
	if not is_instance_valid(camera) or not is_instance_valid(player): return
	# Start active window on first fire
	if not _window_active:
		_window_active = true
		_window_timer  = active_window
	# Always allow re-fire during window — detach current hook first
	if _state != State.IDLE: _detach_hook()

	var from  : Vector3 = player.global_position + Vector3.UP * 1.2
	var dir   : Vector3 = -camera.global_transform.basis.z

	# Raycast toward aim
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * rope_length)
	query.collision_mask = 0xFFFFFFFF
	# Exclude player
	var rids : Array[RID] = []
	var pn   : Node = player
	while is_instance_valid(pn):
		if pn is CollisionObject3D: rids.append((pn as CollisionObject3D).get_rid())
		pn = pn.get_parent()
	query.exclude = rids

	var hit := space.intersect_ray(query)
	if hit.is_empty():
		player._show_message("🪝 Nothing in range", Color(0.8, 0.4, 0.2))
		return

	_hook_pos = hit.position
	_rope_len = player.global_position.distance_to(_hook_pos)
	_state    = State.ZIPPING
	# Initial zip velocity — launch toward hook
	_zip_vel  = ((_hook_pos - player.global_position).normalized()) * zip_speed * 0.5
	if is_instance_valid(_hook_node): _hook_node.visible = true
	grapple_state_changed.emit("zipping")


func release() -> void:
	# RMB = reset current hook, keep window active for re-fire
	if _state == State.IDLE: return
	_detach_hook()
	if is_instance_valid(player):
		player.velocity.y = maxf(player.velocity.y, 3.0)

func _detach_hook() -> void:
	_state   = State.IDLE
	_zip_vel = Vector3.ZERO
	if is_instance_valid(_hook_node): _hook_node.visible = false
	grapple_state_changed.emit("idle")

func _force_release() -> void:
	# Window expired — full release with cooldown
	_detach_hook()
	if is_instance_valid(_rope_inst): _rope_inst.visible = false
	if is_instance_valid(_arc_inst):  _arc_inst.visible  = false
	cooldown_updated.emit(_cooldown, cooldown_time)


func _tick_zip(delta: float) -> void:
	var to_hook : Vector3 = _hook_pos - player.global_position
	var dist    : float   = to_hook.length()

	if dist < 1.2:
		# Reached hook — transition to attached/cling
		_state = State.ATTACHED
		player.velocity = player.velocity * 0.4  # bleed off speed
		grapple_state_changed.emit("attached")
		return

	# JC2 feel: accelerate hard toward hook, preserve lateral momentum
	var toward_hook : Vector3 = to_hook.normalized()

	# Strong pull toward hook
	_zip_vel += toward_hook * zip_accel * delta * 60.0

	# Cap zip speed
	if _zip_vel.length() > zip_speed:
		_zip_vel = _zip_vel.normalized() * zip_speed

	# Apply to player — override gravity while zipping
	player.velocity = _zip_vel
	player.velocity.y = _zip_vel.y  # allow vertical zipping
	player.move_and_slide()
	_zip_vel = player.velocity

	# Add swing input for strafing mid-zip (JC2 sideways movement)
	var sw : float = 0.0
	if Input.is_key_pressed(KEY_D): sw += 1.0
	if Input.is_key_pressed(KEY_A): sw -= 1.0
	if sw != 0.0:
		var side : Vector3 = toward_hook.cross(Vector3.UP).normalized()
		player.velocity += side * sw * swing_force * 0.4 * delta


func _tick_attached(delta: float) -> void:
	# Swinging from attachment point — JC2 pendulum
	var to_hook  : Vector3 = _hook_pos - player.global_position
	var dist     : float   = to_hook.length()
	var rope_dir : Vector3 = to_hook.normalized()

	# Gravity
	player.velocity.y -= 16.0 * delta

	# WASD adds swing force
	var sw_x : float = 0.0
	var sw_z : float = 0.0
	if Input.is_key_pressed(KEY_D): sw_x += 1.0
	if Input.is_key_pressed(KEY_A): sw_x -= 1.0
	if Input.is_key_pressed(KEY_W): sw_z += 1.0
	if Input.is_key_pressed(KEY_S): sw_z -= 1.0

	if sw_x != 0.0 or sw_z != 0.0:
		var right   : Vector3 = rope_dir.cross(Vector3.UP).normalized()
		var forward : Vector3 = Vector3.UP.cross(right).normalized()
		player.velocity += (right * sw_x + forward * sw_z) * swing_force * delta

	# Rope constraint
	player.move_and_slide()
	var new_to : Vector3 = _hook_pos - player.global_position
	if new_to.length() > _rope_len:
		player.global_position = _hook_pos - new_to.normalized() * _rope_len
		# Remove velocity component going away from hook
		var away := player.velocity.dot(-new_to.normalized())
		if away > 0: player.velocity -= -new_to.normalized() * away * 0.85

	# Floor bounce
	if player.is_on_floor() and player.velocity.y < 0.0:
		player.velocity.y = 3.0


func _tick_cling(delta: float) -> void:
	player.velocity.x = move_toward(player.velocity.x, 0.0, 15.0 * delta)
	player.velocity.z = move_toward(player.velocity.z, 0.0, 15.0 * delta)
	player.velocity.y = maxf(player.velocity.y - 2.0 * delta, -2.0)
	player.move_and_slide()


func _update_rope() -> void:
	if not is_instance_valid(_rope_inst) or not is_instance_valid(player): return
	_rope_inst.visible = (_state != State.IDLE)
	if _state == State.IDLE: return
	var from : Vector3 = player.global_position + Vector3.UP * 1.0
	_rope_mesh.clear_surfaces()
	_rope_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_rope_mesh.surface_set_color(Color(0.85, 0.72, 0.4))
	_rope_mesh.surface_add_vertex(from)
	_rope_mesh.surface_set_color(Color(0.65, 0.52, 0.3))
	_rope_mesh.surface_add_vertex(_hook_pos)
	_rope_mesh.surface_end()
	if is_instance_valid(_hook_node):
		_hook_node.global_position = _hook_pos
		_hook_node.visible = true


func _update_arc() -> void:
	if not is_instance_valid(_arc_inst) or not is_instance_valid(camera): return
	_arc_inst.visible = (visible and _state == State.IDLE and _cooldown <= 0.0)
	if not _arc_inst.visible: return

	var from  : Vector3 = player.global_position + Vector3.UP * 1.2
	var dir   : Vector3 = -camera.global_transform.basis.z
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * rope_length)
	query.collision_mask = 0xFFFFFFFF
	var rids : Array[RID] = []
	var pn : Node = player
	while is_instance_valid(pn):
		if pn is CollisionObject3D: rids.append((pn as CollisionObject3D).get_rid())
		pn = pn.get_parent()
	query.exclude = rids
	var hit := space.intersect_ray(query)
	var end_pos : Vector3 = hit.position if not hit.is_empty() else from + dir * rope_length
	var col : Color = Color(0.3, 1.0, 0.5, 0.9) if not hit.is_empty() else Color(1.0, 0.4, 0.2, 0.5)

	_arc_mesh.clear_surfaces()
	_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in arc_segments:
		if i % 2 != 0: continue  # dashed
		_arc_mesh.surface_set_color(col)
		_arc_mesh.surface_add_vertex(from.lerp(end_pos, float(i) / arc_segments))
		_arc_mesh.surface_set_color(col * Color(1,1,1,0.3))
		_arc_mesh.surface_add_vertex(from.lerp(end_pos, float(i+1) / arc_segments))
	_arc_mesh.surface_end()

	if not hit.is_empty():
		_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for i in 8:
			var a1 := float(i) / 8.0 * TAU; var a2 := float(i+1) / 8.0 * TAU
			_arc_mesh.surface_set_color(Color(0.3, 1.0, 0.5, 0.9))
			_arc_mesh.surface_add_vertex(end_pos + Vector3(cos(a1)*0.4, 0, sin(a1)*0.4))
			_arc_mesh.surface_add_vertex(end_pos + Vector3(cos(a2)*0.4, 0, sin(a2)*0.4))
		_arc_mesh.surface_end()


func _build_gun_model() -> void:
	var body := MeshInstance3D.new(); body.name = "Body"
	var bm   := BoxMesh.new(); bm.size = Vector3(0.06, 0.10, 0.24)
	body.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.15, 0.16, 0.18)
	bmat.metallic = 0.9; bmat.roughness = 0.2
	bmat.clearcoat = 1.0; bmat.clearcoat_roughness = 0.1
	body.material_override = bmat
	body.position = Vector3(0, 0, 0)
	add_child(body)

	var barrel := MeshInstance3D.new()
	var cyl    := CylinderMesh.new()
	cyl.top_radius = 0.016; cyl.bottom_radius = 0.020; cyl.height = 0.20
	barrel.mesh = cyl
	var barmat := StandardMaterial3D.new()
	barmat.albedo_color = Color(0.1, 0.1, 0.12)
	barmat.metallic = 0.95; barmat.roughness = 0.12
	barrel.material_override = barmat
	barrel.rotation_degrees.x = 90
	barrel.position = Vector3(0, 0, -0.22)
	add_child(barrel)

	var spool := MeshInstance3D.new()
	var scyl  := CylinderMesh.new()
	scyl.top_radius = 0.024; scyl.bottom_radius = 0.024; scyl.height = 0.065
	spool.mesh = scyl
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.52, 0.40, 0.16)
	smat.metallic = 0.65; smat.roughness = 0.4
	spool.material_override = smat
	spool.rotation_degrees.z = 90
	spool.position = Vector3(0.065, 0, -0.08)
	add_child(spool)

	var grip := MeshInstance3D.new()
	var gm   := BoxMesh.new(); gm.size = Vector3(0.05, 0.13, 0.06)
	grip.mesh = gm; grip.material_override = bmat
	grip.rotation_degrees.x = 12
	grip.position = Vector3(0, -0.11, -0.04)
	add_child(grip)

	# Glowing hook tip
	var tip  := MeshInstance3D.new()
	var tsph := SphereMesh.new(); tsph.radius = 0.018; tsph.height = 0.036
	tip.mesh = tsph
	var tmat := StandardMaterial3D.new()
	tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tmat.albedo_color = Color(0.25, 0.95, 0.45)
	tmat.emission_enabled = true; tmat.emission = Color(0.25, 0.95, 0.45)
	tmat.emission_energy_multiplier = 5.0
	tip.material_override = tmat
	tip.position = Vector3(0, 0, -0.33)
	add_child(tip)

	var ring    := MeshInstance3D.new()
	ring.name   = "CooldownRing"
	var rm      := TorusMesh.new(); rm.inner_radius = 0.018; rm.outer_radius = 0.024
	ring.mesh   = rm
	var rmat    := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.albedo_color = Color(0.3, 0.9, 0.5)
	rmat.emission_enabled = true; rmat.emission = Color(0.3, 0.9, 0.5)
	rmat.emission_energy_multiplier = 4.0
	ring.material_override = rmat
	ring.rotation_degrees.x = 90
	ring.position = Vector3(0, 0, -0.18)
	add_child(ring)


func _build_rope() -> void:
	_rope_mesh = ImmediateMesh.new()
	_rope_inst = MeshInstance3D.new()
	_rope_inst.mesh = _rope_mesh
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.albedo_color = Color(0.8, 0.65, 0.35)
	rmat.vertex_color_use_as_albedo = true
	_rope_inst.material_override = rmat
	_rope_inst.visible = false
	_rope_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(_rope_inst)

	_hook_node = Node3D.new(); _hook_node.visible = false
	var hm := MeshInstance3D.new()
	var hs := SphereMesh.new(); hs.radius = 0.07; hs.height = 0.14
	hm.mesh = hs
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.7, 0.55, 0.2)
	hmat.metallic = 0.9; hmat.roughness = 0.15
	hm.material_override = hmat
	_hook_node.add_child(hm)
	get_tree().root.add_child(_hook_node)


func _build_arc() -> void:
	_arc_mesh = ImmediateMesh.new()
	_arc_inst = MeshInstance3D.new()
	_arc_inst.mesh = _arc_mesh
	var amat := StandardMaterial3D.new()
	amat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	amat.vertex_color_use_as_albedo = true
	amat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_arc_inst.material_override = amat
	_arc_inst.visible = false
	_arc_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(_arc_inst)


func _exit_tree() -> void:
	if is_instance_valid(_rope_inst): _rope_inst.queue_free()
	if is_instance_valid(_hook_node): _hook_node.queue_free()
	if is_instance_valid(_arc_inst):  _arc_inst.queue_free()
