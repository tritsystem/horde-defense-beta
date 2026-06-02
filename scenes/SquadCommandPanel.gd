# ============================================================
# SquadCommandPanel.gd
# ============================================================
extends Control

const DEFEND_RALLY_OFFSET : float = 4.0
const ATTACK_SCAN_RADIUS  : float = 60.0
const RAY_LENGTH_SELECT   : float = 200.0
const RAY_LENGTH_GROUND   : float = 300.0
const BOX_DRAG_THRESHOLD  : float = 8.0

const C_ATTACK := Color(0.85, 0.25, 0.10)
const C_DEFEND := Color(0.20, 0.45, 0.85)
const C_PATROL := Color(0.20, 0.75, 0.45)
const C_STAY   := Color(0.45, 0.45, 0.50)
const C_FOLLOW := Color(0.75, 0.55, 0.20)
const C_SELECT := Color(0.15, 0.55, 0.25)

var player        : Node   = null
var _team_id      : int    = 1
var _device_id    : int    = -1
var _player_iid   : int    = -1
var _player_index : int    = 0
var _horde_mgr    : Node   = null
var _pending_command  : String = ""
var _patrol_waypoints : Array  = []
var _in_patrol_set    : bool   = false

var _minimized        : bool   = false
var _min_bar          : Panel  = null

var _count_label  : Label
var _status_label : Label
var _sel_btn      : Button
var _atk_btn      : Button
var _def_btn      : Button
var _pat_btn      : Button
var _stay_btn     : Button
var _follow_btn   : Button
var _box_rect     : ColorRect

var _box_selecting : bool    = false
var _box_start     : Vector2 = Vector2.ZERO

# ── LIFECYCLE ────────────────────────────────────────────────
func _ready() -> void:
	_find_horde_manager()
	_build_ui()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	name = "SquadCommandPanel_P%d" % _player_index
	# Poll count every 0.2s as backup if signal not connected
	var t := get_tree().create_timer(0.2)
	t.timeout.connect(_poll_count_loop)

func _poll_count_loop() -> void:
	if not is_instance_valid(self): return
	_refresh_count()
	if is_instance_valid(get_tree()):
		get_tree().create_timer(0.2).timeout.connect(_poll_count_loop)

func bind_player(p: Node, player_idx: int = 0) -> void:
	player        = p
	_player_index = player_idx
	_team_id   = int(p.get("team_id")   if "team_id"   in p else 1)
	_device_id = int(p.get("device_id") if "device_id" in p else -1)
	_player_iid = p.get_instance_id()
	_find_horde_manager()
	_refresh_count()

# ── HORDE MANAGER ────────────────────────────────────────────
func _find_horde_manager() -> void:
	if is_instance_valid(player):
		for node_name in ["HordeManager","ZombieHordeManager"]:
			if player.has_node(node_name):
				_horde_mgr = player.get_node(node_name); break
	if not is_instance_valid(_horde_mgr):
		for mgr in (get_tree().get_nodes_in_group("horde_manager") +
					get_tree().get_nodes_in_group("zombie_horde_manager")):
			if mgr.has_method("get_team_id") and mgr.get_team_id() == _team_id:
				_horde_mgr = mgr; break
	if is_instance_valid(_horde_mgr) and _horde_mgr.has_signal("selection_changed"):
		if _horde_mgr.selection_changed.is_connected(_on_selection_changed):
			_horde_mgr.selection_changed.disconnect(_on_selection_changed)
		_horde_mgr.selection_changed.connect(_on_selection_changed)

# ── MINIMIZE ─────────────────────────────────────────────────
func toggle_minimize() -> void:
	_minimized = not _minimized
	for ch in get_children():
		if ch == _min_bar: continue
		(ch as CanvasItem).visible = not _minimized
	if is_instance_valid(_min_bar):
		var lbl := _min_bar.get_node_or_null("MinLabel") as Label
		if is_instance_valid(lbl):
			lbl.text = "SQUAD  [M]  ▲" if _minimized else "SQUAD  [M]  ▼"
	var hud := get_tree().get_first_node_in_group("hud")
	if is_instance_valid(hud): hud.set("_squad_minimized", _minimized)

