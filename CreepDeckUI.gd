# ============================================================
# CreepDeckUI.gd — REWORK v2
# ============================================================
# ARCHITECTURE:
#   • Added to get_tree().root so it sits in the main viewport.
#   • Mouse clicks route through Button.pressed signals (unchanged).
#   • Controller input uses _unhandled_input + per-device guard.
#   • Left-stick axis uses a cooldown so one tilt = one move.
#   • _on_confirm and card-visual helpers are all guard-safe.
#   • Static shared-vote state is reset by the first player only.
# ============================================================
extends Control

signal deck_confirmed(player_id: int, deck: Array)
signal vote_cast(player_id: int, voted_ids: Array)

# ── CONSTANTS ─────────────────────────────────────────────────
const DECK_SIZE := 5

const C_GOLD     := Color(0.95, 0.80, 0.20, 1.0)
const C_GREEN    := Color(0.20, 0.88, 0.42, 1.0)
const C_DIM      := Color(0.48, 0.50, 0.56, 1.0)
const C_BG       := Color(0.03, 0.04, 0.07, 0.97)
const C_CARD_BG  := Color(0.07, 0.09, 0.13, 0.95)
const C_CARD_SEL := Color(0.06, 0.18, 0.10, 0.98)
const C_BORDER   := Color(0.24, 0.28, 0.38, 1.0)
const C_SEL_BRD  := Color(0.20, 0.90, 0.40, 1.0)

const CREEP_CATALOGUE: Array = [
	{"id":"zombie",      "name":"Zombie",      "tier":"base",     "cost":50,  "icon":"🧟", "desc":"Basic melee lane pusher.",     "stats":{"hp":350,  "dmg":15, "spd":4}, "tags":["swarm", "lane"]},
	{"id":"tank",        "name":"Tank",         "tier":"base",     "cost":150, "icon":"🛡",  "desc":"High HP. Taunts enemies.",    "stats":{"hp":1200, "dmg":20, "spd":2}, "tags":["frontline", "taunt"]},
	{"id":"berserker",   "name":"Berserker",    "tier":"base",     "cost":120, "icon":"⚡", "desc":"Enrages below 40% HP.",        "stats":{"hp":420,  "dmg":27, "spd":5}, "tags":["dps", "berserk"]},
	{"id":"shaman",      "name":"Shaman",       "tier":"base",     "cost":130, "icon":"💚", "desc":"Heals allies, poisons foes.",  "stats":{"hp":300,  "dmg":10, "spd":3}, "tags":["support", "heal"]},
	{"id":"leaper",      "name":"Leaper",       "tier":"base",     "cost":100, "icon":"🦘", "desc":"Jumps 12m to target.",         "stats":{"hp":245,  "dmg":12, "spd":6}, "tags":["flanker", "mobility"]},
	{"id":"bomber",      "name":"Bomber",       "tier":"advanced", "cost":200, "icon":"💣", "desc":"AoE explosion on death.",      "stats":{"hp":280,  "dmg":45, "spd":4}, "tags":["aoe", "death"]},
	{"id":"ghost",       "name":"Ghost",        "tier":"advanced", "cost":180, "icon":"👻", "desc":"Phases through walls.",        "stats":{"hp":210,  "dmg":15, "spd":5}, "tags":["stealth", "bypass"]},
	{"id":"goliath",     "name":"Goliath",      "tier":"advanced", "cost":350, "icon":"🗿", "desc":"Massive juggernaut.",          "stats":{"hp":1750, "dmg":18, "spd":2}, "tags":["frontline", "tank"]},
	{"id":"assassin",    "name":"Assassin",     "tier":"advanced", "cost":220, "icon":"🗡",  "desc":"Targets players directly.",   "stats":{"hp":280,  "dmg":37, "spd":6}, "tags":["flanker", "dps"]},
	{"id":"hunter",      "name":"Hunter",       "tier":"advanced", "cost":160, "icon":"🏹", "desc":"Ranged, kites enemies.",       "stats":{"hp":260,  "dmg":22, "spd":5}, "tags":["ranged", "kite"]},
	{"id":"necromancer", "name":"Necromancer",  "tier":"advanced", "cost":300, "icon":"💀", "desc":"Raises slain enemies.",        "stats":{"hp":320,  "dmg":14, "spd":3}, "tags":["support", "swarm"]},
	{"id":"titan",       "name":"Titan",        "tier":"advanced", "cost":500, "icon":"🔥", "desc":"Unstoppable bulldozer.",       "stats":{"hp":1750, "dmg":22, "spd":2}, "tags":["frontline", "juggernaut"]},
]

