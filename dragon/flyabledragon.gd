# ============================================================
# FlyableDragon.gd — Flyable wyvern/dragon mount
# Place as Node3D in scene. Player walks near and presses E.
# Controls while mounted:
#   W/S = pitch nose up/down
#   A/D = bank/yaw left/right
#   Space = flap / gain altitude
#   Shift = dive / speed boost
#   E = dismount (ejects player upward)
#   LMB = dragon fire breath
# ============================================================
extends Node3D

@export_group("Custom Model")
@export var dragon_glb       : PackedScene = null  # drag your dragon .glb here
@export var animation_idle   : String = "Idle"
@export var animation_fly    : String = "Fly"
@export var animation_attack : String = "Attack"
@export var model_scale      : Vector3 = Vector3(1.0, 1.0, 1.0)
@export var mount_offset     : Vector3 = Vector3(0.0, 1.5, 0.8)   # rider seat — positive Z = behind head

@export_group("Flight")
@export var fly_speed        : float = 28.0
@export var boost_speed      : float = 52.0
@export var turn_speed       : float = 1.8
@export var pitch_speed      : float = 1.4
@export var gravity_scale    : float = 6.0
@export var flap_impulse     : float = 4.5
@export var mount_range      : float = 4.0
@export var fire_damage      : float = 35.0
@export var fire_range       : float = 18.0
@export var fire_cooldown    : float = 1.2

var _rider         : Node3D  = null
var _is_mounted    : bool    = false
var _velocity      : Vector3 = Vector3.ZERO
var _pitch         : float   = 0.0   # current pitch angle
var _yaw           : float   = 0.0
var _fire_timer    : float   = 0.0
var _mouse_yaw     : float   = 0.0
var _mouse_pitch   : float   = 0.0
@export var mouse_sensitivity : float = 0.2

# Bomb targeting
var _target_pos    : Vector3 = Vector3.ZERO   # world position of bomb target
var _target_valid  : bool    = false
var _target_cursor : MeshInstance3D = null    # ground reticle indicator
var _target_offset : Vector2 = Vector2.ZERO   # mouse offset from center for aiming
var _flap_timer    : float   = 0.0
var _wing_phase    : float   = 0.0

# Body parts (procedural)
var _glb_instance  : Node3D  = null   # custom GLB root
var _anim_player   : AnimationPlayer = null
var _body      : MeshInstance3D
var _neck      : MeshInstance3D
var _head      : MeshInstance3D
var _wing_l    : MeshInstance3D
var _wing_r    : MeshInstance3D
var _tail      : MeshInstance3D
var _eye_l     : MeshInstance3D
var _eye_r     : MeshInstance3D
var _fire_light    : OmniLight3D
var _crosshair_ui  : CanvasLayer = null
var _pred_arc      : MeshInstance3D = null
var _pred_arc_mesh : ImmediateMesh  = null
var _mount_label: Label3D

# Mount point for rider
var _mount_point : Node3D


func _ready() -> void:
	add_to_group("dragon")
	_build_model()
	_build_mount_label()
	set_physics_process(false)
	set_process(true)


func _process(delta: float) -> void:
	_wing_phase += delta * (3.5 if _is_mounted else 1.2)
	_animate_wings()
	_fire_timer = maxf(0.0, _fire_timer - delta)
	if _is_mounted: _update_prediction_arc()

	if not _is_mounted:
		# Idle hover bob
		position.y += sin(_wing_phase * 0.5) * 0.005
		# Check for nearby player
		_check_mount_prompt()


func _physics_process(delta: float) -> void:
	if not _is_mounted or not is_instance_valid(_rider): return
	_handle_flight(delta)
	_sync_rider()


func _check_mount_prompt() -> void:
	if not is_instance_valid(_mount_label): return
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node3D): continue
		var d : float = global_position.distance_to((p as Node3D).global_position)
		_mount_label.visible = d < mount_range * 2.0
		return
	_mount_label.visible = false


