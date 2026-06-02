# ============================================================
# SniperScope.gd — AAA sniper scope
# RMB = scope in/out  |  Scroll = cycle zoom
# ============================================================
extends Node

@export var zoom_levels : Array[float] = [20.0, 8.0, 3.0]
@export var ads_speed   : float = 25.0
@export var move_slow   : float = 0.35

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
	_build_ui()
	set_process(true)


func _process(delta: float) -> void:
	if not is_instance_valid(_camera): return
	_camera.fov = lerpf(_camera.fov, _target_fov, ads_speed * delta)
	if _scoped:
		_sway_t += delta
		_camera.rotation_degrees.z = sin(_sway_t * 0.5) * 0.08
	else:
		_camera.rotation_degrees.z = move_toward(_camera.rotation_degrees.z, 0.0, delta * 6.0)
	_update_zoom_lbl()


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
	for h in get_tree().get_nodes_in_group("hud"):
		if "crosshair" in h and is_instance_valid(h.crosshair):
			h.crosshair.visible = on
		if on:
			if h.has_method("show_for_scope"): h.show_for_scope()
		else:
			if h.has_method("hide_for_scope"): h.hide_for_scope()


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
		lbl.text = "%.1fx" % (75.0 / maxf(_camera.fov, 0.5))


# ── UI BUILD ─────────────────────────────────────────────────
func _build_ui() -> void:
	_scope_ui       = CanvasLayer.new()
	_scope_ui.layer = 20
	get_tree().root.add_child(_scope_ui)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible      = false
	_scope_ui.add_child(_overlay)

	var src := """
extends Control

const SEGS     : int   = 64
const DARK     : Color = Color(0.0, 0.0, 0.0, 0.97)
const RIM_OUT  : Color = Color(0.25, 0.25, 0.28, 1.0)
const RIM_MID  : Color = Color(0.12, 0.12, 0.15, 1.0)
const RIM_IN   : Color = Color(0.45, 0.55, 0.45, 0.30)
const HAIR     : Color = Color(0.25, 0.95, 0.35, 0.92)
const MIL      : Color = Color(0.25, 0.95, 0.35, 0.70)
const TICK     : Color = Color(0.25, 0.95, 0.35, 0.50)
const GLARE    : Color = Color(1.00, 1.00, 1.00, 0.06)

func _draw() -> void:
	var sw := get_rect().size.x
	var sh := get_rect().size.y
	if sw <= 0.0 or sh <= 0.0:
		return
	var cx := sw * 0.5
	var cy := sh * 0.5
	var r  := minf(sw, sh) * 0.42

	var circle := PackedVector2Array()
	circle.resize(SEGS)
	for i in SEGS:
		var a := (float(i) / float(SEGS)) * TAU
		circle[i] = Vector2(cx + cos(a) * r, cy + sin(a) * r)

	var pts := PackedVector2Array()
	pts.append(Vector2(0.0, 0.0))
	pts.append(Vector2(0.0, sh))
	pts.append(Vector2(sw,  sh))
	pts.append(Vector2(sw,  0.0))
	pts.append(Vector2(0.0, 0.0))
	for i in SEGS:
		var a := (float(i) / float(SEGS)) * TAU
		pts.append(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	pts.append(Vector2(cx + r, cy))

	var cols := PackedColorArray()
	cols.resize(pts.size())
	cols.fill(DARK)
	draw_polygon(pts, cols)

	draw_arc(Vector2(cx, cy), r + 2.0, 0.0, TAU, SEGS, RIM_OUT, 4.0)
	draw_arc(Vector2(cx, cy), r,       0.0, TAU, SEGS, RIM_MID, 2.0)
	draw_arc(Vector2(cx, cy), r - 3.0, 0.0, TAU, SEGS, RIM_IN,  1.0)

	var gap := 12.0
	var arm := r * 0.55
	draw_line(Vector2(cx - arm, cy), Vector2(cx - gap, cy), HAIR, 1.0)
	draw_line(Vector2(cx + gap, cy), Vector2(cx + arm, cy), HAIR, 1.0)
	draw_line(Vector2(cx, cy - arm), Vector2(cx, cy - gap), HAIR, 1.0)
	draw_line(Vector2(cx, cy + gap), Vector2(cx, cy + arm), HAIR, 1.0)
	draw_circle(Vector2(cx, cy), 1.5, HAIR)

	var ms := r * 0.18
	for i in range(-4, 5):
		if i == 0: continue
		draw_circle(Vector2(cx + i * ms, cy), 1.8, MIL)

	for i in range(-3, 4):
		if i == 0: continue
		draw_circle(Vector2(cx, cy + i * ms), 1.8, MIL)

	for i : int in [-2, -1, 1, 2]:
		var ty   : float = cy + float(i) * ms
		var tlen : float = 6.0 if abs(i) == 1 else 4.0
		draw_line(Vector2(cx - tlen, ty), Vector2(cx + tlen, ty), TICK, 0.8)

	draw_arc(Vector2(cx - r * 0.3, cy - r * 0.3), r * 0.35,
		deg_to_rad(200.0), deg_to_rad(280.0), 20, GLARE, 8.0)
"""

	var draw_script := GDScript.new()
	draw_script.source_code = src
	draw_script.reload()

	var draw := Control.new()
	draw.set_script(draw_script)
	draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(draw)

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