# ── INSTANCE STATE ────────────────────────────────────────────
var _player_id  : int   = 0
var _device_id  : int   = -1   # -1 = KBM, >=0 = gamepad index
var _all_creeps : Array = []
var _selected   : Array = []
var _confirmed  : bool  = false
var _is_solo    : bool  = true

# Controller navigation
var _card_panels   : Array  = []   # ordered Array[PanelContainer]
var _cursor_idx    : int    = 0
var _axis_cooldown : float  = 0.0  # seconds until next axis-triggered move
const AXIS_COOLDOWN_SEC := 0.22
const AXIS_THRESHOLD    := 0.6

var _ctrl_cursor    : ColorRect = null
var _tutorial_panel : Control  = null

# ── SHARED VOTE STATE (static, reset by P1) ───────────────────
static var _all_votes       : Dictionary = {}
static var _total_players   : int        = 1
static var _confirmed_count : int        = 0
static var _final_deck      : Array      = []


# ── STATIC RESET (call from GameOverScreen before scene reload) ─
func reset_static() -> void:
	_all_votes.clear()
	_confirmed_count = 0
	_final_deck      = []
	_confirmed       = false


# ── LIFECYCLE ─────────────────────────────────────────────────
func _ready() -> void:
	process_mode  = Node.PROCESS_MODE_ALWAYS
	mouse_filter  = Control.MOUSE_FILTER_IGNORE
	z_index       = 950
	visible       = false
	add_to_group("creep_deck_ui")


func _process(delta: float) -> void:
	if _axis_cooldown > 0.0:
		_axis_cooldown -= delta


# ── PUBLIC ENTRY ──────────────────────────────────────────────
func show_for_player(pid: int, _viewport = null) -> void:
	_player_id = pid
	_selected.clear()
	_confirmed  = false
	_cursor_idx = 0

	# Free previous children safely
	for ch in get_children():
		ch.queue_free()
	_card_panels.clear()
	_ctrl_cursor = null
	await get_tree().process_frame

	_device_id = _resolve_device(pid)

	# Player count from splitscreen manager
	var ssm := _get_ssm()
	_total_players = int(ssm.get_player_count()) if is_instance_valid(ssm) and ssm.has_method("get_player_count") else 1
	_is_solo = _total_players <= 1


	# Only P1 resets shared state — prevents P2 wiping P1's already-cast vote
	if pid == 1:
		_all_votes.clear()
		_confirmed_count = 0
		_final_deck      = []

	# Reparent to main viewport so input always reaches this node
	var root := get_tree().root
	if get_parent() != root:
		if get_parent() != null:
			get_parent().remove_child(self)
		root.add_child(self)

	# Position over this player's screen quadrant
	var screen := get_viewport().get_visible_rect().size
	var quad   := _player_quadrant(pid, _total_players, screen)
	anchor_left   = 0.0; anchor_right  = 0.0
	anchor_top    = 0.0; anchor_bottom = 0.0
	offset_left   = quad.position.x
	offset_top    = quad.position.y
	offset_right  = quad.position.x + quad.size.x
	offset_bottom = quad.position.y + quad.size.y

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().paused = false

	_load_creeps(pid)
	_build_ui()

	visible      = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Pre-select saved or default deck
	var defaults := ["zombie", "tank", "berserker", "shaman", "leaper"]
	var dm := _get_dm()
	if is_instance_valid(dm) and dm.has_method("get_player_deck"):
		var saved : Array = dm.get_player_deck(pid)
		if not saved.is_empty():
			defaults = saved
	for id in defaults:
		_toggle_select(id)

	print("[DeckUI] P%d ready | device=%d | quad=%s | solo=%s" % [pid, _device_id, str(quad), str(_is_solo)])
	_maybe_show_tutorial()