func _handle_flight(delta: float) -> void:
	var input_pitch : float = 0.0
	var input_yaw   : float = 0.0
	var boosting    : bool  = Input.is_key_pressed(KEY_SHIFT)
	var flapping    : bool  = Input.is_action_just_pressed("jump") or Input.is_key_pressed(KEY_SPACE)

	if Input.is_key_pressed(KEY_W): input_pitch =  1.0
	if Input.is_key_pressed(KEY_S): input_pitch = -1.0
	if Input.is_key_pressed(KEY_A): input_yaw   =  1.0
	if Input.is_key_pressed(KEY_D): input_yaw   = -1.0

	# Mouse steers the nose — keyboard adds extra fine control
	_mouse_yaw   += input_yaw   * turn_speed  * delta * 0.6
	_mouse_pitch += input_pitch * pitch_speed * delta * 0.6
	_mouse_pitch  = clampf(_mouse_pitch, -0.65, 0.65)
	_yaw   = _mouse_yaw
	_pitch = _mouse_pitch

	# Apply rotation — smooth lerp for fluid feel
	rotation.y = lerp_angle(rotation.y, _yaw,   12.0 * delta)
	rotation.x = lerp(rotation.x, -_pitch,      10.0 * delta)
	rotation.z = lerp(rotation.z, -input_yaw * 0.45, 8.0 * delta)  # banking

	# Thrust
	var speed  : float = boost_speed if boosting else fly_speed
	var fwd    : Vector3 = -global_transform.basis.z
	_velocity  += fwd * speed * delta * 2.0
	_velocity  *= 0.92  # drag

	# Flap — cap vertical so spamming doesn't rocket
	if flapping:
		_velocity.y = minf(_velocity.y + flap_impulse, flap_impulse * 1.2)
		_wing_phase  = 0.0

	# Gravity (reduced when flying fast)
	var grav_mod : float = clampf(1.0 - _velocity.length() / boost_speed, 0.2, 1.0)
	_velocity.y -= gravity_scale * grav_mod * delta

	global_position += _velocity * delta

	# Ground clamp
	if global_position.y < 3.0:
		global_position.y = 3.0
		if _velocity.y < 0.0: _velocity.y = 0.0

	# Fire timer countdown (firing handled in _input via LMB event)


func _breathe_fire() -> void:
	# If no raycast target, synthesize one straight ahead and below
	if not _target_valid:
		var fwd : Vector3 = -global_transform.basis.z
		var aim : Vector3 = global_position + fwd * 40.0 + Vector3(0, -20.0, 0)
		_target_pos   = aim
		_target_valid = true
	# Flash light
	if is_instance_valid(_fire_light):
		_fire_light.light_energy = 10.0
		create_tween().tween_property(_fire_light, "light_energy", 0.5, 0.5)
	# Drop bomb at target ground position
	_drop_bomb(_target_pos)

func _drop_bomb(world_pos: Vector3) -> void:
	var origin : Vector3 = global_position  # drops from dragon position downward
	# Bomb projectile — falls with gravity to target
	var fb := MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = 0.3; sm.height = 0.6
	fb.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true; mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 8.0; mat.albedo_color = Color(1.0, 0.55, 0.1)
	fb.material_override = mat
	var core := MeshInstance3D.new()
	var csm := SphereMesh.new(); csm.radius = 0.12; csm.height = 0.24
	core.mesh = csm
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.albedo_color = Color(1.0,1.0,0.9); cmat.emission_enabled = true
	cmat.emission = Color(1.0,1.0,0.8); cmat.emission_energy_multiplier = 14.0
	core.material_override = cmat; fb.add_child(core)
	var fl := OmniLight3D.new()
	fl.light_color = Color(1.0,0.5,0.1); fl.light_energy = 5.0; fl.omni_range = 7.0
	fb.add_child(fl)
	get_tree().current_scene.add_child(fb); fb.global_position = origin
	# Calculate velocity to arc toward target
	var to_target : Vector3 = world_pos - origin
	var time : float = maxf(to_target.length() / 30.0, 0.5)
	var vel := Vector3(to_target.x / time, -to_target.y / time + 9.8 * time * 0.5, to_target.z / time)
	_step_bomb(fb, vel, 0.0, time * 1.1, world_pos)

