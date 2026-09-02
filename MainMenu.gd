# ============================================================
# main_menu.gd  — reworked with Original / Versus mode select
# ============================================================
# Main panel has two primary mode buttons:
#   ORIGINAL MODE  — hive/egg wave defense, 1 player base, split-screen supported
#   VERSUS MODE    — base vs base, 2 bases, no hives, VS AI + split-screen
#
# Each mode opens its own sub-panel where player count (split-screen)
# and mode-specific options (AI, difficulty) are configured.
# ============================================================
extends Control

# ── Inspector exports ────────────────────────────────────────
@export var game_scene : PackedScene

@export var hover_sound : AudioStream

@export var game_title    : String = "SURVIVAL"
@export var game_subtitle : String = "ENTER THE DARK"

@export_range(0.0, 1.0, 0.05)
var default_music_volume : float = 0.8

# ── Panel state ───────────────────────────────────────────────
var _settings_open   : bool = false
var _orig_panel_open : bool = false
var _vs_panel_open   : bool = false

# ── Settings mirrors ─────────────────────────────────────────
var _master_volume : float = 1.0
var _music_volume  : float = 0.8
var _sfx_volume    : float = 1.0
var _fullscreen    : bool  = false

# ── Game config ───────────────────────────────────────────────
var _player_count     : int        = 1
var _ai_difficulty    : int        = 2
var _ai_enabled       : bool       = false
var _team_assignments : Dictionary = {}
var _game_mode        : String     = "original"   # "original" or "versus"

# ── Nodes ─────────────────────────────────────────────────────
var _hover_sfx      : AudioStreamPlayer

var _main_panel     : Control
var _settings_panel : Control
var _orig_panel     : Control   # original mode sub-panel
var _vs_panel       : Control   # versus mode sub-panel


# ════════════════════════════════════════════════════════════
# READY
# ════════════════════════════════════════════════════════════
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	Engine.time_scale  = 1.0
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.flush_buffered_events()
	randomize()

	_music_volume = default_music_volume
	_load_from_settings()
	_setup_hover_sfx()

	var mm := _music_manager()
	if mm:
		mm.set_volume(_music_volume)
		mm.enter_menu()

	_build_ui()
	_animate_in()


func _load_from_settings() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if not is_instance_valid(gs): return
	_ai_difficulty = gs.ai_difficulty
	_ai_enabled    = gs.ai_enabled
	_master_volume = gs.master_volume
	_music_volume  = gs.music_volume
	_sfx_volume    = gs.sfx_volume
	_fullscreen    = gs.fullscreen


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"): return
	if _settings_open:   _close_settings(); return
	if _orig_panel_open: _close_orig();     return
	if _vs_panel_open:   _close_vs();       return


# ════════════════════════════════════════════════════════════
# AUDIO
# ════════════════════════════════════════════════════════════
func _setup_hover_sfx() -> void:
	_hover_sfx = AudioStreamPlayer.new()
	_hover_sfx.bus       = "Master"
	_hover_sfx.volume_db = linear_to_db(_sfx_volume) - 6.0
	add_child(_hover_sfx)
	if hover_sound: _hover_sfx.stream = hover_sound

func _play_hover() -> void:
	if not hover_sound or not is_instance_valid(_hover_sfx): return
	_hover_sfx.stop(); _hover_sfx.play()

func _music_manager() -> Node:
	return get_node_or_null("/root/MusicManager")


# ════════════════════════════════════════════════════════════
# BUILD UI
# ════════════════════════════════════════════════════════════
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color        = Color(0.04, 0.05, 0.06)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vignette := ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.color        = Color(0.0, 0.0, 0.0, 0.45)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vignette)

	_main_panel     = _build_main_panel()
	_settings_panel = _build_settings_panel()
	_orig_panel     = _build_orig_panel()
	_vs_panel       = _build_vs_panel()

	_settings_panel.visible = false
	_orig_panel.visible     = false
	_vs_panel.visible       = false

	add_child(_main_panel)
	add_child(_settings_panel)
	add_child(_orig_panel)
	add_child(_vs_panel)


