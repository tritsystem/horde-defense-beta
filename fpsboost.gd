# ============================================================
# FPSBooster.gd — GPU + CPU + Physics optimization
# Attach to main scene root OR add as AutoLoad.
# F1 cycles presets. Pause Menu → Settings → FPS BOOST.
# ============================================================
extends Node

@export var draw_distance_ultra    : float = 50.0
@export var draw_distance_high     : float = 80.0
@export var draw_distance_balanced : float = 120.0


enum Preset { ULTRA, HIGH, BALANCED, OFF }
var _preset : Preset = Preset.ULTRA

var _orig_msaa_3d      : int   = Viewport.MSAA_DISABLED
var _orig_msaa_2d      : int   = Viewport.MSAA_DISABLED
var _orig_taa          : bool  = false
var _orig_sdfgi        : bool  = false
var _orig_ssr          : bool  = false
var _orig_ssao         : bool  = false
var _orig_ssil         : bool  = false
var _orig_glow         : bool  = false
var _orig_vsync        : int   = DisplayServer.VSYNC_ENABLED
var _orig_far          : float = 300.0
var _shadow_store      : Dictionary = {}


func _ready() -> void:
	add_to_group("fps_booster")
	Engine.max_fps = 0
	_cache_originals()
	print("[FPS] Booster ready — applying ULTRA")
	_apply_preset(Preset.ULTRA)


func _exit_tree() -> void:
	_apply_preset(Preset.OFF)


# ============================================================
# PRESETS
# ============================================================
func _apply_preset(p: Preset) -> void:
	_preset = p
	match p:
		Preset.ULTRA:
			_gpu_ultra()
			_cpu_ultra()
			print("[FPS] ULTRA — max FPS mode")
		Preset.HIGH:
			_gpu_high()
			_cpu_high()
			print("[FPS] HIGH")
		Preset.BALANCED:
			_gpu_balanced()
			_cpu_balanced()
			print("[FPS] BALANCED")
		Preset.OFF:
			_restore_all()
			print("[FPS] OFF — restored")


# ── GPU ───────────────────────────────────────────────────────
func _gpu_ultra() -> void:
	Engine.max_fps = 0
	_set_vsync(false)
	_set_msaa(Viewport.MSAA_DISABLED, Viewport.MSAA_DISABLED)
	_set_taa(false)
	_set_sdfgi(false)
	_set_ssr(false)
	_set_ssao(false)
	_set_ssil(false)
	_set_glow(false)
	_set_shadows(false)
	_set_draw_distance(draw_distance_ultra)
	_set_occlusion_culling(true)
	_set_mesh_lod(1.0)

func _gpu_high() -> void:
	_set_vsync(false)
	_set_msaa(Viewport.MSAA_DISABLED, Viewport.MSAA_DISABLED)
	_set_taa(false)
	_set_sdfgi(false)
	_set_ssr(false)
	_set_ssao(false)
	_set_ssil(false)
	_set_glow(true)
	_set_shadows(false)
	_set_draw_distance(draw_distance_high)
	_set_occlusion_culling(true)
	_set_mesh_lod(1.0)

func _gpu_balanced() -> void:
	_set_vsync(false)
	_set_msaa(Viewport.MSAA_2X, Viewport.MSAA_DISABLED)
	_set_taa(false)
	_set_sdfgi(false)
	_set_ssr(false)
	_set_ssao(true)
	_set_ssil(false)
	_set_glow(true)
	_set_shadows(true)
	_set_draw_distance(draw_distance_balanced)
	_set_occlusion_culling(true)
	_set_mesh_lod(1.0)


# ── CPU ───────────────────────────────────────────────────────
func _cpu_ultra() -> void:
	NavigationServer3D.set_debug_enabled(false)
	_throttle_navigation(true)
	_set_zombie_process_mode(Node.PROCESS_MODE_INHERIT, 2)

func _cpu_high() -> void:
	_throttle_navigation(true)
	_set_zombie_process_mode(Node.PROCESS_MODE_INHERIT, 1)

func _cpu_balanced() -> void:
	_throttle_navigation(false)
	_set_zombie_process_mode(Node.PROCESS_MODE_INHERIT, 1)


func _throttle_navigation(throttle: bool) -> void:
	if throttle:
		NavigationServer3D.set_active(true)
		for agent in get_tree().get_nodes_in_group("nav_agents"):
			if agent.has_method("set_navigation_layer_value"): continue
			if "path_desired_distance" in agent:
				agent.set_meta("_nav_throttle", 3)


func _set_zombie_process_mode(_mode: int, _every_n: int) -> void:
	var zombies := get_tree().get_nodes_in_group("zombies")
	for i in zombies.size():
		var z := zombies[i]
		if not is_instance_valid(z): continue
		if z.has_method("set_ai_tick_offset"):
			z.set_ai_tick_offset(i % _every_n)


# ============================================================
# INPUT — F1 cycles
# ============================================================
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey): return
	if not (event as InputEventKey).pressed: return
	if (event as InputEventKey).keycode != KEY_F1: return
	var next := ((_preset + 1) % (Preset.OFF + 1)) as Preset
	_apply_preset(next)
	var labels := ["ULTRA","HIGH","BALANCED","OFF"]
	print("[FPS] → %s (F1 to cycle)" % labels[_preset])
	get_viewport().set_input_as_handled()


# ============================================================
# HELPERS
# ============================================================
func _set_vsync(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)


