# ============================================================
# TurretUpgradePanel.gd
# ============================================================
# One instance lives inside each player's SubViewport (spawned
# by SplitScreenManager via _create_hud / bind_player).
# Never a singleton — each player owns their own panel.
#
# Controller bindings (all remappable in InputMap):
#   turret_panel   → T  /  Y button  (toggle)
#   turret_upgrade → U  /  R-Bumper
#   turret_repair  → R  /  L-Bumper
#
# Split-screen:
#   - Panel is inside the player's own SubViewport → no bleed
#   - _input() guards by device_id; joypad events only fire on
#     the correct pad; keyboard fires only for player_index == 0
#   - Crosshair: two crosshairs are drawn (one per SubViewport)
#     via _draw() on a full-rect Control child
# ============================================================
extends Panel

const PROXIMITY_RANGE  : float = 5.0
const CHECK_INTERVAL   : float = 0.15
const WORLD_OFFSET     : Vector3 = Vector3(0.0, 3.5, 0.0)
const PANEL_WIDTH      : float = 300.0
const FONT_SIZE_TITLE  : int = 17
const FONT_SIZE_STAT   : int = 13
const FONT_SIZE_BTN    : int = 14

# ── Player binding ────────────────────────────────────────
var player        : Node3D = null
var _player_index : int    = 0   # 0 = P1, 1 = P2 …
var _device_id    : int    = -1  # -1 = keyboard, ≥0 = joypad
var _team_id      : int    = 1
var gm            : Node   = null

# ── UI nodes ─────────────────────────────────────────────
var _title_lbl       : Label
var _level_lbl       : Label
var _health_lbl      : Label
var _damage_lbl      : Label
var _fire_rate_lbl   : Label
var _range_lbl       : Label
var _cost_lbl        : Label
var _max_lbl         : Label
var _upgrade_btn     : Button
var _repair_btn      : Button
var _repair_cost_lbl : Label
var _close_btn       : Button
var _hint_lbl        : Label
var _crosshair       : Control   # full-rect overlay drawn per-viewport

# ── State ─────────────────────────────────────────────────
var selected_turret  : Node3D = null
var _check_timer     : float  = 0.0
var _manually_closed : bool   = false


# ============================================================
# SETUP — call this immediately after instantiate()
# ============================================================
func bind_player(p: Node3D, player_idx: int, device_id: int) -> void:
	player        = p
	_player_index = player_idx
	_device_id    = device_id
	_team_id      = int(p.get("team_id") if "team_id" in p else 1)
	gm            = get_tree().get_first_node_in_group("game_manager")
	if not is_instance_valid(gm):
		push_warning("[TUP] P%d: game_manager not found." % (_player_index + 1))


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	add_to_group("turret_upgrade_panel")
	visible = false
	_build_layout()
	# _build_crosshair() -- disabled: HUD canvas_layer owns crosshair
	_ensure_input_actions()


# ============================================================
# INPUT ACTION REGISTRATION
# Registers keyboard + controller bindings if not already set
# in the project's InputMap.  Safe to call multiple times.
# ============================================================
func _ensure_input_actions() -> void:
	_add_action_if_missing("turret_panel",
		KEY_T, JOY_BUTTON_Y)
	_add_action_if_missing("turret_upgrade",
		KEY_U, JOY_BUTTON_RIGHT_SHOULDER)
	_add_action_if_missing("turret_repair",
		KEY_R, JOY_BUTTON_LEFT_SHOULDER)


func _add_action_if_missing(action: String, key: Key, pad_btn: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)

	# Keyboard
	var has_key  : bool = false
	var has_pad  : bool = false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey        and (ev as InputEventKey).keycode        == key:     has_key = true
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == pad_btn: has_pad = true

	if not has_key:
		var k := InputEventKey.new()
		k.keycode = key
		InputMap.action_add_event(action, k)

	if not has_pad:
		var j := InputEventJoypadButton.new()
		j.button_index = pad_btn
		InputMap.action_add_event(action, j)


# ============================================================
# CROSSHAIR — drawn inside the player's own SubViewport
# ============================================================
func _build_crosshair() -> void:
	_crosshair              = Control.new()
	_crosshair.name         = "Crosshair"
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.draw.connect(_draw_crosshair.bind(_crosshair))
	# Add to the SubViewport root, not to this panel
	call_deferred("_attach_crosshair")


func _attach_crosshair() -> void:
	# Walk up to find the SubViewport and add the crosshair there
	# so it always renders centered in this player's half-screen.
	var vp := get_viewport()
	if is_instance_valid(vp):
		vp.add_child(_crosshair)
	else:
		add_child(_crosshair)


