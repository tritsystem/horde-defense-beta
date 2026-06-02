# ============================================================
# QuestHUD.gd — Attach to a Control node in your HUD scene
# Shows active quests top-right, completion flash center
# Press J (TOGGLE_KEY) to show/hide the panel.
# ============================================================
extends Control

var _player_id     : int  = 0
var _quest_mgr     : Node = null
var _quest_rows    : Array = []
var _vbox          : VBoxContainer
var _panel_visible : bool = true   # runtime show/hide state

const MAX_SHOW   := 3
# ── Change this to whatever key you prefer ──
const TOGGLE_KEY := KEY_J


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	anchor_left = 0.72; anchor_right  = 1.0
	anchor_top  = 0.02; anchor_bottom = 0.4
	offset_left = 0.0;  offset_right  = -8.0
	offset_top  = 0.0;  offset_bottom = 0.0
	z_index = 100

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 4)
	_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vbox)

	var hdr := Label.new()
	hdr.text = "◈ ACTIVE QUESTS  [J]"
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.add_child(hdr)

	_quest_mgr = get_tree().get_first_node_in_group("quest_manager")
	if is_instance_valid(_quest_mgr):
		_quest_mgr.quest_progress.connect(_on_progress)
		_quest_mgr.quest_completed.connect(_on_completed)
		_quest_mgr.new_quest_available.connect(_on_new_quests)


# ── Toggle visibility with J key ─────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.is_echo():
		if (event as InputEventKey).keycode == TOGGLE_KEY:
			_panel_visible = not _panel_visible
			visible = _panel_visible
			get_viewport().set_input_as_handled()


func bind_player(player: Node) -> void:
	if "player_id" in player:
		_player_id = int(player.get("player_id"))
	if is_instance_valid(_quest_mgr):
		_quest_mgr.register_player(_player_id)
		_refresh()


func _refresh() -> void:
	for r in _quest_rows: if is_instance_valid(r): r.queue_free()
	_quest_rows.clear()
	if not is_instance_valid(_quest_mgr): return
	var quests : Array = _quest_mgr.get_active_quests(_player_id)
	for q in quests.slice(0, MAX_SHOW):
		_add_quest_row(q)


func _add_quest_row(q: Dictionary) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.05, 0.06, 0.09, 0.88)
	sbox.set_border_width_all(1); sbox.border_color = Color(0.3, 0.3, 0.4, 0.6)
	sbox.set_corner_radius_all(3)
	sbox.content_margin_left = 6; sbox.content_margin_right  = 6
	sbox.content_margin_top  = 3; sbox.content_margin_bottom = 3
	panel.add_theme_stylebox_override("panel", sbox)
	panel.name = "QRow_" + q["id"]
	_vbox.add_child(panel)
	_quest_rows.append(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)

	var title := Label.new()
	title.text = "%s  %s" % [q.get("icon","◈"), q["label"]]
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.9, 0.88, 0.82))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	var prog := Label.new()
	var cur  : int = _quest_mgr.get_progress(_player_id, q["id"])
	prog.text = "  %d / %d   +%d🪙  +%d✦" % [cur, q["target"], q.get("reward_gold",0), q.get("reward_crystals",0)]
	prog.name = "Prog_" + q["id"]
	prog.add_theme_font_size_override("font_size", 10)
	prog.add_theme_color_override("font_color", Color(0.55, 0.7, 0.55))
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(prog)

	var bar_bg := ColorRect.new(); bar_bg.color = Color(0.15,0.15,0.18)
	bar_bg.custom_minimum_size = Vector2(0, 3)
	bar_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(bar_bg)
	var bar_fill := ColorRect.new(); bar_fill.color = Color(0.3, 0.85, 0.45)
	bar_fill.name = "Fill_" + q["id"]
	bar_fill.custom_minimum_size = Vector2(0, 3)
	bar_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_fill.anchor_right = clampf(float(cur) / float(maxi(q["target"],1)), 0.0, 1.0)
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(bar_fill)


func _on_progress(q: Dictionary, pid: int, current: int) -> void:
	if pid != _player_id: return
	var row := _vbox.find_child("QRow_" + q["id"], true, false)
	if not is_instance_valid(row): return
	var prog := row.find_child("Prog_" + q["id"], true, false) as Label
	if is_instance_valid(prog):
		prog.text = "  %d / %d   +%d🪙  +%d✦" % [current, q["target"], q.get("reward_gold",0), q.get("reward_crystals",0)]
	var fill := row.find_child("Fill_" + q["id"], true, false) as ColorRect
	if is_instance_valid(fill):
		fill.anchor_right = clampf(float(current) / float(maxi(q["target"],1)), 0.0, 1.0)


func _on_completed(q: Dictionary, pid: int) -> void:
	if pid != _player_id: return
	_show_completion_flash(q)
	_refresh()


func _on_new_quests(_quests: Array) -> void:
	_refresh()


func _show_completion_flash(q: Dictionary) -> void:
	var lbl := Label.new()
	lbl.text = "✦ QUEST COMPLETE: %s\n+%d🪙  +%d✦" % [q["label"], q.get("reward_gold",0), q.get("reward_crystals",0)]
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.offset_left = -250; lbl.offset_right = 250
	lbl.offset_top  = -40;  lbl.offset_bottom = 40
	lbl.z_index = 400; lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().root.add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - 40, 0.8).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.8).set_delay(0.9)
	tw.chain().tween_callback(lbl.queue_free)