# ── CREEP LOADING ─────────────────────────────────────────────
func _load_creeps(pid: int) -> void:
	var dm := _get_dm()
	if is_instance_valid(dm):
		# REAL BUG FIX: get_all_creeps() was checked first, so this screen
		# always offered every real creep type regardless of whether the
		# player had actually unlocked it -- defeating the whole point of
		# the progressive gold-unlock economy (shopui.gd's "Unlock New
		# Creep" row). This is a "confirm your current deck" screen, not a
		# way to bypass paying for new types, so it should only ever offer
		# what's already unlocked.
		if dm.has_method("get_unlocked_creeps"):
			_all_creeps = dm.get_unlocked_creeps(pid)
		elif dm.has_method("get_all_creeps"):
			_all_creeps = dm.get_all_creeps()
		# DM present but returned empty → genuine "no unlocked creeps" state; propagate it
	else:
		_all_creeps = CREEP_CATALOGUE.duplicate()


# ── QUADRANT LAYOUT ───────────────────────────────────────────
func _player_quadrant(pid: int, total: int, screen: Vector2) -> Rect2:
	var hw  := screen.x * 0.5
	var hh  := screen.y * 0.5
	var idx := pid - 1
	match total:
		1:  return Rect2(Vector2.ZERO, screen)
		2:  return Rect2(Vector2(hw * idx, 0.0), Vector2(hw, screen.y))
		3:
			if idx < 2: return Rect2(Vector2(hw * idx, 0.0), Vector2(hw, hh))
			else:       return Rect2(Vector2(0.0, hh), Vector2(screen.x, hh))
		4:  return Rect2(Vector2(hw * (idx % 2), hh * (idx / 2)), Vector2(hw, hh))
		_:  return Rect2(Vector2.ZERO, screen)


# ── BUILD UI ─────────────────────────────────────────────────
func _build_ui() -> void:
	# Background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color        = C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Root container
	var root_vb := VBoxContainer.new()
	root_vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vb.offset_left   = 10;  root_vb.offset_right  = -10
	root_vb.offset_top    = 6;   root_vb.offset_bottom = -6
	root_vb.add_theme_constant_override("separation", 8)
	add_child(root_vb)

	# ── Header ──────────────────────────────────────────────
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 8)
	root_vb.add_child(hdr)

	var badge := Label.new()
	badge.text = "P%d" % _player_id
	badge.add_theme_font_size_override("font_size", 16)
	badge.add_theme_color_override("font_color", _player_color(_player_id))
	hdr.add_child(badge)

	var title := Label.new()
	title.text = "CHOOSE DECK" if _is_solo else "VOTE FOR CREEPS (top %d win)" % DECK_SIZE
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", C_GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_child(title)

	if _device_id >= 0:
		var hint := Label.new()
		hint.text = "🎮 D-pad/Stick=move  A=select  B=deselect  Start=confirm"
		hint.add_theme_font_size_override("font_size", 9)
		hint.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		hdr.add_child(hint)

	# ── Card scroll area ─────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical       = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode    = ScrollContainer.SCROLL_MODE_DISABLED
	# Scroll must pass mouse events to children
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	root_vb.add_child(scroll)

	var flow := HFlowContainer.new()
	flow.name = "CardFlow"
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	flow.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(flow)

	_card_panels.clear()
	for creep in _all_creeps:
		var card := _make_card(creep)
		flow.add_child(card)
		_card_panels.append(card)

	# Empty-state: no unlocked creeps yet
	if _all_creeps.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.name                  = "EmptyStateLabel"
		empty_lbl.text                  = "No creeps unlocked yet.\nProgress through the game to unlock creep types."
		empty_lbl.autowrap_mode         = TextServer.AUTOWRAP_WORD
		empty_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
		empty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty_lbl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		empty_lbl.add_theme_font_size_override("font_size", 14)
		empty_lbl.add_theme_color_override("font_color", C_DIM)
		flow.add_child(empty_lbl)

	# ── Controller cursor overlay ─────────────────────────────
	if _device_id >= 0:
		_ctrl_cursor = ColorRect.new()
		_ctrl_cursor.name         = "CtrlCursor"
		_ctrl_cursor.color        = Color(1.0, 1.0, 0.3, 0.22)
		_ctrl_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ctrl_cursor.z_index      = 20
		add_child(_ctrl_cursor)

	# ── Footer ───────────────────────────────────────────────
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 12)
	root_vb.add_child(footer)

	var count_lbl := Label.new()
	count_lbl.name = "CountLbl"
	count_lbl.add_theme_font_size_override("font_size", 13)
	count_lbl.add_theme_color_override("font_color", C_GREEN)
	count_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(count_lbl)

	var confirm_btn := Button.new()
	confirm_btn.name = "ConfirmBtn"
	confirm_btn.text = "▶ START" if _is_solo else "✓ CONFIRM"
	confirm_btn.add_theme_font_size_override("font_size", 14)
	confirm_btn.custom_minimum_size = Vector2(160, 44)
	confirm_btn.focus_mode          = Control.FOCUS_NONE   # we handle focus manually
	confirm_btn.pressed.connect(func():
		if _device_id == -1 and _total_players > 1:
			var mpos := get_viewport().get_mouse_position()
			var quad := _player_quadrant(_player_id, _total_players, get_viewport().get_visible_rect().size)
			if not quad.has_point(mpos): return
		_on_confirm())
	footer.add_child(confirm_btn)

	var wait_lbl := Label.new()
	wait_lbl.name               = "WaitLabel"
	wait_lbl.visible            = false
	wait_lbl.add_theme_font_size_override("font_size", 12)
	wait_lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vb.add_child(wait_lbl)

	_refresh_count()
	# Defer cursor update so the flow has laid out its children
	call_deferred("_update_ctrl_cursor")