func _draw_crosshair(ctrl: Control) -> void:
	var c   := ctrl.size * 0.5
	var col := Color(1.0, 1.0, 1.0, 0.85)
	var gap : float = 6.0
	var len : float = 14.0
	var w   : float = 2.0
	# Horizontal arms
	ctrl.draw_line(Vector2(c.x - gap - len, c.y), Vector2(c.x - gap, c.y), col, w)
	ctrl.draw_line(Vector2(c.x + gap,       c.y), Vector2(c.x + gap + len, c.y), col, w)
	# Vertical arms
	ctrl.draw_line(Vector2(c.x, c.y - gap - len), Vector2(c.x, c.y - gap), col, w)
	ctrl.draw_line(Vector2(c.x, c.y + gap),       Vector2(c.x, c.y + gap + len), col, w)
	# Centre dot
	ctrl.draw_circle(c, 2.0, col)


# ============================================================
# LAYOUT BUILD
# ============================================================
func _build_layout() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)

	var sty := StyleBoxFlat.new()
	sty.bg_color           = Color(0.06, 0.07, 0.13, 0.94)
	sty.border_color       = Color(0.35, 0.65, 1.0)
	sty.set_border_width_all(2)
	sty.set_corner_radius_all(8)
	sty.content_margin_left   = 14
	sty.content_margin_right  = 14
	sty.content_margin_top    = 12
	sty.content_margin_bottom = 12
	add_theme_stylebox_override("panel", sty)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 5)
	add_child(vbox)

	# ── Title row ────────────────────────────────────────
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(row)

	_title_lbl = Label.new()
	_title_lbl.text = "⚙ TURRET"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.add_theme_font_size_override("font_size", FONT_SIZE_TITLE)
	_title_lbl.add_theme_color_override("font_color", Color(0.4, 0.82, 1.0))
	row.add_child(_title_lbl)

	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.flat = true
	_close_btn.custom_minimum_size = Vector2(26.0, 26.0)
	_close_btn.add_theme_font_size_override("font_size", FONT_SIZE_TITLE)
	_close_btn.pressed.connect(_on_close)
	row.add_child(_close_btn)

	vbox.add_child(HSeparator.new())

	# ── Stats ─────────────────────────────────────────────
	_level_lbl     = _stat_lbl(); vbox.add_child(_level_lbl)
	_health_lbl    = _stat_lbl(); vbox.add_child(_health_lbl)
	_damage_lbl    = _stat_lbl(); vbox.add_child(_damage_lbl)
	_fire_rate_lbl = _stat_lbl(); vbox.add_child(_fire_rate_lbl)
	_range_lbl     = _stat_lbl(); vbox.add_child(_range_lbl)

	_max_lbl = Label.new()
	_max_lbl.text = "★  MAX LEVEL  ★"
	_max_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_max_lbl.add_theme_font_size_override("font_size", FONT_SIZE_STAT)
	_max_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_max_lbl.visible = false
	vbox.add_child(_max_lbl)

	vbox.add_child(HSeparator.new())

	# ── Upgrade ───────────────────────────────────────────
	_cost_lbl = Label.new()
	_cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cost_lbl.add_theme_font_size_override("font_size", FONT_SIZE_STAT)
	_cost_lbl.add_theme_color_override("font_color", Color(1.0, 0.88, 0.3))
	vbox.add_child(_cost_lbl)

	_upgrade_btn = _make_btn("⬆  Upgrade  [U / RB]", Color(0.12, 0.48, 0.12), _on_upgrade)
	vbox.add_child(_upgrade_btn)

	# ── Repair ────────────────────────────────────────────
	_repair_cost_lbl = Label.new()
	_repair_cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_repair_cost_lbl.add_theme_font_size_override("font_size", FONT_SIZE_STAT)
	_repair_cost_lbl.add_theme_color_override("font_color", Color(0.9, 0.6, 0.3))
	vbox.add_child(_repair_cost_lbl)

	_repair_btn = _make_btn("🔧  Repair  [R / LB]", Color(0.45, 0.28, 0.08), _on_repair)
	vbox.add_child(_repair_btn)

	# ── Hint ──────────────────────────────────────────────
	_hint_lbl = Label.new()
	_hint_lbl.text = "[ T / Y ] toggle panel"
	_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_lbl.add_theme_font_size_override("font_size", 10)
	_hint_lbl.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
	vbox.add_child(_hint_lbl)

	reset_size()


func _stat_lbl() -> Label:
	var l := Label.new()
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", FONT_SIZE_STAT)
	l.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	return l


