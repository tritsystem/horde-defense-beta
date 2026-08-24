# ============================================================
# SniperScope.gd — AAA sniper scope
# RMB = scope in/out  |  Scroll = cycle zoom
# ============================================================
extends Node

@export var zoom_levels : Array[float] = [20.0, 8.0, 3.0]
@export var ads_speed   : float = 25.0
@export var move_slow   : float = 0.35
@export var breath_hold_max     : float = 4.0   # seconds you can hold breath before running out
@export var breath_recover_rate : float = 1.6   # recovers this many seconds per real second, unscoped or not holding

var _zoom_idx   : int   = 0
var _camera     : Camera3D    = null
var _player     : Node        = null
var _scoped     : bool  = false
var _scope_fov  : float = 20.0
var _base_fov   : float = 75.0
var _target_fov : float = 75.0
var _sway_t     : float = 0.0
var _scope_ui   : CanvasLayer = null
var _overlay    : Control     = null
# REAL BUG FIX: the scope UI has always advertised "HOLD BREATH [C]" (see
# _build_ui()'s BreathLbl) but nothing anywhere ever read that input or
# reduced sway -- a real, confirmed feature that was pure UI text with zero
# backing implementation. _breath_remaining is a limited resource (like a
# stamina bar) so holding breath isn't a free permanent no-sway button.
var _breath_remaining : float = 4.0
var _holding_breath   : bool  = false

signal scope_toggled(on: bool)
signal zoom_changed(fov: float)


# ── LIFECYCLE ────────────────────────────────────────────────
func _ready() -> void:
	set_process(false)


func setup(cam: Camera3D, player: Node) -> void:
	_camera     = cam
	_player     = player
	_base_fov   = cam.fov
	_scope_fov  = zoom_levels[0] if not zoom_levels.is_empty() else 20.0
	_target_fov = _base_fov
	_breath_remaining = breath_hold_max
	_build_ui()
	set_process(true)


func _process(delta: float) -> void:
	if not is_instance_valid(_camera): return
	_camera.fov = lerpf(_camera.fov, _target_fov, ads_speed * delta)
	if _scoped:
		_update_hold_breath(delta)
		_sway_t += delta
		var sway_amount : float = 0.006 if _holding_breath else 0.08
		_camera.rotation_degrees.z = sin(_sway_t * 0.5) * sway_amount
	else:
		_holding_breath = false
		_breath_remaining = minf(_breath_remaining + breath_recover_rate * delta, breath_hold_max)
		_camera.rotation_degrees.z = move_toward(_camera.rotation_degrees.z, 0.0, delta * 6.0)
	_update_zoom_lbl()
	_update_breath_lbl()


func _update_hold_breath(delta: float) -> void:
	var wants_hold : bool = Input.is_key_pressed(KEY_C) and _breath_remaining > 0.0
	if wants_hold:
		_holding_breath = true
		_breath_remaining = maxf(_breath_remaining - delta, 0.0)
	else:
		_holding_breath = false
		_breath_remaining = minf(_breath_remaining + breath_recover_rate * delta, breath_hold_max)


func _update_breath_lbl() -> void:
	if not is_instance_valid(_overlay): return
	var lbl := _overlay.find_child("BreathLbl", true, false) as Label
	if not is_instance_valid(lbl): return
	if _holding_breath:
		lbl.text = "HOLDING BREATH  %.1fs" % _breath_remaining
		lbl.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0, 0.9))
	else:
		lbl.text = "HOLD BREATH [C]"
		lbl.add_theme_color_override("font_color", Color(0.4, 0.6, 0.4, 0.6))


# ── PUBLIC API ───────────────────────────────────────────────
func scope_in() -> void:
	if _scoped: return
	_scoped     = true
	_target_fov = _scope_fov
	if is_instance_valid(_overlay): _overlay.visible = true
	scope_toggled.emit(true)
	_set_hud_visible(false)
	_set_spirits_visible(false)
	if is_instance_valid(_player) and "walk_speed" in _player:
		_player.set_meta("_scope_speed_backup", _player.get("walk_speed"))
		_player.set("walk_speed", _player.get("walk_speed") * move_slow)


