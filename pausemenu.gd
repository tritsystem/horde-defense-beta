# ============================================================
# PauseMenu.gd - AUTOLOAD VERSION
# ============================================================
extends CanvasLayer

const C_BG     := Color(0.04, 0.05, 0.08, 0.92)
const C_BORDER := Color(0.6,  0.15, 0.10, 1.0)
const C_TEXT   := Color(0.92, 0.88, 0.82, 1.0)
const C_DIM    := Color(0.50, 0.52, 0.58, 1.0)
const C_RED    := Color(0.85, 0.18, 0.12, 1.0)

var menu_visible : bool = false
var enabled      : bool = true
var settings_open: bool = false
var _fps_preset_lbl : Label = null   # updated when preset changes

var master_vol : float = 1.0
var music_vol  : float = 0.8
var sfx_vol    : float = 1.0

var root              : Control
var _settings_wrapper : PanelContainer
var settings_panel    : VBoxContainer
var _help_wrapper     : PanelContainer = null
var _help_open        : bool           = false


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled and menu_visible:
		hide_menu()


# ── READY ────────────────────────────────────────────────────
func _ready() -> void:
	print("[PauseMenu] Autoload ready")
	layer        = 200
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_volumes()
	_build_ui()
	root.visible = false


func _load_volumes() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if not is_instance_valid(gs): return
	if "master_volume" in gs: master_vol = gs.master_volume
	if "music_volume"  in gs: music_vol  = gs.music_volume
	if "sfx_volume"    in gs: sfx_vol    = gs.sfx_volume


# ── INPUT ────────────────────────────────────────────────────
# Use _input (not _unhandled_input) so it fires even while tree is paused.
# PROCESS_MODE_ALWAYS on this CanvasLayer ensures we receive it.
func _input(event: InputEvent) -> void:
	if not enabled: return
	if not event.is_action_pressed("ui_cancel"): return
	get_viewport().set_input_as_handled()
	print("[PauseMenu] _input ui_cancel — menu_visible=%s" % str(menu_visible))
	if menu_visible:
		# Tree is paused — only PauseMenu (_input, PROCESS_MODE_ALWAYS) can handle this
		hide_menu()
	else:
		# Tree not paused — open the menu
		# (player.gd also does this but in case it didn't fire, handle it here too)
		show_menu()


# ── PUBLIC METHODS ───────────────────────────────────────────
func show_menu() -> void:
	if not enabled:
		print("[PauseMenu] show_menu blocked — disabled"); return
	if menu_visible:
		print("[PauseMenu] show_menu blocked — already visible"); return
	print("[PauseMenu] show_menu — opening")
	menu_visible = true
	if not is_instance_valid(root):
		push_error("[PauseMenu] root is null — _build_ui may have failed"); return
	root.visible = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func hide_menu() -> void:
	if not menu_visible: return
	print("[PauseMenu] Hiding menu")
	menu_visible = false
	root.visible = false
	_close_settings()
	_close_help()
	get_tree().paused = false
	_restore_mouse()


func toggle_menu() -> void:
	if menu_visible: hide_menu()
	else:            show_menu()


func _restore_mouse() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty(): return
	var p := players[0]
	var mode      = p.get("current_mode") if "current_mode" in p else null
	var shop_open = p.get("shop_open")    if "shop_open"    in p else false
	if mode == 0 and not shop_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ── BUILD UI ─────────────────────────────────────────────────