# ── Main panel ────────────────────────────────────────────────
func _build_main_panel() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bar := ColorRect.new()
	bar.color = Color(0.6, 0.15, 0.1)
	bar.set_anchor(SIDE_LEFT, 0.08);  bar.set_anchor(SIDE_RIGHT,  0.083)
	bar.set_anchor(SIDE_TOP,  0.18);  bar.set_anchor(SIDE_BOTTOM, 0.62)
	root.add_child(bar)

	var title := Label.new()
	title.name = "Title"; title.text = game_title
	title.add_theme_font_size_override("font_size", 92)
	title.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchor(SIDE_LEFT, 0.12); title.set_anchor(SIDE_RIGHT,  0.9)
	title.set_anchor(SIDE_TOP,  0.18); title.set_anchor(SIDE_BOTTOM, 0.38)
	title.modulate.a = 0.0
	root.add_child(title)

	var sub := Label.new()
	sub.name = "Subtitle"; sub.text = game_subtitle
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.6, 0.15, 0.1))
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub.set_anchor(SIDE_LEFT, 0.12); sub.set_anchor(SIDE_RIGHT,  0.9)
	sub.set_anchor(SIDE_TOP,  0.36); sub.set_anchor(SIDE_BOTTOM, 0.46)
	sub.modulate.a = 0.0
	root.add_child(sub)

	# BUG FIX (main-menu options cut off below the mode buttons, vault
	# ledger line 561): this VBoxContainer was previously anchored
	# directly (top 0.50 / bottom 0.92) with no wrapping ScrollContainer.
	# A VBoxContainer sizes itself to its children's combined minimum
	# size and does NOT clip or shrink to its anchor rect -- once enough
	# buttons/labels/separators existed (mode buttons + descriptions +
	# separator + Settings + Quit), the container's real height exceeded
	# the ~42%-of-window anchor band, and everything past that point
	# rendered off the bottom of the viewport with no way to reach it --
	# reproduced headlessly: at Godot's default 1152x648 window the QUIT
	# button's bottom edge sat at y=690 while the viewport height was
	# only 648. Wrapping it in a ScrollContainer makes the anchor rect
	# an actual clip+scroll region instead of an ignored suggestion, so
	# all options stay reachable (scrollable) at any window size instead
	# of clipped and unreachable.
	var btns_scroll := ScrollContainer.new()
	btns_scroll.name = "Buttons"
	btns_scroll.set_anchor(SIDE_LEFT, 0.12); btns_scroll.set_anchor(SIDE_RIGHT,  0.52)
	btns_scroll.set_anchor(SIDE_TOP,  0.50); btns_scroll.set_anchor(SIDE_BOTTOM, 0.97)
	btns_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	btns_scroll.modulate.a = 0.0
	root.add_child(btns_scroll)

	var btns := VBoxContainer.new()
	btns.name = "ButtonsList"
	btns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_theme_constant_override("separation", 14)
	btns_scroll.add_child(btns)

	# Mode separator label
	var mode_lbl := Label.new()
	mode_lbl.text = "SELECT MODE"
	mode_lbl.add_theme_font_size_override("font_size", 11)
	mode_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	btns.add_child(mode_lbl)

	var orig_btn := _make_button("🏰   ORIGINAL MODE", Color(0.15, 0.32, 0.18))
	orig_btn.pressed.connect(_open_orig)
	btns.add_child(orig_btn)

	# Desc under original
	var orig_desc := Label.new()
	orig_desc.text = "Survive hive waves  ·  deck-build your creeps  ·  1 – 4 players"
	orig_desc.add_theme_font_size_override("font_size", 11)
	orig_desc.add_theme_color_override("font_color", Color(0.45, 0.65, 0.45))
	btns.add_child(orig_desc)

	var vs_btn := _make_button("⚔   VERSUS MODE", Color(0.45, 0.12, 0.08))
	vs_btn.pressed.connect(_open_vs)
	btns.add_child(vs_btn)

	var vs_desc := Label.new()
	vs_desc.text = "Base vs base  ·  no hives  ·  VS AI or split-screen PvP"
	vs_desc.add_theme_font_size_override("font_size", 11)
	vs_desc.add_theme_color_override("font_color", Color(0.75, 0.40, 0.35))
	btns.add_child(vs_desc)

	var mp_btn := _make_button("🌐   MULTIPLAYER  (ONLINE CO-OP)", Color(0.12, 0.30, 0.44))
	mp_btn.pressed.connect(_open_multiplayer)
	btns.add_child(mp_btn)

	var mp_desc := Label.new()
	mp_desc.text = "Host or join by IP  ·  up to 4 players share one base  ·  LAN or port-forwarded internet"
	mp_desc.add_theme_font_size_override("font_size", 11)
	mp_desc.add_theme_color_override("font_color", Color(0.45, 0.64, 0.80))
	btns.add_child(mp_desc)

	btns.add_child(_hsep(Color(0.3, 0.3, 0.35, 0.5)))

	var settings_btn := _make_button("⚙   SETTINGS", Color(0.18, 0.18, 0.2))
	settings_btn.pressed.connect(_open_settings)
	btns.add_child(settings_btn)

	var quit_btn := _make_button("✕   QUIT", Color(0.1, 0.1, 0.12))
	quit_btn.pressed.connect(_on_quit)
	btns.add_child(quit_btn)

	return root