func _step_bomb(fb: Node3D, vel: Vector3, elapsed: float, max_time: float, target: Vector3) -> void:
	if not is_instance_valid(fb): return
	var step : float = 0.033
	var grav_vel := Vector3(vel.x, vel.y - 9.8 * elapsed, vel.z)
	var new_pos : Vector3 = fb.global_position + grav_vel * step
	fb.global_position = new_pos
	fb.rotation_degrees.z += 12.0
	elapsed += step
	if elapsed >= max_time or new_pos.y <= target.y + 0.5:
		_fireball_explode(fb, new_pos); return
	get_tree().create_timer(step).timeout.connect(
		func(): _step_bomb(fb, vel, elapsed, max_time, target), CONNECT_ONE_SHOT)


func _fireball_explode(fb: Node3D, pos: Vector3) -> void:
	if not is_instance_valid(fb): return
	fb.queue_free()
	# Damage in radius
	for group in ["units","minions","player"]:
		for n in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(n) or not (n is Node3D): continue
			if n == _rider: continue
			if pos.distance_to((n as Node3D).global_position) > 4.5: continue
			if n.has_method("take_damage"): n.take_damage(fire_damage, _rider)
	# Explosion flash spheres
	for i in 8:
		var ef := MeshInstance3D.new()
		var esm := SphereMesh.new(); esm.radius = randf_range(0.3, 0.9)
		ef.mesh = esm
		var emat := StandardMaterial3D.new()
		emat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		emat.emission_enabled = true
		emat.emission = Color(1.0, randf_range(0.2,0.6), 0.05)
		emat.emission_energy_multiplier = 6.0
		ef.material_override = emat
		get_tree().current_scene.add_child(ef)
		ef.global_position = pos + Vector3(randf_range(-1,1), randf_range(0,1.5), randf_range(-1,1))
		var etw := ef.create_tween().set_parallel(true)
		etw.tween_property(ef, "scale", Vector3(2,2,2), 0.25)
		etw.tween_property(ef, "modulate:a", 0.0, 0.4)
		etw.chain().tween_callback(ef.queue_free)


func _spawn_fire_breath(from: Vector3, dir: Vector3, to: Vector3) -> void:
	var dist : float = from.distance_to(to)
	var steps : int = int(dist / 1.5)
	for i in steps:
		var t : float = float(i) / float(maxi(steps, 1))
		var pos : Vector3 = from.lerp(to, t)
		var fl := MeshInstance3D.new()
		var sm := SphereMesh.new(); sm.radius = 0.4 + t * 0.6
		fl.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.4 + t * 0.3, 0.05)
		mat.emission_energy_multiplier = 6.0
		mat.albedo_color = mat.emission
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.85 - t * 0.5
		fl.material_override = mat
		get_tree().current_scene.add_child(fl)
		fl.global_position = pos + Vector3(randf_range(-0.2,0.2), randf_range(-0.1,0.3), randf_range(-0.2,0.2))
		var tw := fl.create_tween().set_parallel(true)
		tw.tween_property(fl, "scale", Vector3.ZERO, 0.5 + t * 0.3)
		tw.tween_property(fl, "modulate:a", 0.0, 0.5)
		tw.chain().tween_callback(fl.queue_free)


func try_mount(player: Node3D) -> bool:
	if _is_mounted: return false
	if global_position.distance_to(player.global_position) > mount_range * 2.0: return false
	_rider = player
	_is_mounted = true
	_mount_label.visible = false
	_mouse_yaw   = rotation.y
	_mouse_pitch = -rotation.x
	_target_offset = Vector2.ZERO
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_play_anim(animation_fly)
	_show_dragon_crosshair(true)
	_set_hud_visible(false)
	# Disable player movement
	if player.has_method("set_movement_locked"): player.set_movement_locked(true)
	if "velocity" in player: player.set("velocity", Vector3.ZERO)
	# Reparent player to mount point — keep them seated
	set_physics_process(true)
	print("[Dragon] Mounted by %s" % player.name)
	return true


