# ============================================================
# DraggableHudPanel.gd  —  per-panel move / resize handle
# ============================================================
# Attach one to any HUD Control with:
#
#     DraggableHudPanel.attach(my_panel, "unique_id")
#
# It lives as a full-rect child of that panel. When HUD edit mode is
# on (HudLayout, toggled with F8) it covers the panel with a move
# surface + a bottom-right resize grip and draws a dashed outline:
#
#   • drag the body           -> move the panel
#   • drag the corner grip    -> resize the panel
#   • right-click the panel    -> reset it to its original spot
#
# The panel's Rect2 is saved through HudLayout (user://hud_layout.cfg)
# and restored on the next launch. When edit mode is off this node is
# invisible and ignores the mouse, so gameplay input is untouched.
# ============================================================
extends Control
# NOTE: intentionally no `class_name` -- a fresh global class isn't registered
# on a headless (no-editor) boot. Callers use:
#     const DraggableHudPanel := preload("res://scripts/DraggableHudPanel.gd")

const GRIP        : float = 16.0     # size of the corner resize grip, px
const MIN_SIZE    := Vector2(64.0, 36.0)
const TAB_H       : float = 16.0     # drawn title tab height, px

var _target       : Control = null
var _id           : String  = ""
var _default_rect : Rect2   = Rect2()
var _have_default : bool     = false

var _dragging     : bool    = false
var _resizing     : bool    = false
var _grab_off     : Vector2 = Vector2.ZERO
var _saved_applied : bool    = false


# ── factory ────────────────────────────────────────────────
static func attach(target: Control, id: String) -> Control:
	if not is_instance_valid(target):
		return null
	if target.has_node("DragHandle"):          # don't double-attach
		return target.get_node("DragHandle")
	var d : Control = load("res://scripts/DraggableHudPanel.gd").new()
	d._target = target
	d._id     = id
	d.name    = "DragHandle"
	target.add_child(d)
	return d


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 50
	if is_instance_valid(_target):
		_default_rect = Rect2(_target.position, _target.size)
		_have_default = true
	var hl := _hud_layout()
	if hl:
		hl.edit_mode_changed.connect(_on_edit_mode)
		_apply_saved()
		_on_edit_mode(hl.edit_mode)
	else:
		_set_active(false)
	# capture a real default once the panel has been laid out for a frame
	call_deferred("_late_default")


func _late_default() -> void:
	# Grab a real default rect once layout has settled -- but never overwrite it
	# with a rect that came from a saved layout.
	if is_instance_valid(_target) and not _saved_applied and _default_rect.size == Vector2.ZERO:
		_default_rect = Rect2(_target.position, _target.size)


func _hud_layout() -> Node:
	return get_node_or_null("/root/HudLayout")


# ── persistence ────────────────────────────────────────────
func _apply_saved() -> void:
	var hl := _hud_layout()
	if hl == null or not is_instance_valid(_target):
		return
	var r : Rect2 = hl.get_rect(_id)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return   # nothing saved -> keep the scene's own placement
	_target.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_target.position = r.position
	_target.size     = r.size
	_saved_applied   = true


func _save() -> void:
	var hl := _hud_layout()
	if hl and is_instance_valid(_target):
		hl.save_rect(_id, Rect2(_target.position, _target.size))


func _reset() -> void:
	var hl := _hud_layout()
	if hl:
		hl.clear_rect(_id)
	if is_instance_valid(_target) and _have_default:
		_target.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_target.position = _default_rect.position
		_target.size     = _default_rect.size
	queue_redraw()


# ── edit-mode wiring ───────────────────────────────────────
func _on_edit_mode(on: bool) -> void:
	_set_active(on)


func _set_active(on: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	visible = true                       # keep the node processing; _draw guards on edit mode
	_dragging = false
	_resizing = false
	queue_redraw()


func _editing() -> bool:
	var hl := _hud_layout()
	return hl != null and hl.edit_mode


# ── input ──────────────────────────────────────────────────
func _gui_input(event: InputEvent) -> void:
	if not _editing() or not is_instance_valid(_target):
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_reset()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var local : Vector2 = mb.position
				if local.x >= size.x - GRIP and local.y >= size.y - GRIP:
					_resizing = true
				else:
					_dragging = true
					_grab_off = get_global_mouse_position() - _target.global_position
				_target.set_anchors_preset(Control.PRESET_TOP_LEFT)
			else:
				if _dragging or _resizing:
					_dragging = false
					_resizing = false
					_save()
			accept_event()

	elif event is InputEventMouseMotion:
		if _dragging:
			var vp : Vector2 = get_viewport_rect().size
			var np : Vector2 = get_global_mouse_position() - _grab_off
			np.x = clampf(np.x, 0.0, maxf(0.0, vp.x - _target.size.x))
			np.y = clampf(np.y, 0.0, maxf(0.0, vp.y - _target.size.y))
			_target.global_position = np
			queue_redraw()
		elif _resizing:
			var ns : Vector2 = get_global_mouse_position() - _target.global_position
			_target.size = Vector2(maxf(ns.x, MIN_SIZE.x), maxf(ns.y, MIN_SIZE.y))
			queue_redraw()


# ── overlay ────────────────────────────────────────────────
func _draw() -> void:
	if not _editing():
		return
	var r := Rect2(Vector2.ZERO, size)
	var accent := Color(0.35, 0.75, 1.0, 0.95)
	var fill   := Color(0.35, 0.75, 1.0, 0.10)
	draw_rect(r, fill, true)
	# dashed-ish border (four solid edges + inset)
	draw_rect(r, accent, false, 2.0)
	# title tab
	draw_rect(Rect2(0.0, -TAB_H, minf(size.x, 120.0), TAB_H), accent, true)
	var f := ThemeDB.fallback_font
	draw_string(f, Vector2(6.0, -4.0), _id, HORIZONTAL_ALIGNMENT_LEFT, 114.0, 10,
		Color(0.03, 0.05, 0.09))
	# resize grip
	var g := Rect2(size.x - GRIP, size.y - GRIP, GRIP, GRIP)
	draw_rect(g, accent, true)
	draw_line(Vector2(size.x - GRIP, size.y), Vector2(size.x, size.y - GRIP),
		Color(0.03, 0.05, 0.09), 1.5)