# ── BUILD UI ─────────────────────────────────────────────────
func _build_ui() -> void:
	mouse_filter  = Control.MOUSE_FILTER_IGNORE
	clip_contents = false

	# ── Title / minimize bar ──────────────────────────────────
	_min_bar = Panel.new(); _min_bar.name = "MinBar"
	_min_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_min_bar.offset_bottom = 22.0; _min_bar.offset_top = 0.0
	_min_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var bar_sty := StyleBoxFlat.new()
	bar_sty.bg_color = Color(0.06, 0.08, 0.14, 0.96)
	bar_sty.set_border_width_all(1); bar_sty.border_color = Color(0.2, 0.5, 0.9)
	_min_bar.add_theme_stylebox_override("panel", bar_sty)

	var min_lbl := Label.new(); min_lbl.name = "MinLabel"
	min_lbl.text = "SQUAD  [M]  ▼"
	min_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	min_lbl.add_theme_font_size_override("font_size", 10)
	min_lbl.add_theme_color_override("font_color", Color(0.6, 0.75, 1.0))
	min_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	min_lbl.offset_right = -22.0  # leave room for close button
	min_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_min_bar.add_child(min_lbl)

	# [X] close button — hides the panel entirely ([H] keybind mirrors this)
	var close_btn := Button.new(); close_btn.name = "CloseBtn"
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_btn.offset_left = -22.0; close_btn.offset_right  = 0.0
	close_btn.offset_top  =   0.0; close_btn.offset_bottom = 22.0
	close_btn.add_theme_font_size_override("font_size", 9)
	var csty := StyleBoxFlat.new()
	csty.bg_color = Color(0.55, 0.10, 0.10, 0.90); csty.set_corner_radius_all(2)
	close_btn.add_theme_stylebox_override("normal", csty)
	var chov := StyleBoxFlat.new()
	chov.bg_color = Color(0.85, 0.15, 0.15, 1.00); chov.set_corner_radius_all(2)
	close_btn.add_theme_stylebox_override("hover", chov)
	close_btn.pressed.connect(func(): visible = false)
	_min_bar.add_child(close_btn)

	_min_bar.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			toggle_minimize())
	add_child(_min_bar)

	# ── Main container ────────────────────────────────────────
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_top = 22.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.94)
	style.border_color = Color(0.15, 0.55, 0.32, 0.80)
	style.set_border_width_all(1)
	style.content_margin_left   = 6; style.content_margin_right  = 6
	style.content_margin_top    = 5; style.content_margin_bottom = 5
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	# ── Vertical column of controls ───────────────────────────
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)

	# Count label
	_count_label = Label.new()
	_count_label.text = "🧟 0 selected"
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", Color(0.35, 0.90, 0.55))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_count_label)

	# Select-All button
	_sel_btn = _make_btn("⬡ SELECT ALL [F]", C_SELECT, _on_select_all)
	_sel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_btn.custom_minimum_size   = Vector2(0.0, 26.0)
	_sel_btn.add_theme_font_size_override("font_size", 10)
	col.add_child(_sel_btn)

	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("color", Color(0.2, 0.5, 0.3, 0.5))
	col.add_child(sep1)

	# Command buttons — stacked vertically
	_atk_btn    = _make_btn("⚔ ATTACK   [1]", C_ATTACK, _on_attack)
	_def_btn    = _make_btn("🛡 DEFEND   [2]", C_DEFEND, _on_defend)
	_pat_btn    = _make_btn("↺ PATROL   [3]", C_PATROL, _on_patrol)
	_stay_btn   = _make_btn("■ HOLD     [4]", C_STAY,   _on_stay)
	_follow_btn = _make_btn("👤 FOLLOW   [5]", C_FOLLOW, _on_follow)
	for btn in [_atk_btn, _def_btn, _pat_btn, _stay_btn, _follow_btn]:
		(btn as Button).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		(btn as Button).custom_minimum_size   = Vector2(0.0, 28.0)
		(btn as Button).add_theme_font_size_override("font_size", 10)
		col.add_child(btn)

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", Color(0.2, 0.5, 0.3, 0.5))
	col.add_child(sep2)

	# Status label
	_status_label = Label.new()
	_status_label.text = "[H] hide  [M] minimize"
	_status_label.add_theme_font_size_override("font_size", 9)
	_status_label.add_theme_color_override("font_color", Color(0.55, 0.60, 0.70))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	col.add_child(_status_label)

	# Box-select overlay (attached to viewport in _attach_box_rect)
	_box_rect = ColorRect.new()
	_box_rect.color = Color(0.3, 0.7, 1.0, 0.14)
	_box_rect.visible = false
	_box_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	call_deferred("_attach_box_rect")

