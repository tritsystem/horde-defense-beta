# ============================================================
# ClassSelectUI.gd
# Per-player class selection shown once at game start.
#
# Setup — caller MUST set these BEFORE add_child:
#   ui.set("player_id",     player_id)          # 1-based
#   ui.set("device_id",     device_id)          # -1=KBM, ≥0=gamepad
#   ui.set("viewport_size", quad_size)          # player's quadrant pixel size
#   ui.set("screen_offset", quad_pos)           # top-left of quadrant in screen coords
#
# This Control lives inside a CanvasLayer at layer 200 that is added to the
# ROOT Window (not inside any SubViewport). This guarantees:
#   • Mouse clicks reach it via the root Window GUI system (reliable)
#   • It renders above SubViewportContainers (layer -100) and all HUD layers
#
# Signal class_chosen(class_id: int) fires when confirmed.
# ============================================================
extends Control

signal class_chosen(class_id: int)

## Set by player.gd BEFORE add_child.
var player_id     : int     = 1
var device_id     : int     = -1      # -1 = KBM,  ≥0 = gamepad
var viewport_size : Vector2 = Vector2.ZERO   # quadrant pixel dimensions
var screen_offset : Vector2 = Vector2.ZERO   # top-left of this player's screen area

const CLASSES : Array = [
	{"id": 1,  "name": "Necromancer",  "icon": "💀", "color": Color(0.45, 0.0, 0.7),
	 "lore": "Master of the undead.\nRaise enemies as thralls\nand command an army.",
	 "abilities": ["Raise Dead", "Death Pulse", "Undead Army", "Spirit Walk"]},
	{"id": 2,  "name": "Berserker",    "icon": "⚔",  "color": Color(0.85, 0.1, 0.05),
	 "lore": "Unstoppable war machine.\nRage fuels devastation.\nDeath feeds the frenzy.",
	 "abilities": ["War Cry", "Bloodlust", "Ragnarok", "Savage Leap"]},
	{"id": 3,  "name": "Paladin",      "icon": "✨", "color": Color(0.9, 0.8, 0.15),
	 "lore": "Beacon of divine light.\nProtects allies, smites\nevil with holy fire.",
	 "abilities": ["Holy Smite", "Divine Shield", "Consecration", "Holy Charge"]},
	{"id": 4,  "name": "Shadowblade",  "icon": "🌑", "color": Color(0.3, 0.0, 0.5),
	 "lore": "Strike from the dark.\nVanish between kills.\nDeath has no echo.",
	 "abilities": ["Shadow Step", "Vanish", "Shadow Realm", "Blur"]},
	{"id": 5,  "name": "Stormcaller",  "icon": "⚡", "color": Color(0.95, 0.95, 0.15),
	 "lore": "Lightning given form.\nChain bolts cascade\nthrough enemy ranks.",
	 "abilities": ["Chain Lightning", "Storm Surge", "Thundergod", "Skyfall"]},
	{"id": 6,  "name": "Bloodmage",    "icon": "🩸", "color": Color(0.7, 0.0, 0.15),
	 "lore": "Pain is power.\nSpend life to end lives.\nBlood fuels every spell.",
	 "abilities": ["Blood Bolt", "Crimson Pact", "Hemorrhage", "Blood Surge"]},
	{"id": 7,  "name": "Timeweaver",   "icon": "⏳", "color": Color(0.25, 0.75, 1.0),
	 "lore": "Time bends to will.\nFreeze, rewind, unravel\nthe flow of battle.",
	 "abilities": ["Time Fracture", "Rewind", "Timestop", "Chrono Dash"]},
	{"id": 8,  "name": "Voidwalker",   "icon": "🌀", "color": Color(0.25, 0.0, 0.45),
	 "lore": "Between dimensions.\nUntouchable, inevitable.\nThe void consumes all.",
	 "abilities": ["Phase Shift", "Void Rift", "Annihilation", "Void Step"]},
	{"id": 9,  "name": "Ironclad",     "icon": "🛡", "color": Color(0.55, 0.6, 0.65),
	 "lore": "An impenetrable wall.\nAbsorb every blow,\nthen crush the attacker.",
	 "abilities": ["Iron Skin", "Taunt", "Unstoppable", "Shield Slam"]},
	{"id": 10, "name": "Plaguemaster", "icon": "☠",  "color": Color(0.15, 0.75, 0.1),
	 "lore": "Disease is art.\nInfect, spread, watch\nthe world rot away.",
	 "abilities": ["Infect", "Plague Cloud", "Pandemic", "Spore Burst"]},
	{"id": 11, "name": "Soulreaper",   "icon": "💀", "color": Color(0.6, 0.0, 0.9),
	 "lore": "Death is currency.\nCollect souls from the\nfallen, spend them wisely.",
	 "abilities": ["Soul Harvest", "Execute", "Soul Bomb", "Wraith Glide"]},
	{"id": 12, "name": "Warlock",      "icon": "🔮", "color": Color(0.55, 0.0, 0.85),
	 "lore": "Dark pacts, cursed power.\nSell your soul for\ndevastating magic.",
	 "abilities": ["Hex", "Dark Pact", "Demon Form", "Hellbolt Jump"]},
	{"id": 13, "name": "Phoenix",      "icon": "🔥", "color": Color(1.0, 0.4, 0.05),
	 "lore": "Death is just a pause.\nBurn the world down,\nrise from the ashes.",
	 "abilities": ["Flame Trail", "Rebirth", "Supernova", "Blazing Dash"]},
	{"id": 14, "name": "Gravemind",    "icon": "🧠", "color": Color(0.45, 0.8, 0.2),
	 "lore": "Commander of all undead.\nControl the hive,\nbend minds to your will.",
	 "abilities": ["Dominate", "Hive Mind", "Singularity", "Undertow"]},
	{"id": 15, "name": "Doomslayer",   "icon": "💥", "color": Color(0.95, 0.15, 0.0),
	 "lore": "Pure brutality incarnate.\nRip, tear, charge forward.\nEvery kill fuels the next.",
	 "abilities": ["Glory Kill", "Rip and Tear", "DOOM", "Rip Charge"]},
]