# ── Original mode panel ───────────────────────────────────────
func _build_orig_panel() -> Control:
	var root := Control.new()
	root.name = "OrigPanel"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var overlay := ColorRect.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color        = Color(0.0, 0.0, 0.0, 0.88)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -300; panel.offset_right  = 300
	panel.offset_top  = -240; panel.offset_bottom = 240
	var sbox := _panel_style(Color(0.15, 0.55, 0.25, 0.9))
	panel.add_theme_stylebox_override("panel", sbox)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	panel.add_child(vb)

	# Header
	var hdr := Label.new()
	hdr.text = "🏰  ORIGINAL MODE"
	hdr.add_theme_font_size_override("font_size", 30)
	hdr.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hdr)

	var desc := Label.new()
	desc.text = "Survive endless hive waves. Build a creep deck.\nDefend your castle — no enemy base exists."
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.65, 0.80, 0.65))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(desc)

	vb.add_child(_hsep(Color(0.2, 0.5, 0.25, 0.5)))

	# Player count
	var pc_row_lbl := Label.new()
	pc_row_lbl.text = "NUMBER OF PLAYERS  (split-screen)"
	pc_row_lbl.add_theme_font_size_override("font_size", 12)
	pc_row_lbl.add_theme_color_override("font_color", Color(0.5, 0.6, 0.5))
	pc_row_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(pc_row_lbl)

	var selected_orig := [1]   # mutable via closure
	var orig_pc_btns : Array[Button] = []

	var pc_row := HBoxContainer.new()
	pc_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pc_row.add_theme_constant_override("separation", 10)
	vb.add_child(pc_row)

	var _refresh_orig := func(n: int) -> void:
		for bi in orig_pc_btns.size():
			var pb := orig_pc_btns[bi]
			if not is_instance_valid(pb): continue
			var pbs := StyleBoxFlat.new()
			var is_sel : bool = (bi + 1) == n
			pbs.bg_color    = Color(0.14, 0.42, 0.20, 0.9) if is_sel else Color(0.06, 0.10, 0.08, 0.9)
			pbs.set_border_width_all(2)
			pbs.border_color = Color(0.3, 0.9, 0.4) if is_sel else Color(0.2, 0.35, 0.22)
			pbs.set_corner_radius_all(8)
			pb.add_theme_stylebox_override("normal", pbs)

	for n in [1, 2, 3, 4]:
		var btn := Button.new()
		btn.text = "%d" % n
		btn.custom_minimum_size = Vector2(68, 68)
		btn.add_theme_font_size_override("font_size", 26)
		btn.focus_mode = Control.FOCUS_NONE
		var _n : int = n
		btn.pressed.connect(func():
			selected_orig[0] = _n
			_refresh_orig.call(_n))
		pc_row.add_child(btn)
		orig_pc_btns.append(btn)
	_refresh_orig.call(1)

	vb.add_child(_hsep(Color(0.2, 0.5, 0.25, 0.4)))

	var hint := Label.new()
	hint.text = "P1 = Keyboard & Mouse  ·  P2-P4 = Controllers"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.4, 0.5, 0.4))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	vb.add_child(btn_row)

	var play_btn := _make_button("▶  PLAY", Color(0.12, 0.40, 0.18))
	play_btn.custom_minimum_size = Vector2(180, 54)
	play_btn.pressed.connect(func():
		_player_count     = selected_orig[0]
		_ai_enabled       = false
		_game_mode        = "original"
		_team_assignments = {}
		for pi in _player_count: _team_assignments[pi] = 1  # all players on team 1
		_close_orig()
		_launch())
	btn_row.add_child(play_btn)

	var back_btn := _make_button("← BACK", Color(0.12, 0.14, 0.18))
	back_btn.custom_minimum_size = Vector2(110, 54)
	back_btn.pressed.connect(_close_orig)
	btn_row.add_child(back_btn)

	return root