func _attach_box_rect() -> void:
	var vp := get_viewport()
	if is_instance_valid(vp): vp.add_child(_box_rect)
	else: get_tree().current_scene.add_child(_box_rect)

# ── INPUT ────────────────────────────────────────────────────
func _is_my_event(event: InputEvent) -> bool:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device == _device_id
	if event is InputEventKey:
		return _player_index == 0
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		return _player_index == 0
	return _device_id == -1 and _player_index == 0

func _input(event: InputEvent) -> void:
	if not _is_my_event(event): return

	# H hides/shows the panel regardless of player binding
	if event is InputEventKey and event.pressed and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_H:
			visible = not visible
			get_viewport().set_input_as_handled()
			return

	if not is_instance_valid(player): return
	var shop_open   = player.get("shop_open")          if "shop_open"          in player else false
	var talent_open = player.get("_talent_tree_open")  if "_talent_tree_open"  in player else false
	if shop_open or talent_open: return

	if event is InputEventKey and event.pressed and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_H:      visible = not visible;  get_viewport().set_input_as_handled()
			KEY_M:      toggle_minimize();      get_viewport().set_input_as_handled()
			KEY_F:      _on_select_all();       get_viewport().set_input_as_handled()
			KEY_1:      _on_attack();           get_viewport().set_input_as_handled()
			KEY_2:      _on_defend();           get_viewport().set_input_as_handled()
			KEY_3:      _on_patrol();           get_viewport().set_input_as_handled()
			KEY_4:      _on_stay();             get_viewport().set_input_as_handled()
			KEY_5:      _on_follow();           get_viewport().set_input_as_handled()
			KEY_ESCAPE: _cancel_pending();      get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed: _on_lmb_down(mb.position)
				else:          _on_lmb_up(mb.position)
			MOUSE_BUTTON_RIGHT:
				if mb.pressed: _cancel_pending()
	if event is InputEventMouseMotion and _box_selecting:
		_update_box((event as InputEventMouseMotion).position)

# ── BOX SELECT ───────────────────────────────────────────────
func _viewport_local(screen_pos: Vector2) -> Vector2:
	var vp := get_viewport()
	return screen_pos - vp.get_visible_rect().position if is_instance_valid(vp) else screen_pos

func _on_lmb_down(pos: Vector2) -> void:
	var local := _viewport_local(pos)
	if _pending_command != "":
		_execute_pending_at_screen(local); return
	_box_selecting = true; _box_start = local
	_box_rect.visible = true; _box_rect.position = local; _box_rect.size = Vector2.ZERO