var _selected_id  : int    = -1
var _confirmed    : bool   = false
var _cards        : Array  = []
var _confirm_btn  : Button = null
var _desc_lbl     : Label  = null
var _ab_lbl       : Label  = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS

	# ── Size: use passed-in viewport_size, fall back to full window ────────────
	var vw : float
	var vh : float
	if viewport_size.x > 0.0 and viewport_size.y > 0.0:
		vw = viewport_size.x
		vh = viewport_size.y
	else:
		var vr := get_viewport_rect()
		vw = vr.size.x
		vh = vr.size.y

	# Position within the CanvasLayer so we occupy the correct screen quadrant.
	# screen_offset is the top-left corner of this player's SubViewportContainer.
	position = screen_offset
	size     = Vector2(vw, vh)

	print("[ClassSelectUI] P%d  pos=%s  size=%.0fx%.0f  device=%d" % [
		player_id, str(screen_offset), vw, vh, device_id])

	# ── Adaptive sizing ────────────────────────────────────────────────────────
	var title_fs  : int = clampi(int(vh * 0.05), 14, 40)
	var info_fs   : int = clampi(int(vh * 0.022), 10, 18)
	var card_cols : int = clampi(int(vw / 115.0), 3, 6)
	var card_min  : Vector2 = Vector2(
		maxf(70.0, (vw - 20.0) / card_cols - 8.0),
		maxf(90.0, vh * 0.13))

	# Background — absolute, covers entire quadrant
	var bg := ColorRect.new()
	bg.color        = Color(0.0, 0.0, 0.0, 0.96)
	bg.position     = Vector2.ZERO
	bg.size         = Vector2(vw, vh)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── Title ──────────────────────────────────────────────────────────────────
	var title_h : float = vh * 0.09
	var title   := Label.new()
	title.text      = "P%d: CHOOSE YOUR CLASS" % player_id
	title.position  = Vector2.ZERO
	title.size      = Vector2(vw, title_h)
	title.add_theme_font_size_override("font_size", title_fs)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	# ── Card grid ──────────────────────────────────────────────────────────────
	var grid := GridContainer.new()
	grid.columns  = card_cols
	grid.position = Vector2(vw * 0.01, title_h)
	grid.size     = Vector2(vw * 0.98, vh * 0.63)
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(grid)

	for cd in CLASSES:
		var card := _make_card(cd, card_min)
		grid.add_child(card)
		_cards.append(card)

	# ── Bottom info panel ──────────────────────────────────────────────────────
	var info_y : float = vh * 0.72
	var info_h : float = vh - info_y
	var info_pad : float = 10.0

	var info_bg := Panel.new()
	info_bg.position = Vector2(0.0, info_y)
	info_bg.size     = Vector2(vw, info_h)
	var info_style := StyleBoxFlat.new()
	info_style.bg_color = Color(0.06, 0.06, 0.1, 0.95)
	info_style.set_border_width_all(1)
	info_style.border_color = Color(0.3, 0.3, 0.4)
	info_bg.add_theme_stylebox_override("panel", info_style)
	add_child(info_bg)

	var info_hbox := HBoxContainer.new()
	info_hbox.position = Vector2(info_pad, info_pad)
	info_hbox.size     = Vector2(vw - info_pad * 2.0, info_h - info_pad * 2.0)
	info_hbox.add_theme_constant_override("separation", 20)
	info_bg.add_child(info_hbox)

	var desc_wrap := VBoxContainer.new()
	desc_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_hbox.add_child(desc_wrap)

	_desc_lbl = Label.new()
	_desc_lbl.text = "Use D-Pad / Left Stick to navigate.  Press A to confirm." \
		if device_id >= 0 else "Tab / Arrow keys to browse   •   Enter to select   •   Enter again to confirm."
	_desc_lbl.add_theme_font_size_override("font_size", info_fs)
	_desc_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	_desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_wrap.add_child(_desc_lbl)

	_ab_lbl = Label.new()
	_ab_lbl.text = ""
	_ab_lbl.add_theme_font_size_override("font_size", maxi(info_fs - 2, 10))
	_ab_lbl.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	_ab_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_wrap.add_child(_ab_lbl)

	# Confirm button — KBM only
	_confirm_btn = Button.new()
	_confirm_btn.text = "CONFIRM CLASS"
	_confirm_btn.custom_minimum_size = Vector2(
		clampi(int(vw * 0.3), 120, 200),
		clampi(int(vh * 0.07), 36, 56))
	_confirm_btn.add_theme_font_size_override("font_size", clampi(int(vh * 0.03), 12, 20))
	_confirm_btn.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	_confirm_btn.disabled     = true
	_confirm_btn.focus_mode   = Control.FOCUS_ALL
	_confirm_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.85, 0.75, 0.1)
	bs.set_corner_radius_all(4)
	bs.set_content_margin_all(10)
	_confirm_btn.add_theme_stylebox_override("normal", bs)
	var bh := bs.duplicate() as StyleBoxFlat
	bh.bg_color = Color(1.0, 0.9, 0.2)
	_confirm_btn.add_theme_stylebox_override("hover", bh)
	var bf := bs.duplicate() as StyleBoxFlat
	bf.bg_color = Color(1.0, 0.9, 0.2)
	bf.border_color = Color(1.0, 1.0, 1.0, 0.9)
	bf.set_border_width_all(3)
	_confirm_btn.add_theme_stylebox_override("focus", bf)
	_confirm_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(_on_confirm)
	if device_id >= 0:
		_confirm_btn.visible = false
	info_hbox.add_child(_confirm_btn)

	if _cards.size() > 0 and is_instance_valid(_cards[0]):
		(_cards[0] as Control).grab_focus()

	_set_gamepad_nav(true)