# ── Versus mode panel ─────────────────────────────────────────
func _build_vs_panel() -> Control:
	var root := Control.new()
	root.name = "VsPanel"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var overlay := ColorRect.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color        = Color(0.0, 0.0, 0.0, 0.88)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -320; panel.offset_right  = 320
	panel.offset_top  = -290; panel.offset_bottom = 290
	var sbox := _panel_style(Color(0.7, 0.15, 0.08, 0.9))
	panel.add_theme_stylebox_override("panel", sbox)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)

	# Header
	var hdr := Label.new()
	hdr.text = "⚔  VERSUS MODE"
	hdr.add_theme_font_size_override("font_size", 30)
	hdr.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hdr)

	var desc := Label.new()
	desc.text = "Two bases. Destroy the enemy castle.\nNo hives or eggs — pure PvP or PvAI."
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.80, 0.55, 0.50))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(desc)

	vb.add_child(_hsep(Color(0.6, 0.2, 0.1, 0.5)))

	# Player count
	var pc_row_lbl := Label.new()
	pc_row_lbl.text = "NUMBER OF PLAYERS  (split-screen)"
	pc_row_lbl.add_theme_font_size_override("font_size", 12)
	pc_row_lbl.add_theme_color_override("font_color", Color(0.60, 0.45, 0.40))
	pc_row_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(pc_row_lbl)

	var selected_vs := [2]
	var vs_pc_btns : Array[Button] = []

	var pc_row := HBoxContainer.new()
	pc_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pc_row.add_theme_constant_override("separation", 10)
	vb.add_child(pc_row)

	var _refresh_vs := func(n: int) -> void:
		for bi in vs_pc_btns.size():
			var pb := vs_pc_btns[bi]
			if not is_instance_valid(pb): continue
			var pbs := StyleBoxFlat.new()
			var is_sel : bool = (bi + 1) == n
			pbs.bg_color    = Color(0.45, 0.12, 0.06, 0.9) if is_sel else Color(0.10, 0.06, 0.05, 0.9)
			pbs.set_border_width_all(2)
			pbs.border_color = Color(1.0, 0.4, 0.2) if is_sel else Color(0.4, 0.2, 0.15)
			pbs.set_corner_radius_all(8)
			pb.add_theme_stylebox_override("normal", pbs)

	for n in [1, 2, 3, 4]:
		var btn := Button.new()
		btn.text = "%d" % n
		btn.custom_minimum_size = Vector2(68, 68)
		btn.add_theme_font_size_override("font_size", 26)
		btn.focus_mode = Control.FOCUS_NONE
		var _n : int = n
		btn.pressed.connect(func():
			selected_vs[0] = _n
			_refresh_vs.call(_n))
		pc_row.add_child(btn)
		vs_pc_btns.append(btn)
	_refresh_vs.call(2)

	vb.add_child(_hsep(Color(0.6, 0.2, 0.1, 0.4)))

	# ── VS AI section (inside versus mode only) ───────────────
	var ai_lbl := Label.new()
	ai_lbl.text = "VS AI"
	ai_lbl.add_theme_font_size_override("font_size", 12)
	ai_lbl.add_theme_color_override("font_color", Color(0.55, 0.45, 0.40))
	ai_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ai_lbl)

	var ai_row := HBoxContainer.new()
	ai_row.alignment = BoxContainer.ALIGNMENT_CENTER
	ai_row.add_theme_constant_override("separation", 10)
	vb.add_child(ai_row)

	var ai_state := [_ai_enabled]
	var ai_toggle_btn : Button

	var _diff_row := HBoxContainer.new()
	_diff_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_diff_row.add_theme_constant_override("separation", 6)

	var _refresh_diff := func() -> void:
		for child in _diff_row.get_children():
			if not (child is Button): continue
			var btn := child as Button
			var dv  := int(btn.name.replace("Diff_", ""))
			var active := dv == _ai_difficulty
			var s := StyleBoxFlat.new()
			s.bg_color = Color(0.45, 0.15, 0.08) if active else Color(0.12, 0.10, 0.10)
			s.set_corner_radius_all(3)
			for state in ["normal", "hover", "pressed", "focus"]:
				btn.add_theme_stylebox_override(state, s)
		_diff_row.visible = ai_state[0]

	ai_toggle_btn = _make_small_button("🤖 VS AI: %s" % ("ON" if _ai_enabled else "OFF"),
		Color(0.30, 0.18, 0.14) if _ai_enabled else Color(0.14, 0.14, 0.16))
	ai_toggle_btn.custom_minimum_size = Vector2(160, 36)
	ai_toggle_btn.pressed.connect(func():
		ai_state[0] = not ai_state[0]
		_ai_enabled  = ai_state[0]
		ai_toggle_btn.text = "🤖 VS AI: %s" % ("ON" if ai_state[0] else "OFF")
		_refresh_diff.call())
	ai_row.add_child(ai_toggle_btn)

	vb.add_child(_diff_row)

	for d in [["EASY",1,Color(0.1,0.4,0.15)], ["MEDIUM",2,Color(0.4,0.35,0.08)],
			  ["HARD",3,Color(0.45,0.15,0.08)], ["NIGHTMARE",4,Color(0.35,0.04,0.04)]]:
		var db := _make_diff_button(d[0], d[1], d[2])
		db.name = "Diff_%d" % d[1]
		var dv : int = d[1]
		db.pressed.connect(func(): _ai_difficulty = dv; _refresh_diff.call())
		_diff_row.add_child(db)
	_refresh_diff.call()

	vb.add_child(_hsep(Color(0.6, 0.2, 0.1, 0.4)))

	var hint := Label.new()
	hint.text = "P1 = Keyboard & Mouse  ·  P2-P4 = Controllers"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.45, 0.35, 0.32))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	vb.add_child(btn_row)

	var play_btn := _make_button("▶  PLAY VERSUS", Color(0.55, 0.12, 0.06))
	play_btn.custom_minimum_size = Vector2(200, 54)
	play_btn.pressed.connect(func():
		_player_count = selected_vs[0]
		_game_mode    = "versus"
		_ai_enabled   = ai_state[0]
		_team_assignments = {}
		# 2+ players: alternate teams 1 and 2
		for pi in _player_count: _team_assignments[pi] = (pi % 2) + 1
		_close_vs()
		_launch())
	btn_row.add_child(play_btn)

	var back_btn := _make_button("← BACK", Color(0.12, 0.14, 0.18))
	back_btn.custom_minimum_size = Vector2(110, 54)
	back_btn.pressed.connect(_close_vs)
	btn_row.add_child(back_btn)

	return root