func dismount() -> void:
	if not _is_mounted or not is_instance_valid(_rider): return
	var rider := _rider
	_rider      = null
	_is_mounted = false
	set_physics_process(false)
	_play_anim(animation_idle)
	_show_dragon_crosshair(false)  # cleanup UI first
	_set_hud_visible(true)
	# Re-capture AFTER UI cleanup so CanvasLayer queue_free doesn't reset it
	get_tree().create_timer(0.05).timeout.connect(
		func(): Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED))
	if rider.has_method("set_movement_locked"): rider.set_movement_locked(false)
	# Eject rider upward and forward
	if "velocity" in rider:
		rider.set("velocity", _velocity + Vector3(0, 8.0, 0))
	rider.global_position = global_position + Vector3(0, 1.5, 0)
	print("[Dragon] Dismounted")


func _sync_rider() -> void:
	if not is_instance_valid(_rider) or not is_instance_valid(_mount_point): return
	_rider.global_position = _mount_point.global_position
	# Match dragon facing exactly — dragon forward is -Z, player forward is also -Z
	# so rotations should match directly without offset
	_rider.global_rotation  = Vector3(0.0, global_rotation.y, 0.0)


func _input(event: InputEvent) -> void:
	if not _is_mounted: return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Mouse moves targeting reticle — also slightly steers dragon
		_target_offset += mm.relative * 1.5
		# Clamp offset so reticle stays in viewport
		var vp_size := get_viewport().get_visible_rect().size
		_target_offset.x = clampf(_target_offset.x, -vp_size.x*0.45, vp_size.x*0.45)
		_target_offset.y = clampf(_target_offset.y, -vp_size.y*0.45, vp_size.y*0.45)
		# Gentle dragon steering from reticle offset
		_mouse_yaw   -= mm.relative.x * mouse_sensitivity * 0.004
		_mouse_pitch -= mm.relative.y * mouse_sensitivity * 0.003
		_mouse_pitch  = clampf(_mouse_pitch, -0.65, 0.65)
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		# LMB = fire
		if mb.button_index == MOUSE_BUTTON_LEFT and _fire_timer <= 0.0:
			_breathe_fire()
			_fire_timer = fire_cooldown
			get_viewport().set_input_as_handled()
		# Scroll = zoom (handled by player.gd; dragon also accepts it as fallback)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if is_instance_valid(_rider) and "_dragon_zoom" in _rider:
				_rider.set("_dragon_zoom", clampf(float(_rider.get("_dragon_zoom")) - 3.0, 20.0, 90.0))
				if _rider.has_method("_apply_dragon_zoom"): _rider._apply_dragon_zoom()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if is_instance_valid(_rider) and "_dragon_zoom" in _rider:
				_rider.set("_dragon_zoom", clampf(float(_rider.get("_dragon_zoom")) + 3.0, 20.0, 90.0))
				if _rider.has_method("_apply_dragon_zoom"): _rider._apply_dragon_zoom()

func _show_dragon_crosshair(show: bool) -> void:
	if show:
		# Screen-space HUD crosshair (center dot for orientation)
		if not is_instance_valid(_crosshair_ui):
			_crosshair_ui = CanvasLayer.new(); _crosshair_ui.layer = 15
			get_tree().root.add_child(_crosshair_ui)
			var ctrl := Control.new()
			ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
			ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_crosshair_ui.add_child(ctrl)
			var draw_node := _DragonCrosshair.new()
			draw_node.set_anchors_preset(Control.PRESET_FULL_RECT)
			draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
			ctrl.add_child(draw_node)
		# Ground reticle — 3D ring showing bomb target
		if not is_instance_valid(_target_cursor):
			_target_cursor = MeshInstance3D.new()
			var tm := TorusMesh.new(); tm.inner_radius = 1.2; tm.outer_radius = 1.6; tm.rings = 32; tm.ring_segments = 16
			_target_cursor.mesh = tm
			var tmat := StandardMaterial3D.new()
			tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			tmat.albedo_color = Color(1.0, 0.4, 0.05, 0.9)
			tmat.emission_enabled = true; tmat.emission = Color(1.0, 0.4, 0.05)
			tmat.emission_energy_multiplier = 4.0
			tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_target_cursor.material_override = tmat
			_target_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			get_tree().root.add_child(_target_cursor)
		# Bomb trajectory arc
		_pred_arc_mesh = ImmediateMesh.new()
		_pred_arc = MeshInstance3D.new(); _pred_arc.mesh = _pred_arc_mesh
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.vertex_color_use_as_albedo = true
		pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_pred_arc.material_override = pmat
		_pred_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(_pred_arc)
	else:
		if is_instance_valid(_crosshair_ui):  _crosshair_ui.queue_free();  _crosshair_ui = null
		if is_instance_valid(_target_cursor): _target_cursor.queue_free(); _target_cursor = null
		if is_instance_valid(_pred_arc):      _pred_arc.queue_free();      _pred_arc = null