# ── Helpers ───────────────────────────────────────────────────

func _set_gamepad_nav(active: bool) -> void:
	if device_id < 0: return
	var gnav := get_node_or_null("/root/GamepadUINavigator")
	if is_instance_valid(gnav) and gnav.has_method("set_ui_active"):
		gnav.set_ui_active(device_id, active)


# ── Card factory ──────────────────────────────────────────────

func _make_card(cd: Dictionary, card_min_size: Vector2 = Vector2(130, 170)) -> Control:
	var btn := Button.new()
	btn.custom_minimum_size   = card_min_size
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	btn.focus_mode   = Control.FOCUS_ALL
	btn.mouse_filter = Control.MOUSE_FILTER_STOP

	var sn := StyleBoxFlat.new()
	sn.bg_color     = Color(cd.color.r * 0.25, cd.color.g * 0.25, cd.color.b * 0.25, 0.9)
	sn.border_color = cd.color
	sn.set_border_width_all(2); sn.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal", sn)

	var sh := StyleBoxFlat.new()
	sh.bg_color     = Color(cd.color.r * 0.45, cd.color.g * 0.45, cd.color.b * 0.45, 1.0)
	sh.border_color = cd.color.lightened(0.4)
	sh.set_border_width_all(3); sh.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("hover", sh)

	var sf := StyleBoxFlat.new()
	sf.bg_color     = Color(cd.color.r * 0.45, cd.color.g * 0.45, cd.color.b * 0.45, 1.0)
	sf.border_color = Color(1.0, 1.0, 0.3, 1.0)
	sf.set_border_width_all(4); sf.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("focus", sf)

	var sp := StyleBoxFlat.new()
	sp.bg_color     = cd.color.darkened(0.1)
	sp.border_color = Color(1.0, 1.0, 1.0, 0.9)
	sp.set_border_width_all(3); sp.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("pressed", sp)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.add_child(vb)

	var icon_fs : int = clampi(int(card_min_size.y * 0.28), 14, 28)
	var name_fs : int = clampi(int(card_min_size.y * 0.13), 8, 13)

	var icon_lbl := Label.new()
	icon_lbl.text = cd.icon
	icon_lbl.add_theme_font_size_override("font_size", icon_fs)
	icon_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	vb.add_child(icon_lbl)

	var name_lbl := Label.new()
	name_lbl.text = cd.name
	name_lbl.add_theme_font_size_override("font_size", name_fs)
	name_lbl.add_theme_color_override("font_color", cd.color.lightened(0.3))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_lbl)

	btn.pressed.connect(_on_card_selected.bind(cd, btn))
	btn.set_meta("class_data", cd)
	return btn