func _make_btn(txt: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size   = Vector2(0.0, 34.0)
	b.add_theme_font_size_override("font_size", FONT_SIZE_BTN)
	b.pressed.connect(cb)

	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(5)
	b.add_theme_stylebox_override("normal", s)

	var sd := StyleBoxFlat.new()
	sd.bg_color = Color(0.22, 0.22, 0.22)
	sd.set_corner_radius_all(5)
	b.add_theme_stylebox_override("disabled", sd)

	return b


# ============================================================
# INPUT — isolated per player
# Keyboard events only fire for player_index == 0.
# Joypad events only fire when event.device == _device_id.
# Because this node lives inside its own SubViewport
# (handle_input_locally = true), events from other viewports
# never arrive here at all — this guard is a second safety net.
# ============================================================
func _is_my_event(event: InputEvent) -> bool:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device == _device_id
	# Keyboard / mouse belong to P1 only
	return _player_index == 0


func _input(event: InputEvent) -> void:
	if not _is_my_event(event):
		return

	# Use action names so both keyboard and controller trigger the same path
	if event.is_action_pressed("turret_panel"):
		if visible:
			_on_close()
		else:
			_manually_closed = false
			var t := _find_nearest_turret()
			if is_instance_valid(t):
				_open(t)
		get_viewport().set_input_as_handled()

	elif event.is_action_pressed("turret_upgrade"):
		if visible and is_instance_valid(selected_turret):
			_on_upgrade()
			get_viewport().set_input_as_handled()

	elif event.is_action_pressed("turret_repair"):
		if visible and is_instance_valid(selected_turret):
			_on_repair()
			get_viewport().set_input_as_handled()


# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	if visible and is_instance_valid(selected_turret):
		_reposition()
		_refresh_buttons()

	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = CHECK_INTERVAL

	# Lazy-find player / gm if not bound yet
	if not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("players") as Node3D
	if not is_instance_valid(player):
		return
	if not is_instance_valid(gm):
		gm = get_tree().get_first_node_in_group("game_manager")

	var nearest := _find_nearest_turret()
	if not is_instance_valid(nearest):
		if visible:
			_hide_panel()
		_manually_closed = false
		selected_turret  = null
		return

	if _manually_closed and nearest == selected_turret:
		return

	if nearest != selected_turret or not visible:
		_manually_closed = false
		_open(nearest)


# ============================================================
# WORLD-SPACE REPOSITIONING
# Uses only this player's SubViewport camera.
# ============================================================
func _reposition() -> void:
	var cam := get_viewport().get_camera_3d()
	if not is_instance_valid(cam):
		return
	var wp : Vector3 = selected_turret.global_position + WORLD_OFFSET
	if cam.is_position_behind(wp):
		modulate.a = 0.0
		return
	modulate.a      = 1.0
	var sp  : Vector2 = cam.unproject_position(wp)
	var vps : Vector2 = get_viewport().get_visible_rect().size
	position = Vector2(
		clampf(sp.x - size.x * 0.5, 4.0, vps.x - size.x - 4.0),
		clampf(sp.y - size.y - 8.0,  4.0, vps.y - size.y - 4.0)
	)


# ============================================================
# FIND NEAREST TURRET (team-filtered)
# ============================================================
func _find_nearest_turret() -> Node3D:
	if not is_instance_valid(player):
		return null
	var best   : Node3D
	var best_d : float = PROXIMITY_RANGE
	for t in get_tree().get_nodes_in_group("turrets"):
		if not (t is Node3D) or not is_instance_valid(t):
			continue
		if "team_id" in t and int(t.get("team_id")) != _team_id:
			continue
		var d : float = player.global_position.distance_to((t as Node3D).global_position)
		if d < best_d:
			best_d = d
			best   = t as Node3D
	return best


# ============================================================
# OPEN / CLOSE
# ============================================================
func _open(turret: Node3D) -> void:
	selected_turret = turret
	visible         = true
	_update_ui()
	reset_size()
	_reposition()


func open(turret: Node3D) -> void:
	_open(turret)


func close() -> void:
	selected_turret = null
	visible         = false


func _hide_panel() -> void:
	visible = false


func _on_close() -> void:
	_manually_closed = true
	_hide_panel()


# ============================================================
# UI REFRESH
# ============================================================
func _update_ui() -> void:
	if not is_instance_valid(selected_turret):
		visible = false
		return
	if not is_instance_valid(_title_lbl):
		return

	var t      := selected_turret
	var level  : int   = int(t.get("level"))     if "level"      in t else 1
	var maxlvl : int   = int(t.get("max_level")) if "max_level"  in t else 5
	var at_max : bool  = level >= maxlvl

	_title_lbl.text     = "⚙  TURRET  (Lv %d)" % level
	_level_lbl.text     = "Level:       %d / %d" % [level, maxlvl]

	var hp  : float = float(t.get("health"))     if "health"     in t else 0.0
	var mhp : float = float(t.get("max_health")) if "max_health" in t else 1.0
	_health_lbl.text    = "Health:      %.0f / %.0f" % [hp, mhp]
	_damage_lbl.text    = "Damage:      %.0f" % (float(t.get("damage"))    if "damage"    in t else 0.0)

	var fr  : float = float(t.get("fire_rate")) if "fire_rate" in t else 1.0
	_fire_rate_lbl.text = "Fire Rate:   %.2f / s" % (1.0 / maxf(fr, 0.01))
	_range_lbl.text     = "Range:       %.1f m"   % (float(t.get("range")) if "range"    in t else 0.0)

	_max_lbl.visible = at_max

	if at_max:
		_cost_lbl.text = "Fully Upgraded"
	else:
		var ucost : int = t.get_upgrade_cost() if t.has_method("get_upgrade_cost") else 0
		_cost_lbl.text = "Upgrade:  %d 💰  [U / RB]" % ucost
	_upgrade_btn.disabled = at_max

	var repair_cost : int   = int(t.get("repair_cost")) if "repair_cost" in t else 40
	var hp_ratio    : float = hp / maxf(mhp, 1.0)
	var needs_repair : bool = hp_ratio < 0.99
	_repair_cost_lbl.text    = "Repair:   %d 💰  [R / LB]  [%.0f%%]" % [repair_cost, hp_ratio * 100.0]
	_repair_cost_lbl.visible = needs_repair
	_repair_btn.visible      = needs_repair

	_refresh_buttons()
	reset_size()


func _refresh_buttons() -> void:
	if not is_instance_valid(_upgrade_btn) or not is_instance_valid(selected_turret):
		return
	var t    := selected_turret
	var gold : int = 0
	if is_instance_valid(gm) and gm.has_method("get_gold"):
		gold = gm.get_gold(int(t.get("team_id")) if "team_id" in t else 1)

	var level  : int = int(t.get("level"))     if "level"     in t else 1
	var maxlvl : int = int(t.get("max_level")) if "max_level" in t else 5
	if level < maxlvl and t.has_method("get_upgrade_cost"):
		_upgrade_btn.disabled = gold < t.get_upgrade_cost()

	var repair_cost : int   = int(t.get("repair_cost")) if "repair_cost" in t else 40
	var hp          : float = float(t.get("health"))    if "health"      in t else 0.0
	var mhp         : float = float(t.get("max_health"))if "max_health"  in t else 1.0
	_repair_btn.disabled = gold < repair_cost or hp >= mhp


# ============================================================
# UPGRADE / REPAIR
# ============================================================
func _on_upgrade() -> void:
	if not is_instance_valid(selected_turret):
		return
	var level  : int = int(selected_turret.get("level"))     if "level"     in selected_turret else 1
	var maxlvl : int = int(selected_turret.get("max_level")) if "max_level" in selected_turret else 5
	if level >= maxlvl:
		return
	if selected_turret.has_method("upgrade"):
		var ok : bool = selected_turret.upgrade()
		if ok:
			_update_ui()
		else:
			_flash_cant_afford(_upgrade_btn)


func _on_repair() -> void:
	if not is_instance_valid(selected_turret):
		return
	var hp  : float = float(selected_turret.get("health"))    if "health"     in selected_turret else 0.0
	var mhp : float = float(selected_turret.get("max_health"))if "max_health" in selected_turret else 1.0
	if hp >= mhp:
		return
	if selected_turret.has_method("repair"):
		var ok : bool = selected_turret.repair()
		if ok:
			_update_ui()
		else:
			_flash_cant_afford(_repair_btn)


# ============================================================
# VISUAL FEEDBACK
# ============================================================
func _flash_cant_afford(btn: Button) -> void:
	if not is_instance_valid(btn):
		return
	var orig  : StyleBoxFlat = btn.get_theme_stylebox("normal").duplicate() as StyleBoxFlat
	var flash := StyleBoxFlat.new()
	flash.bg_color = Color(0.6, 0.1, 0.1)
	flash.set_corner_radius_all(5)
	btn.add_theme_stylebox_override("normal", flash)
	get_tree().create_timer(0.35).timeout.connect(func() -> void:
		if is_instance_valid(btn):
			btn.add_theme_stylebox_override("normal", orig)
	, CONNECT_ONE_SHOT)