func _on_lmb_up(pos: Vector2) -> void:
	if not _box_selecting: return
	var local := _viewport_local(pos)
	_box_selecting = false; _box_rect.visible = false
	if local.distance_to(_box_start) < BOX_DRAG_THRESHOLD:
		_select_at_point(local); return
	if not is_instance_valid(_horde_mgr): return
	var cam := _get_cam()
	if not is_instance_valid(cam): return
	var vp_size := get_viewport().get_visible_rect().size
	_horde_mgr.select_box(cam,
		Vector2(minf(_box_start.x, local.x)/vp_size.x, minf(_box_start.y, local.y)/vp_size.y),
		Vector2(maxf(_box_start.x, local.x)/vp_size.x, maxf(_box_start.y, local.y)/vp_size.y),
		_team_id)

func _update_box(pos: Vector2) -> void:
	if not is_instance_valid(_box_rect): return
	var local := _viewport_local(pos)
	_box_rect.position = Vector2(minf(_box_start.x, local.x), minf(_box_start.y, local.y))
	_box_rect.size     = Vector2(absf(local.x - _box_start.x), absf(local.y - _box_start.y))

func _select_at_point(sp: Vector2) -> void:
	var cam := _get_cam()
	if not is_instance_valid(cam): return
	var space := get_viewport().get_world_3d().direct_space_state
	if not space: return
	var query := PhysicsRayQueryParameters3D.create(
		cam.project_ray_origin(sp),
		cam.project_ray_origin(sp) + cam.project_ray_normal(sp) * RAY_LENGTH_SELECT)
	var hit := space.intersect_ray(query)
	if hit.is_empty(): return
	var node : Node = hit.get("collider") as Node
	while is_instance_valid(node) and node != get_tree().current_scene:
		if "team_id" in node and "health" in node and int(node.get("team_id")) == _team_id:
			if is_instance_valid(_horde_mgr):
				_horde_mgr.deselect_all()
				_horde_mgr.select_in_radius(node.global_position, 0.1, _team_id)
			return
		node = node.get_parent()

# ── PENDING ──────────────────────────────────────────────────
func _execute_pending_at_screen(sp: Vector2) -> void:
	var pos := _screen_to_ground(sp)
	if pos == Vector3.ZERO: _cancel_pending(); return
	match _pending_command:
		"attack":
			if is_instance_valid(_horde_mgr): _horde_mgr.command_attack(pos)
			_persist_selected_zombies("attack", pos)
			_set_status("⚔ Attacking!"); _pending_command = ""; _unhighlight_all()

func _cancel_pending() -> void:
	if _pending_command == "patrol_add" and not _patrol_waypoints.is_empty():
		if is_instance_valid(_horde_mgr): _horde_mgr.command_patrol(_patrol_waypoints)
		_persist_selected_zombies("patrol")
		_set_status("↺ Patrol: %d points set." % _patrol_waypoints.size())
		_patrol_waypoints.clear()
	_pending_command = ""; _in_patrol_set = false; _unhighlight_all()

# ── MAKE COMMANDS PERSISTENT ON ZOMBIES ──────────────────────
# Called after every command to mark selected zombies as persistent
# so the 1-second timeout in zombie.gd does NOT expire them.
func _persist_selected_zombies(cmd: String, pos: Vector3 = Vector3.ZERO) -> void:
	for z in _get_sel():
		if not is_instance_valid(z): continue
		if "squad_persistent" in z:
			z.set("squad_persistent", true)
			z.set("order_persistent", true)
		# Also directly call the typed command on the zombie for reliability
		match cmd:
			"attack":
				if z.has_method("command_attack_move"): z.command_attack_move(pos, true)
				elif z.has_method("command_attack_position"): z.command_attack_position(pos, true)
			"defend":
				if z.has_method("command_defend"): z.command_defend(true)
			"stay":
				if z.has_method("command_hold"): z.command_hold(true)
			"follow":
				if z.has_method("command_follow") and is_instance_valid(player):
					z.command_follow(player as Node3D, true)
			"patrol":
				if z.has_method("set_patrol_points"):
					z.set_patrol_points(_patrol_waypoints)
					z.set_ai_mode(4)  # AIMode.PATROL