func _update_prediction_arc() -> void:
	# Raycast from dragon down to find ground target based on mouse offset
	var vp := get_viewport()
	var center := vp.get_visible_rect().size * 0.5
	# Add mouse offset from center as world offset
	_target_offset += Vector2(
		Input.get_axis("move_left","move_right") * 0.0,
		Input.get_axis("move_forward","move_backward") * 0.0)
	# Use camera to project a ray downward from slightly offset screen point
	var cam := vp.get_camera_3d()
	var screen_pt := center + _target_offset
	var ray_dir   := Vector3.DOWN
	if is_instance_valid(cam):
		ray_dir = cam.project_ray_normal(screen_pt)
	var origin := global_position
	var space  := get_world_3d().direct_space_state
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + ray_dir * 200.0)
	query.collision_mask = 1  # terrain only
	var hit    := space.intersect_ray(query)
	if not hit.is_empty():
		_target_pos   = hit.position
		_target_valid = true
		if is_instance_valid(_target_cursor):
			_target_cursor.global_position = _target_pos + Vector3(0, 0.1, 0)
			# Pulse scale
			var pulse := 1.0 + sin(Time.get_ticks_msec() * 0.006) * 0.12
			_target_cursor.scale = Vector3(pulse, 1.0, pulse)
	else:
		_target_valid = false
		if is_instance_valid(_target_cursor): _target_cursor.visible = false
	# Draw arc from dragon to target
	if not is_instance_valid(_pred_arc_mesh) or not _target_valid: return
	var to_t : Vector3 = _target_pos - origin
	var time  : float = maxf(to_t.length() / 30.0, 0.5)
	var vel   := Vector3(to_t.x/time, -to_t.y/time + 9.8*time*0.5, to_t.z/time)
	_pred_arc_mesh.clear_surfaces()
	_pred_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var sim_pos := origin
	var steps := 24
	for i in steps:
		var t1 := float(i)   / steps * time
		var t2 := float(i+1) / steps * time
		var p1 := origin + Vector3(vel.x*t1, vel.y*t1 - 4.9*t1*t1, vel.z*t1)
		var p2 := origin + Vector3(vel.x*t2, vel.y*t2 - 4.9*t2*t2, vel.z*t2)
		var alpha := 1.0 - float(i)/steps
		_pred_arc_mesh.surface_set_color(Color(1.0, 0.5, 0.1, alpha))
		_pred_arc_mesh.surface_add_vertex(p1)
		_pred_arc_mesh.surface_set_color(Color(1.0, 0.3, 0.05, alpha * 0.6))
		_pred_arc_mesh.surface_add_vertex(p2)
	_pred_arc_mesh.surface_end()

func _animate_wings() -> void:
	if not is_instance_valid(_wing_l) or not is_instance_valid(_wing_r): return
	var flap : float = sin(_wing_phase * 2.0) * 0.5 + (0.2 if _is_mounted else 0.05)
	_wing_l.rotation.z =  flap
	_wing_r.rotation.z = -flap
	# Tail wag
	if is_instance_valid(_tail):
		_tail.rotation.y = sin(_wing_phase * 0.7) * 0.3