func _build_ui() -> void:
	root = Control.new()
	root.name = "PauseMenuRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(root)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	backdrop.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			hide_menu())
	root.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -200; panel.offset_right  = 200
	panel.offset_top  = -310; panel.offset_bottom = 310
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = C_BG
	sbox.set_border_width_all(2); sbox.border_color = C_BORDER
	sbox.set_corner_radius_all(8)
	sbox.content_margin_left = 24; sbox.content_margin_right  = 24
	sbox.content_margin_top  = 20; sbox.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", sbox)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", C_TEXT)
	vb.add_child(title)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", C_BORDER)
	vb.add_child(sep)

	_make_button(vb, "▶  RESUME",    C_RED,                    hide_menu)
	_make_button(vb, "📖  TUTORIAL", Color(0.14, 0.12, 0.03),  _toggle_tutorial)
	_make_button(vb, "❓  CONTROLS", Color(0.06, 0.16, 0.08),  toggle_help_overlay)
	_make_button(vb, "⚙  SETTINGS",  Color(0.18, 0.20, 0.26),  _toggle_settings)
	_make_button(vb, "↩  MAIN MENU", Color(0.14, 0.18, 0.28),  _go_main_menu)
	_make_button(vb, "✕  QUIT GAME", Color(0.10, 0.11, 0.13),  _quit)

	var hint := Label.new()
	hint.text = "[ESC] to resume"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", C_DIM)
	vb.add_child(hint)

	_build_settings_panel()
	_build_help_panel()
	print("[PauseMenu] UI built successfully")


func _make_button(parent: Control, text: String, bg_color: Color, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", C_TEXT)
	var n := StyleBoxFlat.new(); n.bg_color = bg_color; n.set_corner_radius_all(4); n.content_margin_left = 16
	var h := StyleBoxFlat.new(); h.bg_color = bg_color.lightened(0.18); h.set_corner_radius_all(4); h.content_margin_left = 16
	var p := StyleBoxFlat.new(); p.bg_color = bg_color.darkened(0.15);  p.set_corner_radius_all(4); p.content_margin_left = 16
	btn.add_theme_stylebox_override("normal",  n)
	btn.add_theme_stylebox_override("hover",   h)
	btn.add_theme_stylebox_override("pressed", p)
	btn.add_theme_stylebox_override("focus",   n)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn


func _build_settings_panel() -> void:
	_settings_wrapper = PanelContainer.new()
	_settings_wrapper.set_anchors_preset(Control.PRESET_CENTER)
	_settings_wrapper.offset_left = -220; _settings_wrapper.offset_right  = 220
	_settings_wrapper.offset_top  = -200; _settings_wrapper.offset_bottom = 200
	_settings_wrapper.mouse_filter = Control.MOUSE_FILTER_STOP
	_settings_wrapper.process_mode = Node.PROCESS_MODE_ALWAYS
	_settings_wrapper.visible = false
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.06, 0.07, 0.10, 0.98)
	sbox.set_border_width_all(2); sbox.border_color = Color(0.3, 0.5, 0.8)
	sbox.set_corner_radius_all(8)
	sbox.content_margin_left = 24; sbox.content_margin_right  = 24
	sbox.content_margin_top  = 18; sbox.content_margin_bottom = 18
	_settings_wrapper.add_theme_stylebox_override("panel", sbox)
	root.add_child(_settings_wrapper)

	settings_panel = VBoxContainer.new()
	settings_panel.name = "SettingsPanel"
	settings_panel.add_theme_constant_override("separation", 18)
	_settings_wrapper.add_child(settings_panel)

	var header := Label.new()
	header.text = "SETTINGS"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 24)
	header.add_theme_color_override("font_color", C_TEXT)
	settings_panel.add_child(header)

	settings_panel.add_child(_slider_row("MASTER", master_vol, _on_master_volume_changed, "MasterVolumeSlider"))
	settings_panel.add_child(_slider_row("MUSIC",  music_vol,  _on_music_volume_changed))
	settings_panel.add_child(_slider_row("SFX",    sfx_vol,    _on_sfx_volume_changed))

	var fs_row := HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 12)
	settings_panel.add_child(fs_row)
	var fs_lbl := Label.new()
	fs_lbl.text = "FULLSCREEN"
	fs_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fs_lbl.add_theme_font_size_override("font_size", 13)
	fs_lbl.add_theme_color_override("font_color", C_DIM)
	fs_row.add_child(fs_lbl)
	var fs_check := CheckButton.new()
	fs_check.process_mode = Node.PROCESS_MODE_ALWAYS
	fs_check.button_pressed = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	fs_check.toggled.connect(_on_fullscreen_toggled)
	fs_row.add_child(fs_check)

	# ── FPS Boost section ──────────────────────────────────────
	var fps_sep := HSeparator.new()
	fps_sep.add_theme_color_override("color", Color(0.2, 0.35, 0.55, 0.5))
	settings_panel.add_child(fps_sep)

	var fps_hdr := Label.new()
	fps_hdr.text = "FPS BOOST"
	fps_hdr.add_theme_font_size_override("font_size", 13)
	fps_hdr.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	settings_panel.add_child(fps_hdr)

	# Current preset display
	_fps_preset_lbl = Label.new()
	_fps_preset_lbl.add_theme_font_size_override("font_size", 11)
	_fps_preset_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 0.6))
	_fps_preset_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	settings_panel.add_child(_fps_preset_lbl)
	_update_fps_preset_label()

	# Preset buttons row
	var fps_row := HBoxContainer.new()
	fps_row.add_theme_constant_override("separation", 6)
	fps_row.alignment = BoxContainer.ALIGNMENT_CENTER
	settings_panel.add_child(fps_row)

	var preset_labels := ["⚡ ULTRA", "🔥 HIGH", "⚖ BALANCED", "✦ OFF"]
	var preset_colors := [
		Color(0.10, 0.28, 0.10),  # green tint - ultra (most aggressive)
		Color(0.18, 0.22, 0.10),  # yellow-green
		Color(0.22, 0.18, 0.08),  # amber
		Color(0.20, 0.08, 0.08),  # red - off (no boost)
	]
	for pi in preset_labels.size():
		var pb := Button.new()
		pb.text = preset_labels[pi]
		pb.add_theme_font_size_override("font_size", 11)
		pb.custom_minimum_size = Vector2(72, 36)
		pb.focus_mode = Control.FOCUS_NONE
		pb.process_mode = Node.PROCESS_MODE_ALWAYS
		var pn := StyleBoxFlat.new(); pn.bg_color = preset_colors[pi]; pn.set_corner_radius_all(4)
		var ph := pn.duplicate() as StyleBoxFlat; ph.bg_color = preset_colors[pi].lightened(0.2)
		pb.add_theme_stylebox_override("normal",  pn)
		pb.add_theme_stylebox_override("hover",   ph)
		pb.add_theme_stylebox_override("pressed", pn)
		pb.add_theme_stylebox_override("focus",   pn)
		var _pi := pi
		pb.pressed.connect(func(): _set_fps_preset(_pi))
		fps_row.add_child(pb)

	_make_button(settings_panel, "← BACK", Color(0.12, 0.14, 0.18), _close_settings).custom_minimum_size.y = 44


