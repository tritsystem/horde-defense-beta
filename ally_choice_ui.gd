# ============================================================
# AllyChoiceUI.gd — listens for QuestManager.ally_choice_available and
# offers the player a real choice between a pack of rats (loot-scavenging +
# bonus damage) or a pack of bats (vampiric healing). See rat_ally.gd /
# bat_ally.gd for the actual unit behavior/stats.
#
# Add this as a child of the HUD (or an autoload) in the real player scene;
# it finds QuestManager and the requesting player itself via groups.
# ============================================================
extends CanvasLayer

const PACK_SIZE := 3
const SPAWN_RADIUS := 2.5

var _panel : Control = null

## Lets other scripts (player.gd's _unhandled_input mouse-recapture guard)
## check whether this panel is currently blocking gameplay, the same way
## they already check _class_selecting/_deck_open. See player.gd for the
## real bug this closes.
func is_choice_open() -> bool:
	return is_instance_valid(_panel)


func _ready() -> void:
	layer = 60
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if is_instance_valid(qm) and qm.has_signal("ally_choice_available"):
		qm.ally_choice_available.connect(_on_ally_choice_available)


func _on_ally_choice_available(pid: int) -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	_build_panel(pid)
	# REAL BUG FIX: this panel's "Choose" buttons were never clickable --
	# gameplay leaves the mouse MOUSE_MODE_CAPTURED (hidden, locked to
	# center) for FPS look, and nothing here ever released it, so the
	# cursor needed to actually click a card never appeared. Mirrors the
	# pattern player.gd's own notify_shop_state()/shopui.gd already use
	# for the shop panel.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _build_panel(pid: int) -> void:
	# _panel is the single root for this whole popup -- everything
	# (including the dim background) is parented under it, so one
	# _panel.queue_free() cleans up the entire thing with nothing leaked.
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(dim)

	var box := VBoxContainer.new()
	box.anchor_left = 0.25; box.anchor_right = 0.75
	box.anchor_top = 0.25; box.anchor_bottom = 0.75
	box.add_theme_constant_override("separation", 18)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "Call of the Wild — choose your allies"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	row.add_child(_build_choice_card(
		"🐀 Pack of Rats", Color(0.55, 0.42, 0.30),
		"Fast, scrappy fighters.\n+%d dmg/hit  •  %.0f%% bonus gold from nearby kills\n%d HP each" % [
			14, 35.0, 60],
		func(): _choose(pid, "rat")))

	row.add_child(_build_choice_card(
		"🦇 Pack of Bats", Color(0.35, 0.15, 0.45),
		"Flying, vampiric healers.\n%d dmg/hit  •  heals self + you on every hit\n%d HP each (squishier)" % [
			9, 45],
		func(): _choose(pid, "bat")))


func _build_choice_card(title_text: String, color: Color, desc: String, on_pick: Callable) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(240, 200)
	var style := StyleBoxFlat.new()
	style.bg_color = color.darkened(0.5)
	style.set_border_width_all(2)
	style.border_color = color
	style.set_corner_radius_all(10)
	style.content_margin_left = 14; style.content_margin_right = 14
	style.content_margin_top = 14; style.content_margin_bottom = 14
	card.add_theme_stylebox_override("panel", style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)

	var t := Label.new()
	t.text = title_text
	t.add_theme_font_size_override("font_size", 20)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)

	var d := Label.new()
	d.text = desc
	d.autowrap_mode = TextServer.AUTOWRAP_WORD
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(d)

	var btn := Button.new()
	btn.text = "Choose"
	btn.custom_minimum_size = Vector2(0, 36)
	btn.pressed.connect(on_pick)
	vb.add_child(btn)

	return card


func _choose(pid: int, kind: String) -> void:
	var player : Node3D = null
	for p in get_tree().get_nodes_in_group("player"):
		if "player_id" in p and int(p.get("player_id")) == pid:
			player = p as Node3D
			break
	if not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player") as Node3D

	if is_instance_valid(player):
		_spawn_pack(player, kind)

	if is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	# Restore FPS mouse-look now that the choice is made -- see the
	# matching set_mouse_mode(VISIBLE) in _on_ally_choice_available().
	if is_instance_valid(player) and int(player.get("device_id") if "device_id" in player else -1) == -1:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _spawn_pack(player: Node3D, kind: String) -> void:
	var script_path := "res://rat_ally.gd" if kind == "rat" else "res://bat_ally.gd"
	var team_id : int = int(player.get("team_id")) if "team_id" in player else 1
	for i in PACK_SIZE:
		var ally := CharacterBody3D.new()
		ally.set_script(load(script_path))
		var angle := (TAU / PACK_SIZE) * i
		var offset := Vector3(cos(angle), 0, sin(angle)) * SPAWN_RADIUS
		ally.global_position = player.global_position + offset
		# Bats use this every frame to hover at a distinct point around the
		# player/target instead of all converging on the same spot -- see
		# bat_ally.gd's hover_offset for the full story. Harmless no-op for
		# rats (rat_ally.gd has no such property, "hover_offset" in ally
		# there is just false).
		if "hover_offset" in ally:
			ally.set("hover_offset", offset)
		get_tree().current_scene.add_child(ally)
		ally.set("team_id", team_id)
		ally.set("owner_player", player)