# ── Settings panel ────────────────────────────────────────────
func _build_settings_panel() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	root.add_child(bg)

	var box := PanelContainer.new()
	box.set_anchor(SIDE_LEFT, 0.25); box.set_anchor(SIDE_RIGHT,  0.75)
	box.set_anchor(SIDE_TOP,  0.12); box.set_anchor(SIDE_BOTTOM, 0.88)
	box.add_theme_stylebox_override("panel", _panel_style(Color(0.6, 0.15, 0.1)))
	root.add_child(box)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	box.add_child(vbox)

	var hdr := Label.new()
	hdr.text = "SETTINGS"
	hdr.add_theme_font_size_override("font_size", 32)
	hdr.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)
	vbox.add_child(_hsep(Color(0.6, 0.15, 0.1, 0.6)))
	vbox.add_child(_make_slider_row("MASTER VOLUME", _master_volume, _on_master_volume_changed))
	vbox.add_child(_make_slider_row("MUSIC VOLUME",  _music_volume,  _on_music_volume_changed))
	vbox.add_child(_make_slider_row("SFX VOLUME",    _sfx_volume,    _on_sfx_volume_changed))

	var fs_row := HBoxContainer.new()
	var fs_lbl := Label.new()
	fs_lbl.text = "FULLSCREEN"
	fs_lbl.add_theme_font_size_override("font_size", 14)
	fs_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.65))
	fs_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fs_check := CheckButton.new()
	fs_check.button_pressed = _fullscreen
	fs_check.toggled.connect(func(on: bool):
		_fullscreen = on
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED))
	fs_row.add_child(fs_lbl)
	fs_row.add_child(fs_check)
	vbox.add_child(fs_row)
	vbox.add_child(_hsep(Color(0.6, 0.15, 0.1, 0.6)))

	var close_btn := _make_button("✕   CLOSE", Color(0.18, 0.18, 0.2))
	close_btn.pressed.connect(_close_settings)
	vbox.add_child(close_btn)
	return root