func _slider_row(label: String, initial: float, callback: Callable, slider_name: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var lbl := Label.new()
	lbl.text = label; lbl.custom_minimum_size.x = 72
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", C_DIM)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.0; slider.max_value = 1.0; slider.step = 0.01
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.process_mode = Node.PROCESS_MODE_ALWAYS
	if slider_name != "":
		slider.name = slider_name
	slider.value_changed.connect(callback)
	row.add_child(slider)
	return row


# ── SETTINGS HANDLERS ────────────────────────────────────────
func _on_master_volume_changed(value: float) -> void:
	master_vol = value
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(value))
	_save_volume("master_volume", value)

func _on_music_volume_changed(value: float) -> void:
	music_vol = value
	var mus := get_node_or_null("/root/MenuMusicPlayer") as AudioStreamPlayer
	if is_instance_valid(mus): mus.volume_db = linear_to_db(value)
	_save_volume("music_volume", value)

func _on_sfx_volume_changed(value: float) -> void:
	sfx_vol = value
	_save_volume("sfx_volume", value)

func _on_fullscreen_toggled(on: bool) -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)

func _save_volume(key: String, value: float) -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if is_instance_valid(gs) and key in gs: gs.set(key, value)

func _toggle_settings() -> void:
	settings_open = not settings_open
	if is_instance_valid(_settings_wrapper): _settings_wrapper.visible = settings_open

func _close_settings() -> void:
	settings_open = false
	if is_instance_valid(_settings_wrapper): _settings_wrapper.visible = false


