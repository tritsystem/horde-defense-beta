# ============================================================
# patrol_editor.gd — GODOT 4.6 COMPATIBLE
# ============================================================
extends Node
class_name PatrolEditor

signal patrol_path_set(points: Array)
signal editor_closed

# ===============================
# STATE
# ===============================
var _active        : bool           = false
var _waypoints     : Array[Vector3] = []
var _screen_pts    : Array[Vector2] = []  # cached screen positions

var _drag_start_screen : Vector2 = Vector2.ZERO
var _is_dragging       : bool    = false
var _drag_threshold    : float   = 12.0
var _drag_current      : Vector2 = Vector2.ZERO
var _drag_dirty        : bool    = false

var _camera       : Camera3D = null
var _overlay      : Control  = null
var _status_label : Label    = null
var _finish_btn   : Button   = null

# ===============================
# INIT
# ===============================
func init(camera: Camera3D, status_lbl: Label) -> void:
	_camera       = camera
	_status_label = status_lbl
	_build_overlay()

func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.focus_mode   = Control.FOCUS_NONE
	_overlay.visible      = false
	_overlay.z_index      = 200

	_overlay.draw.connect(_on_overlay_draw)
	_overlay.gui_input.connect(_on_overlay_input)

	get_parent().add_child(_overlay)

	_finish_btn               = Button.new()
	_finish_btn.text          = "✔ Finish Path"
	_finish_btn.anchor_left   = 0.35
	_finish_btn.anchor_right  = 0.65
	_finish_btn.anchor_top    = 0.91
	_finish_btn.anchor_bottom = 0.97
	_finish_btn.z_index       = 201
	_finish_btn.mouse_filter  = Control.MOUSE_FILTER_STOP
	_finish_btn.focus_mode    = Control.FOCUS_NONE
	_finish_btn.visible       = false
	_finish_btn.pressed.connect(send_patrol)
	_overlay.add_child(_finish_btn)

# ===============================
# OPEN / CLOSE
# ===============================
func open() -> void:
	_active             = true
	_is_dragging        = false
	_drag_dirty         = false
	_overlay.visible    = true
	_finish_btn.visible = true
	_overlay.queue_redraw()
	_update_status("Click: place point  |  Drag: rectangle  |  Right-click: undo  |  Finish / Enter: confirm  |  Esc: cancel")

func close() -> void:
	_active             = false
	_is_dragging        = false
	_drag_dirty         = false
	_overlay.visible    = false
	_finish_btn.visible = false
	editor_closed.emit()