# ════════════════════════════════════════════════════════════
# PLAY / LAUNCH
# ════════════════════════════════════════════════════════════
func _launch() -> void:
	if not game_scene:
		push_warning("MainMenu: game_scene not assigned in Inspector")
		return

	var gs := get_node_or_null("/root/GameSettings")
	if is_instance_valid(gs):
		gs.reset()
		gs.player_count     = _player_count
		gs.team_assignments = _team_assignments.duplicate()
		gs.ai_enabled       = _ai_enabled
		gs.ai_difficulty    = _ai_difficulty
		gs.master_volume    = _master_volume
		gs.music_volume     = _music_volume
		gs.sfx_volume       = _sfx_volume
		gs.fullscreen       = _fullscreen
		gs.game_mode        = _game_mode

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.35)
	tw.tween_callback(func():
		Input.flush_buffered_events()
		get_tree().change_scene_to_packed(game_scene))


# ════════════════════════════════════════════════════════════
# OPEN / CLOSE PANELS
# ════════════════════════════════════════════════════════════
func _open_settings() -> void:
	_settings_open = true
	_settings_panel.visible   = true
	_settings_panel.modulate.a = 0.0
	create_tween().tween_property(_settings_panel, "modulate:a", 1.0, 0.2)

func _close_settings() -> void:
	_settings_open = false
	var tw := create_tween()
	tw.tween_property(_settings_panel, "modulate:a", 0.0, 0.15)
	tw.tween_callback(func(): _settings_panel.visible = false)

func _open_multiplayer() -> void:
	# Online co-op lobby (Host / Join by IP). Its own scene -- Scenesetup.gd
	# skips game setup for "lobby" scenes, and the lobby's own "Start Match"
	# loads main.tscn on every peer via NetworkManager.rpc_load_match().
	if ResourceLoader.exists("res://scenes/lobby.tscn"):
		get_tree().change_scene_to_file("res://scenes/lobby.tscn")
	else:
		push_error("[MainMenu] scenes/lobby.tscn missing")


func _open_orig() -> void:
	_orig_panel_open = true
	_orig_panel.visible   = true
	_orig_panel.modulate.a = 0.0
	create_tween().tween_property(_orig_panel, "modulate:a", 1.0, 0.2)

func _close_orig() -> void:
	_orig_panel_open = false
	var tw := create_tween()
	tw.tween_property(_orig_panel, "modulate:a", 0.0, 0.15)
	tw.tween_callback(func(): _orig_panel.visible = false)