# ── CONTROLS HELP OVERLAY ────────────────────────────────────
func toggle_help_overlay() -> void:
	_help_open = not _help_open
	if is_instance_valid(_help_wrapper): _help_wrapper.visible = _help_open

func _close_help() -> void:
	_help_open = false
	if is_instance_valid(_help_wrapper): _help_wrapper.visible = false


func _build_help_panel() -> void:
	_help_wrapper = PanelContainer.new()
	_help_wrapper.set_anchors_preset(Control.PRESET_CENTER)
	_help_wrapper.offset_left  = -270; _help_wrapper.offset_right  = 270
	_help_wrapper.offset_top   = -290; _help_wrapper.offset_bottom = 290
	_help_wrapper.mouse_filter = Control.MOUSE_FILTER_STOP
	_help_wrapper.process_mode = Node.PROCESS_MODE_ALWAYS
	_help_wrapper.visible = false
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.04, 0.07, 0.04, 0.98)
	sbox.set_border_width_all(2); sbox.border_color = Color(0.15, 0.55, 0.15)
	sbox.set_corner_radius_all(8)
	sbox.content_margin_left = 22; sbox.content_margin_right  = 22
	sbox.content_margin_top  = 16; sbox.content_margin_bottom = 16
	_help_wrapper.add_theme_stylebox_override("panel", sbox)
	root.add_child(_help_wrapper)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_help_wrapper.add_child(outer)

	var hdr := Label.new()
	hdr.text = "CONTROLS"
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", C_TEXT)
	outer.add_child(hdr)

	var div := HSeparator.new()
	div.add_theme_color_override("color", Color(0.15, 0.55, 0.15))
	outer.add_child(div)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	_help_section(vb, "MOVEMENT")
	_help_row(vb, "Move",            "W A S D",       "Left Stick")
	_help_row(vb, "Sprint",          "Hold Shift",    "L3")
	_help_row(vb, "Jump",            "Space",         "A")
	_help_row(vb, "Dash",            "Tap Shift",     "B")
	_help_row(vb, "Grapple",         "X",             "—")

	_help_section(vb, "COMBAT")
	_help_row(vb, "Shoot",           "Left Click",    "R2")
	_help_row(vb, "Aim",             "Right Click",   "L2")
	_help_row(vb, "Reload",          "R",             "X btn")
	_help_row(vb, "Weapon Switch",   "Scroll Wheel",  "D-Pad ←→")
	_help_row(vb, "Grenade",         "T",             "—")

	_help_section(vb, "CLASS ABILITIES")
	_help_row(vb, "Ability Slot",    "Q",             "LB")
	_help_row(vb, "Interact/Ability","E",             "—")
	_help_row(vb, "Class Skills",    "1 / 2 / 3 / 4", "—")
	_help_row(vb, "Ultimate",        "V",             "—")

	_help_section(vb, "INTERFACE")
	_help_row(vb, "Shop",            "Tab",           "Y")
	_help_row(vb, "Pause / Close",   "Esc",           "Start")

	_make_button(outer, "← BACK", Color(0.08, 0.12, 0.08), _close_help).custom_minimum_size.y = 40


func _help_section(parent: VBoxContainer, title: String) -> void:
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.35, 0.85, 0.35))
	parent.add_child(lbl)


