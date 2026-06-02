# ============================================================
# GameOverScreen.gd
# ============================================================
# Add as an autoload OR child of your main scene.
# Call GameOverScreen.show_result(winning_team, local_team)
# from your base _on_died() handler.
# ============================================================
extends CanvasLayer

var _panel : Control = null
var _tween : Tween = null


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS  # buttons must work while tree is paused
	_build()
	_hide_screen()
	visible = true
	_panel.visible = false
	# Auto-hide when the scene changes so the panel never blocks the next scene
	get_tree().node_added.connect(func(node: Node):
		if node == get_tree().current_scene and is_instance_valid(_panel) and _panel.visible:
			_hide_screen())


func _build() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.88)
	_panel.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.anchor_top = 0.4  # Move up a bit
	vbox.anchor_bottom = 0.6
	vbox.add_theme_constant_override("separation", 28)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(vbox)

	var title := Label.new()
	title.name = "Title"
	title.text = ""
	title.add_theme_font_size_override("font_size", 96)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var sub := Label.new()
	sub.name = "Sub"
	sub.text = ""
	sub.add_theme_font_size_override("font_size", 28)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	vbox.add_child(btn_row)

	var btn_retry := _make_btn("↺  PLAY AGAIN", Color(0.15, 0.38, 0.22))
	var btn_menu  := _make_btn("⌂  MAIN MENU",  Color(0.12, 0.18, 0.28))
	var btn_quit  := _make_btn("✕  QUIT",        Color(0.25, 0.08, 0.08))
	btn_retry.pressed.connect(_on_retry)
	btn_menu.pressed.connect(_on_main_menu)
	btn_quit.pressed.connect(_on_quit)
	btn_row.add_child(btn_retry)
	btn_row.add_child(btn_menu)
	btn_row.add_child(btn_quit)


func _make_btn(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 60)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color", Color(0.95, 0.9, 0.85))
	
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(4)
	s.set_content_margin_all(12)
	b.add_theme_stylebox_override("normal", s)
	
	var h := StyleBoxFlat.new()
	h.bg_color = color.lightened(0.2)
	h.set_corner_radius_all(4)
	h.set_content_margin_all(12)
	b.add_theme_stylebox_override("hover", h)
	
	var p := StyleBoxFlat.new()
	p.bg_color = color.lightened(0.3)
	p.set_corner_radius_all(4)
	p.set_content_margin_all(12)
	b.add_theme_stylebox_override("pressed", p)
	
	return b


# Call this from your base _on_died():
# GameOverScreen.show_result(winning_team_id, local_player_team_id)
func show_result(winning_team: int, local_team: int) -> void:
	# Find nodes safely
	var title_node = _find_child_recursive(_panel, "Title")
	var sub_node = _find_child_recursive(_panel, "Sub")
	
	if not title_node or not sub_node:
		push_error("[GameOverScreen] Could not find UI nodes")
		return

	var won = (winning_team == local_team)

	if won:
		title_node.text = "MAP CLEARED!"
		title_node.add_theme_color_override("font_color", Color(1.0, 0.88, 0.2))
		sub_node.text = "Every hive, every zombie, every egg — gone.\nThe map is yours."
	else:
		title_node.text = "YOU FAILED"
		title_node.add_theme_color_override("font_color", Color(0.8, 0.1, 0.1))
		sub_node.text = "The night consumed you.\nThere is no hope here."

	# Kill any existing tween
	if _tween and _tween.is_valid():
		_tween.kill()
	
	# Show panel
	_panel.modulate.a = 0.0
	_panel.visible = true
	
	# Pause AFTER setting up visuals, but before tween
	get_tree().paused = true
	
	# Fade in
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.8)
	
	# Ensure mouse can interact with buttons
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	for child in _panel.get_children():
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if child is Button or (child is Control and child.get_child_count() > 0):
			_set_mouse_filter_recursive(child, Control.MOUSE_FILTER_STOP)


func _find_child_recursive(node: Node, name: String):
	"""Recursively find a child by name"""
	if node.name == name:
		return node
	for child in node.get_children():
		var found = _find_child_recursive(child, name)
		if found:
			return found
	return null


func _set_mouse_filter_recursive(node: Node, filter: int):
	"""Set mouse filter on node and all children"""
	if node is Control:
		(node as Control).mouse_filter = filter
	for child in node.get_children():
		_set_mouse_filter_recursive(child, filter)


func _hide_screen() -> void:
	if _panel:
		_panel.visible = false
		_panel.modulate.a = 0.0
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _reset_game_autoloads() -> void:
	var zhm := get_node_or_null("/root/ZombieHordeManager")
	if is_instance_valid(zhm) and zhm.has_method("reset_for_new_scene"):
		zhm.reset_for_new_scene()
	var ls := get_node_or_null("/root/LaneSpawner")
	if is_instance_valid(ls) and ls.has_method("reset"):
		ls.reset()
	var ff := get_node_or_null("/root/FlowFieldManager")
	if is_instance_valid(ff) and ff.has_method("reset"):
		ff.reset()
	var gs := get_node_or_null("/root/GameSettings")
	if is_instance_valid(gs) and gs.has_method("reset"):
		gs.reset()
	var ss := get_node_or_null("/root/Scenesetup")
	if is_instance_valid(ss):
		ss.set("_setup_done_for", "")
	# Reset CreepDeckUI static vote state so START works on replay
	for du in get_tree().get_nodes_in_group("creep_deck_ui"):
		if is_instance_valid(du) and du.has_method("reset_static"):
			du.call("reset_static")


func _on_retry() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	get_tree().paused = false
	_hide_screen()
	_reset_game_autoloads()
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	get_tree().paused = false
	_hide_screen()
	_reset_game_autoloads()
	for path in ["res://scenes/MainMenu.tscn", "res://MainMenu.tscn",
			"res://main_menu.tscn", "res://scenes/main_menu.tscn", "res://ui/MainMenu.tscn"]:
		if ResourceLoader.exists(path):
			get_tree().change_scene_to_file(path)
			return
	push_error("[GameOverScreen] Main menu scene not found at any known path")


func _on_quit() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	get_tree().paused = false
	get_tree().quit()