# ===============================
# UTIL — update status label
# ===============================
func _update_status(text: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text
func clear_waypoints() -> void:
	_waypoints.clear()
	_screen_pts.clear()
	_overlay.queue_redraw()
	_update_status("Waypoints cleared.")

func send_patrol() -> void:
	if _waypoints.is_empty():
		_update_status("No waypoints set!")
		return
	patrol_path_set.emit(_waypoints.duplicate())
	_update_status("✓ Patrol path sent — %d waypoints." % _waypoints.size())
	close()

# ===============================
# KEYBOARD INPUT
# ===============================
func _input(event: InputEvent) -> void:
	if not _active: return
	if not (event is InputEventKey): return
	if not event.pressed or event.echo: return
	match event.keycode:
		KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			send_patrol()
			get_viewport().set_input_as_handled()
		KEY_Z:
			if event.ctrl_pressed:
				_remove_last_waypoint()
				get_viewport().set_input_as_handled()

# ===============================
# MOUSE INPUT
# ===============================
func _on_overlay_input(event: InputEvent) -> void:
	if not _active:
		return

	if event is InputEventMouseButton:
		var mev := event as InputEventMouseButton
		if mev.button_index == MOUSE_BUTTON_RIGHT and mev.pressed:
			_remove_last_waypoint()
			get_viewport().set_input_as_handled()
			return
		if mev.button_index == MOUSE_BUTTON_LEFT:
			if mev.pressed:
				_drag_start_screen = mev.position
				_drag_current      = mev.position
				_is_dragging       = false
				_drag_dirty        = false
			else:
				if _is_dragging:
					_finish_rect_drag(mev.position)
				else:
					if not _finish_btn.get_global_rect().has_point(mev.position):
						_add_waypoint_at_screen(mev.position)
				_is_dragging = false
				_drag_dirty  = false
				_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			return
		var motion = event as InputEventMouseMotion
		var prev_drag = _is_dragging
		_drag_current = motion.position
		if motion.position.distance_to(_drag_start_screen) > _drag_threshold:
			_is_dragging = true
		if _is_dragging:
			if not prev_drag or motion.relative.length_squared() > 4.0:
				_drag_dirty = true
				_overlay.queue_redraw()

# ===============================
# WAYPOINT MANAGEMENT
# ===============================
func _add_waypoint_at_screen(screen_pos: Vector2) -> void:
	var world := _screen_to_world(screen_pos)
	if world == Vector3.ZERO:
		return
	_waypoints.append(world)
	_screen_pts.append(screen_pos)
	_overlay.queue_redraw()
	_update_status("Waypoint %d added.  Finish / Enter: confirm  |  Right-click: undo" % _waypoints.size())

func _remove_last_waypoint() -> void:
	if _waypoints.is_empty():
		return
	_waypoints.pop_back()
	_screen_pts.pop_back()
	_overlay.queue_redraw()
	_update_status("%d waypoint(s) remaining.  Right-click: undo  |  Finish / Enter: confirm" % _waypoints.size())

func _finish_rect_drag(end_screen: Vector2) -> void:
	var corners : Array[Vector2] = [
		_drag_start_screen,
		Vector2(end_screen.x, _drag_start_screen.y),
		end_screen,
		Vector2(_drag_start_screen.x, end_screen.y),
	]
	var added := 0
	for sc in corners:
		var w := _screen_to_world(sc)
		if w != Vector3.ZERO:
			_waypoints.append(w)
			_screen_pts.append(sc)
			added += 1
	if added > 0:
		_update_status("Rectangle added (%d corners).  Finish / Enter: confirm" % added)

# ===============================
# DRAW
# ===============================
func _on_overlay_draw() -> void:
	if not _active:
		return

	var dot_color  := Color(0.2, 0.8, 1.0, 0.95)
	var line_color := Color(0.2, 0.8, 1.0, 0.55)
	var rect_color := Color(1.0, 0.85, 0.2, 0.35)

	# Waypoint lines
	for i in range(1, _screen_pts.size()):
		_overlay.draw_line(_screen_pts[i - 1], _screen_pts[i], line_color, 2.0)

	# Close-loop hint when 3+ points
	if _screen_pts.size() >= 3:
		_overlay.draw_line(_screen_pts[-1], _screen_pts[0], Color(0.2, 0.8, 1.0, 0.25), 1.5)

	# Waypoint dots + numbers
	for i in range(_screen_pts.size()):
		var sp := _screen_pts[i]
		_overlay.draw_circle(sp, 8.0, dot_color)
		_overlay.draw_circle(sp, 10.0, Color(0.2, 0.8, 1.0, 0.3))
		_overlay.draw_string(
			ThemeDB.fallback_font,
			sp + Vector2(-4, 5),
			str(i + 1),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1, 13,
			Color.BLACK
		)

	# Drag rectangle
	if _is_dragging:
		var rect := Rect2(_drag_start_screen, _drag_current - _drag_start_screen).abs()
		_overlay.draw_rect(rect, rect_color)
		_overlay.draw_rect(rect, Color(1.0, 0.85, 0.2, 0.8), false, 2.0)

# ===============================
# UTILS
# ===============================
func _screen_to_world(screen_pos: Vector2) -> Vector3:
	if not is_instance_valid(_camera):
		return Vector3.ZERO

	var from = _camera.project_ray_origin(screen_pos)
	var to   = from + _camera.project_ray_normal(screen_pos) * 300.0

	var params = PhysicsRayQueryParameters3D.create(from, to)
	var result = _camera.get_world_3d().direct_space_state.intersect_ray(params)

	if result == null:
		return Vector3.ZERO

	return result.get("position", Vector3.ZERO)