func _build_model() -> void:
	# ── Use GLB if assigned ───────────────────────────────────
	if is_instance_valid(dragon_glb):
		_glb_instance = dragon_glb.instantiate() as Node3D
		if is_instance_valid(_glb_instance):
			add_child(_glb_instance)
			_glb_instance.scale = model_scale
			# Find AnimationPlayer in GLB for animations
			_anim_player = _glb_instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if not is_instance_valid(_anim_player):
				_anim_player = _find_anim_player(_glb_instance)
			# Use GLB head as fire origin — look for node named Head/head
			var glb_head := _glb_instance.find_child("Head", true, false) as Node3D
			if not is_instance_valid(glb_head):
				glb_head = _glb_instance.find_child("head", true, false) as Node3D
			if is_instance_valid(glb_head): _head = glb_head as MeshInstance3D
			# Mount point from GLB or use offset
			_mount_point = Node3D.new(); _mount_point.name = "MountPoint"
			_mount_point.position = mount_offset
			add_child(_mount_point)
			# Fire light
			_fire_light = OmniLight3D.new()
			_fire_light.light_color = Color(1.0, 0.5, 0.1)
			_fire_light.light_energy = 0.5; _fire_light.omni_range = 6.0
			_fire_light.position = mount_offset + Vector3(0, 0, -1.5)
			add_child(_fire_light)
			_play_anim(animation_idle)
			return  # skip procedural model
	# ── Sleek procedural model ───────────────────────────────
	var body_mat := _dragon_mat(SKIN_SCALE, 0.68, 0.25)

	# Body — elongated capsule, narrow and serpentine
	_body = MeshInstance3D.new(); _body.name = "Body"
	var bm := CapsuleMesh.new(); bm.radius = 0.55; bm.height = 4.2; bm.rings = 16; bm.radial_segments = 32
	_body.mesh = bm; _body.rotation_degrees.x = 90.0
	_body.material_override = body_mat
	add_child(_body)

	# ── Neck ──────────────────────────────────────────────────
	_neck = MeshInstance3D.new(); _neck.name = "Neck"
	var nm := CapsuleMesh.new(); nm.radius = 0.22; nm.height = 1.8; nm.rings = 12; nm.radial_segments = 24
	_neck.mesh = nm
	_neck.material_override = body_mat
	_neck.position = Vector3(0, 0.3, -2.2)
	_neck.rotation_degrees.x = -30.0
	add_child(_neck)

	# ── Head ──────────────────────────────────────────────────
	_head = MeshInstance3D.new(); _head.name = "Head"
	var hm := CapsuleMesh.new(); hm.radius = 0.22; hm.height = 0.9; hm.rings = 8; hm.radial_segments = 20
	_head.mesh = hm
	_head.material_override = body_mat
	_head.position = Vector3(0, 0.9, -3.1)
	add_child(_head)

	# Jaw
	var jaw := MeshInstance3D.new()
	var jm := CapsuleMesh.new(); jm.radius = 0.15; jm.height = 0.7
	jaw.mesh = jm; jaw.material_override = body_mat
	jaw.position = Vector3(0, 0.65, -3.2)
	add_child(jaw)

	# Horn
	for side in [-1, 1]:
		var horn := MeshInstance3D.new()
		var cm := CylinderMesh.new(); cm.top_radius = 0.01; cm.bottom_radius = 0.08; cm.height = 0.5
		horn.mesh = cm; horn.material_override = _dragon_mat(SKIN_HORN, 0.4, 0.6)
		horn.position = Vector3(side * 0.22, 1.55, -2.3)
		horn.rotation_degrees.z = side * -20.0
		add_child(horn)

	# Eyes — glowing
	for side in [-1, 1]:
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new(); em.radius = 0.08; em.height = 0.16
		eye.mesh = em
		var eye_mat := StandardMaterial3D.new()
		eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		eye_mat.albedo_color = Color(0.9, 0.05, 0.05)
		eye_mat.emission_enabled = true; eye_mat.emission = Color(1.0, 0.0, 0.0)
		eye_mat.emission_energy_multiplier = 6.0
		eye.material_override = eye_mat
		eye.position = Vector3(side * 0.28, 1.3, -2.7)
		add_child(eye)

	# ── Wings ─────────────────────────────────────────────────
	var wing_mat := _dragon_mat(SKIN_WING, 0.55, 0.05)
	for side in [-1, 1]:
		var wing_root := Node3D.new()
		wing_root.position = Vector3(side * 0.55, 0.5, -0.3)
		add_child(wing_root)

		var wing := MeshInstance3D.new()
		var wm := BoxMesh.new(); wm.size = Vector3(3.8, 0.04, 1.4)
		wing.mesh = wm
		wing.material_override = wing_mat
		wing.position = Vector3(side * 1.3, 0, 0)
		wing_root.add_child(wing)

		# Membrane taper
		var mem := MeshInstance3D.new()
		var mm := CylinderMesh.new(); mm.top_radius = 0.0; mm.bottom_radius = 0.4; mm.height = 1.0
		mem.mesh = mm; mem.material_override = wing_mat
		mem.position = Vector3(side * 2.8, 0, 0.2)
		mem.rotation_degrees.z = side * 15.0
		wing_root.add_child(mem)

		if side == -1: _wing_l = wing_root as MeshInstance3D
		else:          _wing_r = wing_root as MeshInstance3D

	# ── Tail ──────────────────────────────────────────────────
	_tail = MeshInstance3D.new(); _tail.name = "Tail"
	var tm := CapsuleMesh.new(); tm.radius = 0.18; tm.height = 3.2; tm.rings = 14; tm.radial_segments = 24
	_tail.mesh = tm; _tail.material_override = body_mat
	_tail.rotation_degrees.x = 90.0
	_tail.position = Vector3(0, -0.1, 2.4)
	add_child(_tail)

	var tail_tip := MeshInstance3D.new()
	var ttm := CylinderMesh.new(); ttm.top_radius = 0.0; ttm.bottom_radius = 0.22; ttm.height = 0.7
	tail_tip.mesh = ttm; tail_tip.material_override = body_mat
	tail_tip.position = Vector3(0, -0.1, 3.2); tail_tip.rotation_degrees.x = -90.0
	add_child(tail_tip)

	# ── Legs ──────────────────────────────────────────────────
	for offset in [Vector3(-0.7,-0.8,-0.6), Vector3(0.7,-0.8,-0.6),
				   Vector3(-0.7,-0.8,0.6),  Vector3(0.7,-0.8,0.6)]:
		var leg := MeshInstance3D.new()
		var lm := CylinderMesh.new(); lm.top_radius = 0.15; lm.bottom_radius = 0.1; lm.height = 0.9
		leg.mesh = lm; leg.material_override = body_mat
		leg.position = offset; leg.rotation_degrees.x = 15.0
		add_child(leg)

	# ── Fire light ────────────────────────────────────────────
	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.5, 0.1)
	_fire_light.light_energy = 0.5; _fire_light.omni_range = 6.0
	_fire_light.position = Vector3(0, 1.2, -3.0)
	add_child(_fire_light)

	# ── Belly stripe (horror detail) ─────────────────────────
	var belly := MeshInstance3D.new()
	var belm  := CapsuleMesh.new(); belm.radius = 0.55; belm.height = 2.6
	belly.mesh = belm
	belly.material_override = _dragon_mat(SKIN_BELLY, 0.8, 0.05)
	belly.rotation_degrees.x = 90.0
	belly.position = Vector3(0, -0.45, 0)
	belly.scale = Vector3(0.85, 0.85, 0.85)
	add_child(belly)

	# ── Scale ridge spines along back ─────────────────────────
	for i in 7:
		var spine := MeshInstance3D.new()
		var spm := CylinderMesh.new(); spm.top_radius = 0.0; spm.bottom_radius = 0.07; spm.height = 0.3 + (0.2 if i == 3 else 0.0)
		spine.mesh = spm
		spine.material_override = _dragon_mat(SKIN_HORN, 0.35, 0.7)
		spine.position = Vector3(0, 1.05, -1.2 + i * 0.4)
		add_child(spine)

	# ── Mount point ───────────────────────────────────────────
	_mount_point = Node3D.new(); _mount_point.name = "MountPoint"
	_mount_point.position = Vector3(0, 1.2, -0.4)
	add_child(_mount_point)

	# ── Collision ─────────────────────────────────────────────
	var col_body := StaticBody3D.new()
	var col_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new(); capsule.radius = 1.0; capsule.height = 3.5
	col_shape.shape = capsule
	col_body.add_child(col_shape)
	add_child(col_body)