# ── CARD FACTORY ──────────────────────────────────────────────
func _make_card(creep: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name                 = "Card_" + creep["id"]
	panel.custom_minimum_size  = Vector2(130, 170)

	var sbox := StyleBoxFlat.new()
	sbox.bg_color     = C_CARD_BG
	sbox.border_color = C_BORDER
	sbox.set_border_width_all(2)
	sbox.set_corner_radius_all(6)
	sbox.content_margin_left   = 5
	sbox.content_margin_right  = 5
	sbox.content_margin_top    = 5
	sbox.content_margin_bottom = 5
	panel.add_theme_stylebox_override("panel", sbox)

	panel.set_meta("cid",  creep["id"])
	panel.set_meta("sbox", sbox)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	panel.add_child(vb)

	# Icon
	var icon := Label.new()
	icon.text               = creep.get("icon", "◈")
	icon.add_theme_font_size_override("font_size", 28)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(icon)

	# Name
	var nm := Label.new()
	nm.text = creep["name"]
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color", Color(0.93, 0.89, 0.83))
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(nm)

	# Tier
	var is_adv : bool = creep.get("tier", "base") != "base"
	var tier   := Label.new()
	tier.text  = "★ ADV" if is_adv else "BASE"
	tier.add_theme_font_size_override("font_size", 8)
	tier.add_theme_color_override("font_color", Color(0.95, 0.62, 0.18) if is_adv else Color(0.30, 0.85, 0.42))
	tier.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(tier)

	# Description
	var desc := Label.new()
	desc.text         = creep.get("desc", "")
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc.add_theme_font_size_override("font_size", 8)
	desc.add_theme_color_override("font_color", C_DIM)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(desc)

	# Stats
	var st : Dictionary = creep.get("stats", {})
	if not st.is_empty():
		var sl := Label.new()
		sl.text = "HP %d  DMG %d  SPD %.0f" % [st.get("hp", 0), st.get("dmg", 0), st.get("spd", 0)]
		sl.add_theme_font_size_override("font_size", 8)
		sl.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(sl)

	# Synergy-tag badges
	var tags : Array = creep.get("tags", [])
	if not tags.is_empty():
		var tag_flow := HFlowContainer.new()
		tag_flow.add_theme_constant_override("h_separation", 3)
		tag_flow.add_theme_constant_override("v_separation", 2)
		vb.add_child(tag_flow)
		for tag in tags:
			var pill := PanelContainer.new()
			var pill_style := StyleBoxFlat.new()
			pill_style.bg_color = _tag_badge_color(tag)
			pill_style.set_corner_radius_all(3)
			pill_style.content_margin_left   = 3
			pill_style.content_margin_right  = 3
			pill_style.content_margin_top    = 1
			pill_style.content_margin_bottom = 1
			pill.add_theme_stylebox_override("panel", pill_style)
			var pill_lbl := Label.new()
			pill_lbl.text = tag
			pill_lbl.add_theme_font_size_override("font_size", 7)
			pill_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
			pill.add_child(pill_lbl)
			tag_flow.add_child(pill)

	# Cost
	var cost := Label.new()
	cost.text = "%d 🪙" % creep.get("cost", 0)
	cost.add_theme_font_size_override("font_size", 10)
	cost.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(cost)

	# Select button (mouse/touch)
	var btn := Button.new()
	btn.name       = "SelectBtn"
	btn.text       = "SELECT"
	btn.add_theme_font_size_override("font_size", 10)
	btn.focus_mode = Control.FOCUS_NONE   # controller uses _unhandled_input, not focus
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cid : String = creep["id"]
	btn.pressed.connect(func():
		# KBM player: only accept clicks that land inside our screen quadrant.
		# This prevents P1's mouse from selecting cards in a different player's deck UI
		# (which is at root level and would otherwise receive cross-quadrant clicks).
		if _device_id == -1 and _total_players > 1:
			var mpos := get_viewport().get_mouse_position()
			var quad := _player_quadrant(_player_id, _total_players, get_viewport().get_visible_rect().size)
			if not quad.has_point(mpos): return
		_toggle_select(cid))
	vb.add_child(btn)

	return panel


# ── INPUT ─────────────────────────────────────────────────────
# Using _unhandled_input so UI buttons still receive mouse events first.
func _unhandled_input(event: InputEvent) -> void:
	if not visible or _confirmed:
		return

	# Only handle gamepad events; mouse is handled by button signals
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return

	# Guard: only accept input from this player's gamepad.
	# If _device_id is unresolved (-99), retry and accept any pad.
	if _device_id == -99:
		_device_id = _resolve_device(_player_id)
	if _device_id >= 0 and event.device != _device_id:
		return
	# KBM player (_device_id == -1) should not handle gamepad events
	if _device_id == -1:
		return

	if event is InputEventJoypadButton:
		var je := event as InputEventJoypadButton
		if not je.pressed:
			return

		# While the first-run tutorial overlay is visible, eat all pad input and
		# dismiss on A or Start so the player can proceed.
		if is_instance_valid(_tutorial_panel):
			if je.button_index == JOY_BUTTON_A or je.button_index == JOY_BUTTON_START:
				_dismiss_tutorial()
			get_viewport().set_input_as_handled()
			return

		match je.button_index:
			JOY_BUTTON_DPAD_RIGHT:
				_move_cursor(1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_DPAD_LEFT:
				_move_cursor(-1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_DPAD_DOWN:
				_move_cursor_rows(1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_DPAD_UP:
				_move_cursor_rows(-1)
				get_viewport().set_input_as_handled()
			JOY_BUTTON_A:
				_select_at_cursor()
				get_viewport().set_input_as_handled()
			JOY_BUTTON_B:
				if not _selected.is_empty():
					_toggle_select(_selected[-1])
				get_viewport().set_input_as_handled()
			JOY_BUTTON_START:
				_on_confirm()
				get_viewport().set_input_as_handled()

	elif event is InputEventJoypadMotion:
		if _axis_cooldown > 0.0:
			return
		var jm := event as InputEventJoypadMotion
		match jm.axis:
			JOY_AXIS_LEFT_X:
				if abs(jm.axis_value) >= AXIS_THRESHOLD:
					_move_cursor(1 if jm.axis_value > 0 else -1)
					_axis_cooldown = AXIS_COOLDOWN_SEC
					get_viewport().set_input_as_handled()
			JOY_AXIS_LEFT_Y:
				if abs(jm.axis_value) >= AXIS_THRESHOLD:
					_move_cursor_rows(1 if jm.axis_value > 0 else -1)
					_axis_cooldown = AXIS_COOLDOWN_SEC
					get_viewport().set_input_as_handled()


# ── CURSOR MOVEMENT ───────────────────────────────────────────
func _move_cursor(delta: int) -> void:
	if _card_panels.is_empty():
		return
	_cursor_idx = posmod(_cursor_idx + delta, _card_panels.size())
	_update_ctrl_cursor()


func _move_cursor_rows(dir: int) -> void:
	# Estimate columns by comparing card Y positions
	if _card_panels.size() < 2:
		_move_cursor(dir)
		return
	var base_y : float = (_card_panels[0] as PanelContainer).get_global_rect().position.y
	var cols    := 1
	for i in range(1, _card_panels.size()):
		var cp : PanelContainer = _card_panels[i] as PanelContainer
		if abs(cp.get_global_rect().position.y - base_y) > 4.0:
			break
		cols += 1
	cols = max(cols, 1)
	_cursor_idx = clamp(_cursor_idx + dir * cols, 0, _card_panels.size() - 1)
	_update_ctrl_cursor()


func _select_at_cursor() -> void:
	if _card_panels.is_empty() or _cursor_idx >= _card_panels.size():
		return
	var panel : PanelContainer = _card_panels[_cursor_idx] as PanelContainer
	if is_instance_valid(panel) and panel.has_meta("cid"):
		_toggle_select(panel.get_meta("cid"))


func _update_ctrl_cursor() -> void:
	if not is_instance_valid(_ctrl_cursor):
		return
	if _card_panels.is_empty():
		_ctrl_cursor.visible = false
		return
	_cursor_idx = clamp(_cursor_idx, 0, _card_panels.size() - 1)
	var panel : PanelContainer = _card_panels[_cursor_idx] as PanelContainer
	if not is_instance_valid(panel):
		_ctrl_cursor.visible = false
		return
	var gr        : Rect2   = panel.get_global_rect()
	var local_pos : Vector2 = gr.position - global_position
	_ctrl_cursor.position = local_pos
	_ctrl_cursor.size     = gr.size
	_ctrl_cursor.visible  = true

	# Auto-scroll so the highlighted card is visible
	_scroll_to_card(panel)


func _scroll_to_card(panel: PanelContainer) -> void:
	var scroll := find_child("Scroll", true, false) as ScrollContainer
	if not is_instance_valid(scroll):
		return
	var flow := find_child("CardFlow", true, false) as HFlowContainer
	if not is_instance_valid(flow):
		return
	# Card position relative to the flow container
	var card_top    := panel.position.y
	var card_bottom := card_top + panel.size.y
	var view_top    := scroll.scroll_vertical
	var view_bottom := view_top + scroll.size.y
	if card_top < view_top:
		scroll.scroll_vertical = int(card_top)
	elif card_bottom > view_bottom:
		scroll.scroll_vertical = int(card_bottom - scroll.size.y)


# ── SELECTION ─────────────────────────────────────────────────
func _toggle_select(creep_id: String) -> void:
	if _confirmed:
		return
	if creep_id in _selected:
		_selected.erase(creep_id)
	else:
		if _selected.size() >= DECK_SIZE:
			_selected.erase(_selected[0])   # drop oldest if full
		_selected.append(creep_id)
	_refresh_card_visuals()
	_refresh_count()


func _refresh_card_visuals() -> void:
	for panel in _card_panels:
		if not is_instance_valid(panel):
			continue
		if not panel.has_meta("cid") or not panel.has_meta("sbox"):
			continue
		var id   : String       = panel.get_meta("cid")
		var sbox : StyleBoxFlat = panel.get_meta("sbox")
		if not is_instance_valid(sbox):
			continue
		var sel := id in _selected
		sbox.bg_color     = C_CARD_SEL if sel else C_CARD_BG
		sbox.border_color = C_SEL_BRD  if sel else C_BORDER
		sbox.set_border_width_all(3 if sel else 2)
		var btn := panel.find_child("SelectBtn", true, false) as Button
		if is_instance_valid(btn):
			btn.text = ("✓ VOTED" if not _is_solo else "✓ PICK") if sel else ("VOTE" if not _is_solo else "SELECT")


func _refresh_count() -> void:
	var lbl := find_child("CountLbl", true, false) as Label
	if is_instance_valid(lbl):
		if _all_creeps.is_empty():
			lbl.text = "No creeps unlocked yet"
			lbl.add_theme_color_override("font_color", C_DIM)
		else:
			lbl.text = "%d / %d selected" % [_selected.size(), DECK_SIZE]
			lbl.add_theme_color_override("font_color", C_GREEN)
	var btn := find_child("ConfirmBtn", true, false) as Button
	if is_instance_valid(btn):
		btn.disabled = _selected.is_empty()


# ── CONFIRM ───────────────────────────────────────────────────
func _on_confirm() -> void:
	if _confirmed or _selected.is_empty():
		return
	_confirmed = true

	if _is_solo:
		_finish(_selected.duplicate())
		return

	# Networked vote path: _all_votes/_confirmed_count are static vars shared
	# only within one process, useless across peers -- send the vote to
	# NetworkManager's server-side accumulator instead (see
	# NetworkManager.gd's rpc_cast_vote / tally_networked_votes above).
	# rpc_id(1, ...) targeting self resolves to a plain local call when this
	# peer IS the server, same convention as shopui.gd's purchase RPCs.
	if NetworkManager.is_networked:
		NetworkManager.rpc_cast_vote.rpc_id(1, _player_id, _selected.duplicate())
		emit_signal("vote_cast", _player_id, _selected.duplicate())
		var net_btn := find_child("ConfirmBtn", true, false) as Button
		if is_instance_valid(net_btn):
			net_btn.disabled = true
			net_btn.text     = "✓ LOCKED"
		var wl := find_child("WaitLabel", true, false) as Label
		if is_instance_valid(wl):
			wl.visible = true
			wl.text    = "Vote sent — waiting for other players…"
		return

	# Multiplayer vote path (local split-screen)
	_all_votes[_player_id] = _selected.duplicate()
	_confirmed_count       += 1
	emit_signal("vote_cast", _player_id, _selected.duplicate())

	var btn := find_child("ConfirmBtn", true, false) as Button
	if is_instance_valid(btn):
		btn.disabled = true
		btn.text     = "✓ LOCKED"

	_broadcast_wait_label()

	if _confirmed_count >= _total_players:
		_tally_and_finish()


func _broadcast_wait_label() -> void:
	var text := "Waiting… %d / %d confirmed" % [_confirmed_count, _total_players]
	for ui in get_tree().get_nodes_in_group("creep_deck_ui"):
		if not is_instance_valid(ui):
			continue
		var wl := ui.find_child("WaitLabel", true, false) as Label
		if is_instance_valid(wl):
			wl.visible = true
			wl.text    = text


func _tally_and_finish() -> void:
	_final_deck = tally_networked_votes(_all_votes)
	print("[DeckUI] Final voted deck: %s" % str(_final_deck))

	for ui in get_tree().get_nodes_in_group("creep_deck_ui"):
		if is_instance_valid(ui):
			ui._finish(_final_deck.duplicate())


## Same sort/slice/pad tally algorithm _tally_and_finish always used,
## extracted so NetworkManager.gd's rpc_cast_vote can reuse it unchanged
## over a server-accumulated votes dict instead of the static _all_votes
## (which only shares votes within one process -- useless across peers).
func tally_networked_votes(votes: Dictionary) -> Array:
	var counts : Dictionary = {}
	for voted in votes.values():
		for id in voted:
			counts[id] = counts.get(id, 0) + 1

	var sorted_ids := counts.keys()
	sorted_ids.sort_custom(func(a, b): return counts[a] > counts[b])
	var deck : Array = sorted_ids.slice(0, DECK_SIZE)

	if deck.size() < DECK_SIZE:
		for cr in _all_creeps:
			if deck.size() >= DECK_SIZE:
				break
			if not (cr["id"] in deck):
				deck.append(cr["id"])

	return deck


func _finish(deck: Array) -> void:
	var dm := _get_dm()
	if is_instance_valid(dm) and dm.has_method("set_player_deck"):
		dm.set_player_deck(_player_id, deck)

	emit_signal("deck_confirmed", _player_id, deck)

	var tw := create_tween()
	tw.tween_interval(0.4)
	tw.tween_property(self, "modulate:a", 0.0, 0.3)
	tw.tween_callback(func():
		visible      = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		modulate.a   = 1.0
		if _device_id == -1:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	)


# ── FIRST-RUN TUTORIAL OVERLAY ────────────────────────────────
func _maybe_show_tutorial() -> void:
	var dm := _get_dm()
	if not is_instance_valid(dm):
		return
	if dm.get("deck_ui_tutorial_seen") == true:
		return
	dm.save_tutorial_seen()  # sets the flag and writes user://creep_deck_prefs.cfg
	_build_tutorial_overlay()


func _build_tutorial_overlay() -> void:
	var overlay := ColorRect.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color        = Color(0.0, 0.0, 0.0, 0.86)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index      = 200
	add_child(overlay)
	_tutorial_panel = overlay

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	overlay.add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(360, 0)
	var sbox := StyleBoxFlat.new()
	sbox.bg_color     = Color(0.04, 0.06, 0.11, 0.98)
	sbox.border_color = Color(0.95, 0.80, 0.20, 0.9)
	sbox.set_border_width_all(2)
	sbox.set_corner_radius_all(8)
	sbox.content_margin_left   = 22
	sbox.content_margin_right  = 22
	sbox.content_margin_top    = 18
	sbox.content_margin_bottom = 18
	card.add_theme_stylebox_override("panel", sbox)
	center.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)

	var title_lbl := Label.new()
	title_lbl.text = "🧟  DECK BUILDER"
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", Color(0.95, 0.80, 0.20))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title_lbl)

	var sep := HSeparator.new()
	vb.add_child(sep)

	var lines: Array = [
		"You command the horde — pick 5 creep types.",
		"These are the monsters you spend currency to",
		"spawn each wave. Mix roles for best results:",
		"",
		"🛡 Tank      — soaks damage, taunts defences",
		"💚 Shaman   — heals nearby allies mid-wave",
		"⚡ Berserker — glass cannon, enrages when low",
		"👻 Ghost     — phases through walls & towers",
		"💣 Bomber   — detonates on death for area damage",
		"",
		"Cheaper creeps = more volume per wave.",
		"Pricier creeps = rarer but nastier threats.",
		"You can change your deck between rounds.",
	]
	for line in lines:
		var lbl := Label.new()
		lbl.text          = line
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.82, 0.85, 0.90))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		vb.add_child(lbl)

	var sep2 := HSeparator.new()
	vb.add_child(sep2)

	var btn := Button.new()
	btn.text                  = "Got it!  ▶"
	btn.add_theme_font_size_override("font_size", 14)
	btn.custom_minimum_size   = Vector2(160, 44)
	btn.focus_mode            = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func(): _dismiss_tutorial())
	vb.add_child(btn)

	if _device_id >= 0:
		var ctrl_hint := Label.new()
		ctrl_hint.text = "[A] or [START] to continue"
		ctrl_hint.add_theme_font_size_override("font_size", 9)
		ctrl_hint.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		ctrl_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(ctrl_hint)