# ── Callbacks ─────────────────────────────────────────────────

func _on_card_selected(cd: Dictionary, _btn: Button) -> void:
	_selected_id = cd.id

	for c in _cards:
		if not is_instance_valid(c) or not c.has_meta("class_data"): continue
		var d : Dictionary = c.get_meta("class_data")
		var is_sel : bool  = d.id == _selected_id
		var sn2 := StyleBoxFlat.new()
		sn2.bg_color     = d.color.darkened(0.1) if is_sel else Color(d.color.r * 0.25, d.color.g * 0.25, d.color.b * 0.25, 0.9)
		sn2.border_color = Color(1.0, 1.0, 1.0, 0.9) if is_sel else d.color
		sn2.set_border_width_all(3 if is_sel else 2)
		sn2.set_corner_radius_all(4)
		(c as Button).add_theme_stylebox_override("normal", sn2)

	if is_instance_valid(_desc_lbl):
		_desc_lbl.text = "%s  %s\n\n%s" % [cd.icon, cd.name, cd.lore]
		_desc_lbl.add_theme_color_override("font_color", cd.color.lightened(0.3))
	if is_instance_valid(_ab_lbl):
		var al : Array = cd.abilities
		_ab_lbl.text = "[1] %s   [2] %s   [3] %s   [4] %s (MOVE)" % [al[0], al[1], al[2], al[3]]

	if is_instance_valid(_confirm_btn):
		_confirm_btn.disabled = false
		if device_id < 0:
			_confirm_btn.grab_focus()

	if device_id >= 0:
		_on_confirm()


func _on_confirm() -> void:
	if _selected_id < 0 or _confirmed: return
	_confirmed = true
	_set_gamepad_nav(false)
	class_chosen.emit(_selected_id)
	# Parent CanvasLayer (_class_select_ui in player.gd) will be freed by
	# _on_class_chosen, which takes this node with it.