func _set_hud_visible(visible: bool) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if is_instance_valid(h): h.visible = visible

func _find_anim_player(root: Node) -> AnimationPlayer:
	for child in root.get_children():
		if child is AnimationPlayer: return child as AnimationPlayer
		var found := _find_anim_player(child)
		if is_instance_valid(found): return found
	return null

func _play_anim(anim_name: String) -> void:
	if not is_instance_valid(_anim_player): return
	if _anim_player.has_animation(anim_name):
		if _anim_player.current_animation != anim_name:
			_anim_player.play(anim_name)
		return
	# Try lowercase or partial match
	for a in _anim_player.get_animation_list():
		if a.to_lower().contains(anim_name.to_lower()):
			if _anim_player.current_animation != a: _anim_player.play(a)
			return

# Horror palette
const SKIN_BASE   := Color(0.06, 0.06, 0.07)   # near-black
const SKIN_SCALE  := Color(0.10, 0.13, 0.10)   # dark green-grey scales
const SKIN_BELLY  := Color(0.14, 0.08, 0.08)   # dark crimson belly
const SKIN_WING   := Color(0.08, 0.06, 0.11)   # deep purple membrane
const SKIN_HORN   := Color(0.04, 0.04, 0.05)   # obsidian horn

func _dragon_mat(col: Color, roughness: float = 0.65, metallic: float = 0.15) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color  = col
	mat.metallic      = metallic
	mat.roughness     = roughness
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# Snake-pattern via detail UV — procedural checkerboard approximation
	mat.detail_enabled     = true
	mat.detail_blend_mode  = BaseMaterial3D.BLEND_MODE_MUL
	mat.detail_uv_layer    = BaseMaterial3D.DETAIL_UV_2
	# Subsurface for fleshy horror look
	mat.subsurf_scatter_enabled    = true
	mat.subsurf_scatter_strength   = 0.08
	mat.subsurf_scatter_skin_mode  = true
	# Slight emission so scales catch light eerily
	if col.get_luminance() > 0.07:
		mat.emission_enabled            = true
		mat.emission                    = col.darkened(0.7)
		mat.emission_energy_multiplier  = 0.3
	return mat