func scope_out() -> void:
	if not _scoped: return
	_scoped     = false
	_target_fov = _base_fov
	if is_instance_valid(_overlay): _overlay.visible = false
	if is_instance_valid(_camera): _camera.rotation_degrees.z = 0.0
	scope_toggled.emit(false)
	_set_hud_visible(true)
	_set_spirits_visible(true)
	if is_instance_valid(_player) and _player.has_meta("_scope_speed_backup"):
		_player.set("walk_speed", _player.get_meta("_scope_speed_backup"))
		_player.remove_meta("_scope_speed_backup")


func cycle_zoom() -> void:
	if not _scoped or zoom_levels.is_empty(): return
	_zoom_idx   = (_zoom_idx + 1) % zoom_levels.size()
	_scope_fov  = zoom_levels[_zoom_idx]
	_target_fov = _scope_fov
	zoom_changed.emit(_scope_fov)


func adjust_zoom(_direction: float) -> void:
	cycle_zoom()


func is_scoped() -> bool:
	return _scoped


func cleanup() -> void:
	if is_instance_valid(_scope_ui): _scope_ui.queue_free()
	set_process(false)


# ── HELPERS ──────────────────────────────────────────────────
func _set_hud_visible(on: bool) -> void:
	# Only affect THIS player's HUD, not all players'
	var my_hud : Node = null
	if is_instance_valid(_player) and "hud" in _player:
		my_hud = _player.get("hud")
	if not is_instance_valid(my_hud):
		# Fallback: find HUD in player's own SubViewport
		var vp := _camera.get_viewport() if is_instance_valid(_camera) else null
		if is_instance_valid(vp):
			for h in get_tree().get_nodes_in_group("hud"):
				if is_instance_valid(h) and vp.is_ancestor_of(h):
					my_hud = h; break
	if not is_instance_valid(my_hud): return
	if "crosshair" in my_hud and is_instance_valid(my_hud.crosshair):
		my_hud.crosshair.visible = on
	if on:
		if my_hud.has_method("show_for_scope"): my_hud.show_for_scope()
	else:
		if my_hud.has_method("hide_for_scope"): my_hud.hide_for_scope()


func _set_spirits_visible(on: bool) -> void:
	if not is_instance_valid(_player): return
	var aura := _player.get_node_or_null("PlayerEnergyAura")
	if not is_instance_valid(aura): return
	for s in (aura.get("_spirits") if "_spirits" in aura else []):
		if is_instance_valid(s): (s as Node3D).visible = on


func _update_zoom_lbl() -> void:
	if not is_instance_valid(_overlay): return
	var lbl := _overlay.find_child("ZoomLbl", true, false) as Label
	if is_instance_valid(lbl) and is_instance_valid(_camera):
		# REAL BUG FIX: this hardcoded 75.0 as "the" base FOV for the zoom
		# multiplier readout, but the real base FOV is captured dynamically
		# in setup() as _base_fov (whatever the camera's actual FOV is) --
		# if the camera isn't exactly 75 the displayed zoom number was wrong.
		lbl.text = "%.1fx" % (_base_fov / maxf(_camera.fov, 0.5))