# ── COMMANDS ─────────────────────────────────────────────────
func _on_select_all() -> void:
	var count : int = 0
	if is_instance_valid(_horde_mgr):
		_horde_mgr.select_all_team(_team_id)
		count = _horde_mgr.get_selected().size()
	if count == 0 and is_instance_valid(_horde_mgr):
		_horde_mgr.select_owned_by(_player_iid)
		count = _horde_mgr.get_selected().size()
	_set_status("🧟 %d zombies selected." % count)
	_refresh_count(count)

func _on_attack() -> void:
	_auto_select_if_empty()
	if _get_sel().is_empty(): _set_status("No zombies!"); return
	_cancel_pending()
	var nearest := _find_nearest_enemy()
	if is_instance_valid(nearest):
		if is_instance_valid(_horde_mgr): _horde_mgr.command_attack(nearest.global_position)
		_persist_selected_zombies("attack", nearest.global_position)
		_set_status("⚔ %d attacking!" % _get_sel().size())
	else:
		_set_status("⚔ Click target to attack…")
		_pending_command = "attack"; _highlight_btn(_atk_btn)

func _on_defend() -> void:
	_auto_select_if_empty()
	if _get_sel().is_empty(): _set_status("No zombies!"); return
	_cancel_pending()
	var base_pos := _get_base_pos()
	if base_pos == Vector3.ZERO and is_instance_valid(player):
		base_pos = (player as Node3D).global_position
	if is_instance_valid(_horde_mgr): _horde_mgr.command_defend(base_pos)
	_persist_selected_zombies("defend")
	_set_status("🛡 %d defending base!" % _get_sel().size())
	_highlight_btn(_def_btn)

func _on_patrol() -> void:
	_auto_select_if_empty()
	if _get_sel().is_empty(): _set_status("No zombies!"); return
	if not _in_patrol_set:
		_cancel_pending(); _in_patrol_set = true; _patrol_waypoints.clear()
		_pending_command = "patrol_add"
		_set_status("↺ Click waypoints. [3]/ESC to finish.")
		_highlight_btn(_pat_btn)
	else: _cancel_pending()

func _on_stay() -> void:
	_auto_select_if_empty()
	if _get_sel().is_empty(): _set_status("No zombies!"); return
	_cancel_pending()
	if is_instance_valid(_horde_mgr): _horde_mgr.command_stay()
	_persist_selected_zombies("stay")
	_set_status("■ %d holding position." % _get_sel().size())
	_unhighlight_all()

func _on_follow() -> void:
	_auto_select_if_empty()
	if _get_sel().is_empty(): _set_status("No zombies!"); return
	_cancel_pending()
	if is_instance_valid(_horde_mgr) and is_instance_valid(player):
		if _horde_mgr.has_method("command_follow_interrupt"):
			_horde_mgr.command_follow_interrupt(player as Node3D)
		else:
			_horde_mgr.command_follow(player as Node3D)
	_persist_selected_zombies("follow")
	_set_status("👤 %d following!" % _get_sel().size())
	_highlight_btn(_follow_btn)

func handle_gamepad_command(mode_index: int) -> void:
	match mode_index:
		0: _on_attack()
		1: _on_defend()
		2: _on_patrol()
		3: _on_stay()
		4: _on_follow()

# ── SIGNALS / HELPERS ────────────────────────────────────────
func _on_selection_changed(selected: Array) -> void: _refresh_count(selected.size())

func _get_sel() -> Array:
	if not is_instance_valid(_horde_mgr): return []
	return _horde_mgr.get_selected()

func _auto_select_if_empty() -> void:
	if not _get_sel().is_empty() or not is_instance_valid(_horde_mgr): return
	_horde_mgr.select_all_team(_team_id)
	if _horde_mgr.get_selected().is_empty():
		_horde_mgr.select_owned_by(_player_iid)

func _refresh_count(n: int = -1) -> void:
	if n < 0: n = _get_sel().size()
	if is_instance_valid(_count_label): _count_label.text = "🧟 %d selected" % n