func _build_mount_label() -> void:
	_mount_label = Label3D.new()
	_mount_label.text = "[E] Mount Dragon"
	_mount_label.font_size = 32
	_mount_label.modulate = Color(0.9, 0.85, 0.3)
	_mount_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_mount_label.position = Vector3(0, 3.0, 0)
	_mount_label.visible = false
	add_child(_mount_label)

class _DragonCrosshair extends Control:
	func _draw() -> void:
		var cx := size.x * 0.5; var cy := size.y * 0.5
		var col := Color(1.0, 0.55, 0.1, 0.95)
		var gap := 10.0; var arm := 22.0; var thick := 1.8
		draw_line(Vector2(cx-arm,cy), Vector2(cx-gap,cy), col, thick)
		draw_line(Vector2(cx+gap,cy), Vector2(cx+arm,cy), col, thick)
		draw_line(Vector2(cx,cy-arm), Vector2(cx,cy-gap), col, thick)
		draw_line(Vector2(cx,cy+gap), Vector2(cx,cy+arm), col, thick)
		draw_arc(Vector2(cx,cy), 7.0, 0, TAU, 24, col, thick)
		# Corner ticks
		for angle in [PI*0.25, PI*0.75, PI*1.25, PI*1.75]:
			var p := Vector2(cos(angle)*18+cx, sin(angle)*18+cy)
			draw_circle(p, 1.5, col)