# ── UI BUILD ─────────────────────────────────────────────────
func _build_ui() -> void:
	_scope_ui       = CanvasLayer.new()
	_scope_ui.layer = 20
	# Camera lives in main scene — get_viewport() returns root Window.
	# Correct approach: ask SSM for the player's SubViewport directly.
	var target_vp : Node = get_tree().root
	if is_instance_valid(_player):
		var pid : int = int(_player.get("player_id") if "player_id" in _player else 1)
		var ssm := get_tree().get_first_node_in_group("splitscreen_manager")
		if is_instance_valid(ssm) and ssm.has_method("get_player_viewport"):
			var svp : Node = ssm.call("get_player_viewport", pid - 1)
			if is_instance_valid(svp): target_vp = svp
	target_vp.add_child(_scope_ui)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible      = false
	_scope_ui.add_child(_overlay)

	# ── Black vignette using shader (reliable in Godot 4) ──────
	# Shader discards pixels inside the lens circle, showing the game through.
	# Everything outside the circle is solid black.
	var black_rect := ColorRect.new()
	black_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	black_rect.color = Color(0, 0, 0, 1)
	black_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader_src := """
shader_type canvas_item;
void fragment() {
	vec2 uv = UV - vec2(0.5);
	uv.x *= SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;  // correct aspect
	float r = length(uv);
	float lens_r = 0.42;
	if (r < lens_r - 0.002) {
		discard;  // inside lens — show game through
	}
	COLOR = vec4(0.0, 0.0, 0.0, 1.0);
}
"""
	var shd := Shader.new()
	shd.code = shader_src
	var mat := ShaderMaterial.new()
	mat.shader = shd
	black_rect.material = mat
	_overlay.add_child(black_rect)

	# ── Reticle drawn on top of the black mask ─────────────────
	var reticle_src := """
extends Control
func _draw() -> void:
	var sw := get_rect().size.x; var sh := get_rect().size.y
	if sw <= 0 or sh <= 0: return
	var cx := sw * 0.5; var cy := sh * 0.5
	var r  := minf(sw, sh) * 0.42
	const SEGS := 64
	const RIM  := Color(0.25, 0.95, 0.35, 0.85)
	const HAIR := Color(0.25, 0.95, 0.35, 0.92)
	const MIL  := Color(0.25, 0.95, 0.35, 0.65)
	draw_arc(Vector2(cx,cy), r+2.0, 0.0, TAU, SEGS, Color(0.2,0.2,0.22,1.0), 4.0)
	draw_arc(Vector2(cx,cy), r,     0.0, TAU, SEGS, RIM, 2.0)
	var gap := 14.0; var arm := r * 0.52
	draw_line(Vector2(cx-arm,cy), Vector2(cx-gap,cy), HAIR, 1.2)
	draw_line(Vector2(cx+gap,cy), Vector2(cx+arm,cy), HAIR, 1.2)
	draw_line(Vector2(cx,cy-arm), Vector2(cx,cy-gap), HAIR, 1.2)
	draw_line(Vector2(cx,cy+gap), Vector2(cx,cy+arm), HAIR, 1.2)
	draw_circle(Vector2(cx,cy), 1.8, HAIR)
	var ms := r*0.18
	for i in range(-4,5):
		if i==0: continue
		draw_circle(Vector2(cx+i*ms, cy), 1.6, MIL)
		draw_circle(Vector2(cx, cy+i*ms), 1.6, MIL)
"""
	var rdraw_script := GDScript.new()
	rdraw_script.source_code = reticle_src
	rdraw_script.reload()
	var rdraw := Control.new()
	rdraw.set_script(rdraw_script)
	rdraw.set_anchors_preset(Control.PRESET_FULL_RECT)
	rdraw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(rdraw)

	var zoom_lbl := Label.new()
	zoom_lbl.name = "ZoomLbl"
	zoom_lbl.add_theme_font_size_override("font_size", 14)
	zoom_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.45, 0.9))
	zoom_lbl.anchor_left   = 0.5;  zoom_lbl.anchor_right  = 0.5
	zoom_lbl.anchor_top    = 0.62; zoom_lbl.anchor_bottom = 0.62
	zoom_lbl.offset_left   = -50;  zoom_lbl.offset_right  = 50
	zoom_lbl.offset_top    = 0.0;  zoom_lbl.offset_bottom = 20.0
	zoom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zoom_lbl.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(zoom_lbl)

	var breath := Label.new()
	breath.name = "BreathLbl"
	breath.text = "HOLD BREATH [C]"
	breath.add_theme_font_size_override("font_size", 10)
	breath.add_theme_color_override("font_color", Color(0.4, 0.6, 0.4, 0.6))
	breath.anchor_left   = 0.5;  breath.anchor_right  = 0.5
	breath.anchor_top    = 0.65; breath.anchor_bottom = 0.65
	breath.offset_left   = -70;  breath.offset_right  = 70
	breath.offset_top    = 0.0;  breath.offset_bottom = 16.0
	breath.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	breath.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(breath)