func _dismiss_tutorial() -> void:
	if is_instance_valid(_tutorial_panel):
		_tutorial_panel.queue_free()
		_tutorial_panel = null


# ── HELPERS ───────────────────────────────────────────────────
func _resolve_device(pid: int) -> int:
	var ssm := _get_ssm()
	if is_instance_valid(ssm) and ssm.has_method("get_player"):
		var p : Node = ssm.get_player(pid - 1)
		if is_instance_valid(p) and p.get("device_id") != null:
			return int(p.get("device_id"))
	# Fallback: P1 = KBM, others = gamepad index (pid-2)
	return -1 if pid == 1 else pid - 2


func _get_ssm() -> Node:
	return get_tree().get_first_node_in_group("splitscreen_manager")


func _get_dm() -> Node:
	return get_tree().get_first_node_in_group("creep_deck_manager")


func _player_color(pid: int) -> Color:
	match pid:
		1: return Color(0.25, 0.90, 0.45)
		2: return Color(1.00, 0.50, 0.18)
		3: return Color(0.30, 0.60, 1.00)
		4: return Color(0.90, 0.25, 0.80)
		_: return Color(0.85, 0.85, 0.85)


func _tag_badge_color(tag: String) -> Color:
	match tag:
		"dps", "berserk":                  return Color(0.65, 0.18, 0.10, 0.90)
		"aoe":                             return Color(0.55, 0.15, 0.45, 0.90)
		"death":                           return Color(0.40, 0.08, 0.40, 0.90)
		"support", "heal", "aura":         return Color(0.10, 0.38, 0.18, 0.90)
		"swarm":                           return Color(0.08, 0.30, 0.42, 0.90)
		"stealth", "bypass", "drain":      return Color(0.28, 0.10, 0.50, 0.90)
		"flanker", "mobility":             return Color(0.08, 0.34, 0.50, 0.90)
		"frontline", "tank", "taunt":      return Color(0.12, 0.20, 0.48, 0.90)
		"juggernaut":                      return Color(0.38, 0.10, 0.10, 0.90)
		"ranged", "kite":                  return Color(0.10, 0.25, 0.48, 0.90)
		"poison", "debuff":                return Color(0.22, 0.35, 0.10, 0.90)
		"lane":                            return Color(0.12, 0.28, 0.38, 0.90)
		_:                                 return Color(0.18, 0.20, 0.26, 0.90)