func _set_status(text: String) -> void:
	if is_instance_valid(_status_label): _status_label.text = text

func _get_cam() -> Camera3D:
	if is_instance_valid(player):
		for path in ["CameraRoot/FPSPivot/FPSCamera","CameraRoot/FPSPivot/Camera3D",
					 "CameraRoot/TopDownPivot/TopDownCamera","Head/Camera3D"]:
			var cam := player.get_node_or_null(path) as Camera3D
			if is_instance_valid(cam) and cam.current: return cam
	return get_viewport().get_camera_3d()

func _screen_to_ground(sp: Vector2) -> Vector3:
	var cam := _get_cam()
	if not is_instance_valid(cam): return Vector3.ZERO
	var space := get_viewport().get_world_3d().direct_space_state
	if not space: return Vector3.ZERO
	var origin := cam.project_ray_origin(sp)
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + cam.project_ray_normal(sp) * RAY_LENGTH_GROUND)
	var hit    := space.intersect_ray(query)
	if not hit.is_empty(): return hit.get("position", Vector3.ZERO)
	var plane  := Plane(Vector3.UP, 0.0)
	var result : Variant = plane.intersects_ray(origin, cam.project_ray_normal(sp))
	return result if result != null else Vector3.ZERO

func _get_base_pos() -> Vector3:
	for base in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(base): continue
		if "team_id" in base and int(base.get("team_id")) == _team_id and base is Node3D:
			var b3d := base as Node3D
			return b3d.global_position + (-b3d.global_transform.basis.z) * DEFEND_RALLY_OFFSET
	return Vector3.ZERO

func _find_nearest_enemy() -> Node3D:
	if not is_instance_valid(player): return null
	var origin : Vector3 = (player as Node3D).global_position
	var best : Node3D; var best_d : float = ATTACK_SCAN_RADIUS
	for group in ["units","minions"]:
		for u in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(u) or not ("team_id" in u): continue
			if int(u.get("team_id")) == _team_id: continue
			if u.has_method("is_dead") and u.is_dead(): continue
			var d : float = origin.distance_to((u as Node3D).global_position)
			if d < best_d: best_d = d; best = u as Node3D
	return best

# ── BUTTON FACTORY ───────────────────────────────────────────
func _make_btn(text: String, color: Color, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text; btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	var normal := StyleBoxFlat.new()
	normal.bg_color = color * Color(1,1,1,0.68); normal.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("pressed", normal)
	var hover := StyleBoxFlat.new()
	hover.bg_color = color; hover.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("hover", hover)
	btn.pressed.connect(cb)
	return btn

func _highlight_btn(btn: Button) -> void:
	_unhighlight_all()
	if not is_instance_valid(btn): return
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.9,0.9,0.2,0.92); s.set_corner_radius_all(3)
	s.set_border_width_all(2); s.border_color = Color.WHITE
	btn.add_theme_stylebox_override("normal", s)

func _unhighlight_all() -> void:
	for pair in [[_atk_btn,C_ATTACK],[_def_btn,C_DEFEND],[_pat_btn,C_PATROL],
				 [_stay_btn,C_STAY],[_follow_btn,C_FOLLOW]]:
		var btn : Button = pair[0]
		if not is_instance_valid(btn): continue
		var s := StyleBoxFlat.new()
		s.bg_color = (pair[1] as Color) * Color(1,1,1,0.68); s.set_corner_radius_all(3)
		btn.add_theme_stylebox_override("normal", s)

# ── PUBLIC API ───────────────────────────────────────────────
func has_pending_command() -> bool: return _pending_command != ""
func get_count_label()    -> Label: return _count_label
func get_status_label()   -> Label: return _status_label
func set_player_index(idx: int)  -> void: _player_index = idx; name = "SquadCommandPanel_P%d" % idx
func reset_for_new_game() -> void:
	_pending_command = ""; _patrol_waypoints.clear(); _in_patrol_set = false; _unhighlight_all()