func _set_msaa(msaa_3d: int, msaa_2d: int) -> void:
	get_tree().root.msaa_3d = msaa_3d
	get_tree().root.msaa_2d = msaa_2d


func _set_taa(on: bool) -> void:
	if get_tree().root.has_method("set_use_taa"):
		get_tree().root.set_use_taa(on)


func _set_occlusion_culling(on: bool) -> void:
	get_tree().root.use_occlusion_culling = on


func _set_mesh_lod(px: float) -> void:
	get_tree().root.mesh_lod_threshold = px


func _set_draw_distance(far: float) -> void:
	for cam in get_tree().get_nodes_in_group("cameras"):
		if cam is Camera3D and _is_root_vp_cam(cam):
			if not cam.has_meta("_orig_far"): cam.set_meta("_orig_far", (cam as Camera3D).far)
			(cam as Camera3D).far = far
	var active := get_tree().root.get_camera_3d()
	if is_instance_valid(active) and _is_root_vp_cam(active):
		if not active.has_meta("_orig_far"): active.set_meta("_orig_far", active.far)
		active.far = far


func _set_sdfgi(on: bool) -> void:
	var e := _env(); if is_instance_valid(e): e.sdfgi_enabled = on
func _set_ssr(on: bool)   -> void:
	var e := _env(); if is_instance_valid(e): e.ssr_enabled = on
func _set_ssao(on: bool)  -> void:
	var e := _env(); if is_instance_valid(e): e.ssao_enabled = on
func _set_ssil(on: bool)  -> void:
	var e := _env(); if is_instance_valid(e): e.ssil_enabled = on
func _set_glow(on: bool)  -> void:
	var e := _env(); if is_instance_valid(e): e.glow_enabled = on


func _set_shadows(on: bool) -> void:
	if on:
		for nid in _shadow_store:
			var n : Object = instance_from_id(nid)
			if not is_instance_valid(n): continue
			if "shadow_enabled" in n: n.shadow_enabled = _shadow_store[nid]
			elif "cast_shadow" in n:  n.cast_shadow    = _shadow_store[nid]
		_shadow_store.clear()
		for lt in get_tree().get_nodes_in_group("directional_lights"):
			if lt is DirectionalLight3D:
				(lt as DirectionalLight3D).directional_shadow_max_distance = \
					lt.get_meta("_orig_sdist", 100.0)
	else:
		_shadow_pass(get_tree().root)
		for lt in get_tree().get_nodes_in_group("directional_lights"):
			if lt is DirectionalLight3D:
				var dl := lt as DirectionalLight3D
				if not dl.has_meta("_orig_sdist"):
					dl.set_meta("_orig_sdist", dl.directional_shadow_max_distance)
				dl.directional_shadow_max_distance = 20.0


func _shadow_pass(node: Node) -> void:
	if node.is_in_group("zombies") or node.is_in_group("minions"): return
	if "shadow_enabled" in node and node.shadow_enabled:
		_shadow_store[node.get_instance_id()] = node.shadow_enabled
		node.shadow_enabled = false
	elif "cast_shadow" in node and \
			node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		_shadow_store[node.get_instance_id()] = node.cast_shadow
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_shadow_pass(child)


func _cache_originals() -> void:
	var vp := get_tree().root
	_orig_msaa_3d   = vp.msaa_3d
	_orig_msaa_2d   = vp.msaa_2d
	_orig_vsync     = DisplayServer.window_get_vsync_mode()
	var cam := vp.get_camera_3d()
	if is_instance_valid(cam): _orig_far = cam.far
	var e := _env()
	if is_instance_valid(e):
		_orig_sdfgi = e.sdfgi_enabled
		_orig_ssr   = e.ssr_enabled
		_orig_ssao  = e.ssao_enabled
		_orig_ssil  = e.ssil_enabled
		_orig_glow  = e.glow_enabled


func _restore_all() -> void:
	DisplayServer.window_set_vsync_mode(_orig_vsync)
	_set_msaa(_orig_msaa_3d, _orig_msaa_2d)
	_set_taa(_orig_taa)
	_set_occlusion_culling(false)
	_set_mesh_lod(1.0)
	var e := _env()
	if is_instance_valid(e):
		e.sdfgi_enabled = _orig_sdfgi
		e.ssr_enabled   = _orig_ssr
		e.ssao_enabled  = _orig_ssao
		e.ssil_enabled  = _orig_ssil
		e.glow_enabled  = _orig_glow
	_set_shadows(true)
	for cam in get_tree().get_nodes_in_group("cameras"):
		if cam is Camera3D and cam.has_meta("_orig_far"):
			(cam as Camera3D).far = cam.get_meta("_orig_far")
			cam.remove_meta("_orig_far")
	var active := get_tree().root.get_camera_3d()
	if is_instance_valid(active) and active.has_meta("_orig_far"):
		active.far = active.get_meta("_orig_far")
		active.remove_meta("_orig_far")


func _env() -> Environment:
	for we in get_tree().get_nodes_in_group("world_environment"):
		if we is WorldEnvironment and is_instance_valid((we as WorldEnvironment).environment):
			return (we as WorldEnvironment).environment
	var we := get_tree().root.find_child("WorldEnvironment", true, false)
	if is_instance_valid(we) and we is WorldEnvironment:
		return (we as WorldEnvironment).environment
	return null


func _is_root_vp_cam(cam: Camera3D) -> bool:
	var n : Node = cam.get_parent()
	while is_instance_valid(n):
		if n is SubViewport: return false
		n = n.get_parent()
	return true