func _open_vs() -> void:
	_vs_panel_open = true
	_vs_panel.visible   = true
	_vs_panel.modulate.a = 0.0
	create_tween().tween_property(_vs_panel, "modulate:a", 1.0, 0.2)

func _close_vs() -> void:
	_vs_panel_open = false
	var tw := create_tween()
	tw.tween_property(_vs_panel, "modulate:a", 0.0, 0.15)
	tw.tween_callback(func(): _vs_panel.visible = false)


# ════════════════════════════════════════════════════════════
# ANIMATE IN
# ════════════════════════════════════════════════════════════
func _animate_in() -> void:
	var title   := _main_panel.get_node("Title")   as Label
	var sub     := _main_panel.get_node("Subtitle") as Label
	var buttons := _main_panel.get_node("Buttons")  as Control
	var tw := create_tween()
	tw.tween_property(title,   "modulate:a", 1.0, 0.7)
	tw.tween_property(sub,     "modulate:a", 1.0, 0.5)
	tw.tween_property(buttons, "modulate:a", 1.0, 0.5)


# ════════════════════════════════════════════════════════════
# QUIT
# ════════════════════════════════════════════════════════════
func _on_quit() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func(): get_tree().quit())


# ════════════════════════════════════════════════════════════
# IN-GAME PAUSE USE (pause menu reuse)
# ════════════════════════════════════════════════════════════
func show_in_game() -> void:
	visible = true
	get_tree().paused = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.25)
	var mm := _music_manager()
	if mm: mm.enter_menu()

func hide_in_game() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.2)
	tw.tween_callback(func():
		visible = false
		get_tree().paused = false)
	var mm := _music_manager()
	if mm: mm.enter_game()


# ════════════════════════════════════════════════════════════
# VOLUME CALLBACKS
# ════════════════════════════════════════════════════════════
func _on_master_volume_changed(v: float) -> void:
	_master_volume = v
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(v))

func _on_music_volume_changed(v: float) -> void:
	_music_volume = v
	var mm := _music_manager()
	if mm: mm.set_volume(v)

func _on_sfx_volume_changed(v: float) -> void:
	_sfx_volume = v
	if is_instance_valid(_hover_sfx):
		_hover_sfx.volume_db = linear_to_db(v) - 6.0


# ════════════════════════════════════════════════════════════
# HELPERS
# ════════════════════════════════════════════════════════════
func _panel_style(border_color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.07, 0.08, 0.09, 0.97)
	s.border_color = border_color
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.content_margin_left   = 28
	s.content_margin_right  = 28
	s.content_margin_top    = 22
	s.content_margin_bottom = 22
	return s

func _hsep(col: Color) -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_color_override("color", col)
	return s

func _make_slider_row(label_text: String, initial: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.65))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var slider := HSlider.new()
	slider.min_value = 0.0; slider.max_value = 1.0; slider.step = 0.01
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(on_change)
	row.add_child(lbl)
	row.add_child(slider)
	return row

func _make_button(text: String, bg: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 54)
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	for sc in [["normal", bg], ["hover", bg.lightened(0.18)], ["pressed", bg.darkened(0.15)], ["focus", bg]]:
		var s := StyleBoxFlat.new()
		s.bg_color = sc[1]; s.set_corner_radius_all(3); s.content_margin_left = 24
		btn.add_theme_stylebox_override(sc[0], s)
	btn.mouse_entered.connect(_play_hover)
	return btn

func _make_small_button(text: String, bg: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 38)
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	var s := StyleBoxFlat.new(); s.bg_color = bg; s.set_corner_radius_all(3)
	for state in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, s)
	btn.mouse_entered.connect(_play_hover)
	return btn

func _make_diff_button(label: String, _dv: int, active_col: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(0, 36)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 11)
	btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
	var s := StyleBoxFlat.new()
	s.bg_color     = Color(0.12, 0.14, 0.16)
	s.border_color = active_col
	s.set_border_width_all(2)
	s.set_corner_radius_all(3)
	for state in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, s)
	btn.mouse_entered.connect(_play_hover)
	return btn