func _help_row(parent: VBoxContainer, action: String, kb: String, pad: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var la := Label.new()
	la.text = action
	la.custom_minimum_size.x = 140
	la.add_theme_font_size_override("font_size", 12)
	la.add_theme_color_override("font_color", C_DIM)
	row.add_child(la)
	var lk := Label.new()
	lk.text = kb
	lk.custom_minimum_size.x = 110
	lk.add_theme_font_size_override("font_size", 12)
	lk.add_theme_color_override("font_color", C_TEXT)
	row.add_child(lk)
	var lp := Label.new()
	lp.text = pad
	lp.add_theme_font_size_override("font_size", 12)
	lp.add_theme_color_override("font_color", Color(0.50, 0.65, 0.80))
	row.add_child(lp)


# ── TUTORIAL ─────────────────────────────────────────────────
func _toggle_tutorial() -> void:
	var ts := get_node_or_null("/root/Tutorial")
	if not is_instance_valid(ts):
		for path in ["res://scripts/TutorialSystem.gd","res://TutorialSystem.gd"]:
			if ResourceLoader.exists(path):
				var scr := load(path) as Script
				var node := CanvasLayer.new()
				node.set_script(scr); node.name = "Tutorial"
				get_tree().root.add_child(node); ts = node; break
	if not is_instance_valid(ts):
		push_warning("[PauseMenu] Tutorial autoload not found (name=Tutorial)")
		return
	if ts.get("_visible") == true: ts.call("hide_tutorial")
	else:                           ts.call("show_tutorial")


# ── SCENE TRANSITIONS ────────────────────────────────────────
func _go_main_menu() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.flush_buffered_events()
	menu_visible = false
	root.visible = false
	_reset_autoloads_for_menu()
	for path in ["res://MainMenu.tscn","res://scenes/MainMenu.tscn",
				 "res://main_menu.tscn","res://scenes/main_menu.tscn","res://ui/MainMenu.tscn"]:
		if ResourceLoader.exists(path):
			get_tree().change_scene_to_file(path); return
	push_error("[PauseMenu] Main menu scene not found — add MainMenu.tscn to project root")


func _reset_autoloads_for_menu() -> void:
	var zhm := get_node_or_null("/root/ZombieHordeManager")
	if is_instance_valid(zhm) and zhm.has_method("reset_for_new_scene"):
		zhm.reset_for_new_scene()
	var ls := get_node_or_null("/root/LaneSpawner")
	if is_instance_valid(ls) and ls.has_method("reset"):
		ls.reset()
	var ff := get_node_or_null("/root/FlowFieldManager")
	if is_instance_valid(ff) and ff.has_method("reset"):
		ff.reset()
	var ss := get_node_or_null("/root/Scenesetup")
	if is_instance_valid(ss):
		ss.set("_setup_done_for", "")
	for du in get_tree().get_nodes_in_group("creep_deck_ui"):
		if is_instance_valid(du) and du.has_method("reset_static"):
			du.call("reset_static")


func _set_fps_preset(preset_idx: int) -> void:
	var booster := _find_fps_booster()
	if not is_instance_valid(booster):
		push_warning("[PauseMenu] FPSBooster node not found in scene")
		return
	if booster.has_method("_apply_preset") and "Preset" in booster:
		booster.call("_apply_preset", preset_idx)
	elif booster.has_method("_apply_preset"):
		booster.call("_apply_preset", preset_idx)
	_update_fps_preset_label()


func _update_fps_preset_label() -> void:
	if not is_instance_valid(_fps_preset_lbl): return
	var booster := _find_fps_booster()
	if not is_instance_valid(booster):
		_fps_preset_lbl.text = "FPSBooster not in scene"
		_fps_preset_lbl.add_theme_color_override("font_color", Color(0.6, 0.4, 0.4))
		return
	var preset_names := ["⚡ ULTRA (max FPS)", "🔥 HIGH", "⚖ BALANCED", "✦ OFF (full quality)"]
	var current : int = int(booster.get("_preset") if "_preset" in booster else 0)
	_fps_preset_lbl.text = "Current: %s" % preset_names[clampi(current, 0, preset_names.size()-1)]
	_fps_preset_lbl.add_theme_color_override("font_color",
		[Color(0.4, 0.9, 0.4), Color(0.8, 0.9, 0.4), Color(0.9, 0.75, 0.3), Color(0.7, 0.5, 0.5)][clampi(current, 0, 3)])


func _find_fps_booster() -> Node:
	# Search common locations
	for path in ["/root/FPSBooster", "/root/Game/FPSBooster"]:
		var n := get_node_or_null(path)
		if is_instance_valid(n): return n
	# Search by group
	var grouped := get_tree().get_nodes_in_group("fps_booster")
	if not grouped.is_empty(): return grouped[0]
	# Search by script name
	var found := get_tree().root.find_child("FPSBooster", true, false)
	if is_instance_valid(found): return found
	return null


func _quit() -> void:
	get_tree().quit()
