# ============================================================
# shop.gd
# ============================================================
extends Control

# ─────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────
const TAB_TURRETS    := 0
const TAB_PLAYER_UPG := 1
const TAB_CREEP_UPG  := 2
const TAB_CREEPS     := 3
const TAB_ABILITIES  := 4
const TAB_TRINKETS   := 5
const TAB_CRYSTALS   := 6
const TAB_WEAPONS    := 7
const TAB_PERKS      := 8
const TAB_NAMES      := ["Turrets", "Player Upgrades", "Creep Upgrades", "Creeps", "Special Abilities", "Trinkets", "Crystals ✦", "Weapons ⚔", "Class Perks ⭐"]

# ── Class perks — one chosen pre-match per class ─────────────
# Structure: class_id (int(PlayerClass)) → Array of 3 perk dicts
# Each perk: { "id", "label", "desc", "stat", "amount", "special" }
const CLASS_PERKS : Dictionary = {
	1: [  # NECROMANCER
		{"id":"necro_a", "label":"Death Harvest",   "desc":"Each kill heals 2 HP.",       "stat":"",     "amount":0, "special":"heal_on_kill"},
		{"id":"necro_b", "label":"Bone Armor",      "desc":"+10 Max HP, +1 damage.",       "stat":"",     "amount":0, "special":"bone_armor"},
		{"id":"necro_c", "label":"Soul Surge",      "desc":"Abilities cost 15% less CD.",  "stat":"cd_reduce","amount":0.15,"special":""},
	],
	2: [  # BERSERKER
		{"id":"berk_a",  "label":"Bloodlust",       "desc":"Kills give +2% move speed (max 20%).", "stat":"","amount":0,"special":"bloodlust"},
		{"id":"berk_b",  "label":"Iron Skin",       "desc":"+15 Max HP.",                  "stat":"max_health","amount":15,"special":""},
		{"id":"berk_c",  "label":"Rapid Assault",   "desc":"+4% fire rate.",               "stat":"fire_rate","amount":0.04,"special":""},
	],
	3: [  # PALADIN
		{"id":"pal_a",   "label":"Holy Grenade",    "desc":"Spawn with 1 grenade.",        "stat":"","amount":0,"special":"spawn_grenade"},
		{"id":"pal_b",   "label":"Divine Reload",   "desc":"+1 ammo on headshot.",         "stat":"","amount":0,"special":"ammo_on_headshot"},
		{"id":"pal_c",   "label":"Shield of Light", "desc":"+10 Max HP + shield +5.",      "stat":"max_health","amount":10,"special":""},
	],
	4: [  # SHADOWBLADE
		{"id":"shad_a",  "label":"Poison Edge",     "desc":"Sword applies 3s poison DoT.", "stat":"","amount":0,"special":"sword_poison"},
		{"id":"shad_b",  "label":"Ghost Step",      "desc":"+3% move speed.",              "stat":"move_speed","amount":0.03,"special":""},
		{"id":"shad_c",  "label":"Backstab",        "desc":"First hit from stealth: 3× dmg.", "stat":"","amount":0,"special":"backstab"},
	],
	5: [  # STORMCALLER
		{"id":"storm_a", "label":"Static Charge",   "desc":"Kills electrify nearby zombies (1s stun).", "stat":"","amount":0,"special":"static_charge"},
		{"id":"storm_b", "label":"Wind Rush",       "desc":"+4% move speed.",              "stat":"move_speed","amount":0.04,"special":""},
		{"id":"storm_c", "label":"Lightning Rod",   "desc":"+6% damage.",                  "stat":"damage","amount":0.06,"special":""},
	],
}

# Fallback perks for classes not in the dict above
const DEFAULT_PERKS : Array = [
	{"id":"def_a", "label":"Iron Will",     "desc":"+10 Max HP.",          "stat":"max_health","amount":10,"special":""},
	{"id":"def_b", "label":"Quick Hands",   "desc":"+3% fire rate.",       "stat":"fire_rate", "amount":0.03,"special":""},
	{"id":"def_c", "label":"Veteran",       "desc":"+2% move speed.",      "stat":"move_speed","amount":0.02,"special":""},
]

var _selected_perk_id : String = ""
const BTN_MIN_HEIGHT := 56

const GHOST_ALPHA      := 0.45
const SHOP_PANEL_ALPHA := 0.92
const MAX_TURRET_DIST  := 30.0
const CREEP_ORBIT_R    := 1.8
const CREEP_SPREAD     := 0.55

# ─────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────
@export var turret_scenes : Array[PackedScene] = []
@export var turret_costs  : Array[int]         = [300]

@export var attack_creep_scenes : Array[PackedScene] = []
@export var attack_creep_labels : Array[String]      = []
@export var attack_creep_costs  : Array[int]         = []

@export var defend_creep_scenes : Array[PackedScene] = []
@export var defend_creep_labels : Array[String]      = []
@export var defend_creep_costs  : Array[int]         = []

@export var creep_spawn_count : int = 1

# ─────────────────────────────────────────────────────────────
# UPGRADE TABLES
# ─────────────────────────────────────────────────────────────
const PLAYER_UPGRADES : Array = [
	{ "label": "Max Health +5",    "stat": "max_health", "amount": 5    },
	{ "label": "Move Speed +1.5%", "stat": "move_speed", "amount": 0.015},
	{ "label": "Rate of Fire +2%", "stat": "fire_rate",  "amount": 0.02 },
	{ "label": "Damage +1",        "stat": "damage",     "amount": 1    },
	{ "label": "Max Health +10",   "stat": "max_health", "amount": 10   },
	{ "label": "Move Speed +3%",   "stat": "move_speed", "amount": 0.03 },
	{ "label": "Rate of Fire +4%", "stat": "fire_rate",  "amount": 0.04 },
	{ "label": "Damage +2",        "stat": "damage",     "amount": 2    },
]
const PLAYER_UPGRADE_COSTS : Array = [60, 75, 90, 80, 150, 200, 220, 180]

const BASE_UPGRADES : Array = [
	{ "label": "Base Health +100",  "amount": 100 },
	{ "label": "Base Health +200",  "amount": 200 },
	{ "label": "Base Health +400",  "amount": 400 },
	{ "label": "Base Health +750",  "amount": 750 },
]
const BASE_UPGRADE_COSTS : Array = [100, 200, 400, 800]

const CREEP_UPGRADES : Array = [
	{ "label": "Zombie Health +7",   "stat": "health",     "amount": 7    },
	{ "label": "Zombie Damage +1",   "stat": "damage",     "amount": 1    },
	{ "label": "Zombie Speed +1%",   "stat": "move_speed", "amount": 0.01 },
	{ "label": "Zombie Health +15",  "stat": "health",     "amount": 15   },
	{ "label": "Zombie Damage +2",   "stat": "damage",     "amount": 2    },
	{ "label": "Zombie Speed +2%",   "stat": "move_speed", "amount": 0.02 },
]
const CREEP_UPGRADE_COSTS : Array = [60, 75, 90, 150, 200, 240]

# Per-creep inline upgrade options shown beneath each creep button
const CREEP_INLINE_UPGRADES : Array = [
	{ "label": "❤ HP +15",   "stat": "health",       "amount": 15,   "cost": 120 },
	{ "label": "⚔ DMG +3",   "stat": "damage",       "amount": 3,    "cost": 150 },
	{ "label": "⚡ SPD +2%",  "stat": "attack_speed", "amount": 0.02, "cost": 180 },
]


# ── Weapon Upgrades per weapon type ──────────────────────────
const WEAPON_UPGRADES : Dictionary = {
	"laser": [
		{"label":"Laser Damage +0.6",  "stat":"damage",      "amount":0.6,  "cost":50 },
		{"label":"Laser Damage +1.2",  "stat":"damage",      "amount":1.2,  "cost":90 },
		{"label":"Fire Rate +1.5%",    "stat":"fire_rate",   "amount":0.015,"cost":60 },
		{"label":"Fire Rate +3%",      "stat":"fire_rate",   "amount":0.03, "cost":110},
		{"label":"Proj Speed +3%",     "stat":"proj_speed",  "amount":0.03, "cost":55 },
		{"label":"Ammo Capacity +1",   "stat":"ammo_cap",    "amount":1,    "cost":45 },
	],
	"rocket": [
		{"label":"Rocket Damage +1.5", "stat":"damage",      "amount":1.5,  "cost":65 },
		{"label":"Rocket Damage +3",   "stat":"damage",      "amount":3,    "cost":130},
		{"label":"Fire Rate +1.2%",    "stat":"fire_rate",   "amount":0.012,"cost":75 },
		{"label":"Blast Radius +2%",   "stat":"blast_radius","amount":0.02, "cost":80 },
		{"label":"Proj Speed +2.5%",   "stat":"proj_speed",  "amount":0.025,"cost":60 },
		{"label":"Ammo Capacity +1",   "stat":"ammo_cap",    "amount":1,    "cost":55 },
	],
	"flame": [
		{"label":"Flame Damage +0.6",  "stat":"damage",      "amount":0.6,  "cost":50 },
		{"label":"Flame Damage +4",    "stat":"damage",      "amount":4,    "cost":95 },
		{"label":"Burn Duration +8%",  "stat":"burn_time",   "amount":0.08, "cost":60 },
		{"label":"Fire Rate +5%",      "stat":"fire_rate",   "amount":0.05, "cost":55 },
		{"label":"Ammo Capacity +10%", "stat":"ammo_cap",    "amount":0.10, "cost":45 },
		{"label":"Range +5%",          "stat":"range",       "amount":0.05, "cost":65 },
	],
	"sword": [
		{"label":"Sword Damage +3",    "stat":"damage",      "amount":3,    "cost":50 },
		{"label":"Sword Damage +6",    "stat":"damage",      "amount":6,    "cost":95 },
		{"label":"Attack Range +10%",  "stat":"attack_range","amount":0.10, "cost":60 },
		{"label":"Attack Range +20%",  "stat":"attack_range","amount":0.20, "cost":110},
		{"label":"Swing Speed +8%",    "stat":"swing_speed", "amount":0.08, "cost":70 },
		{"label":"Swing Speed +15%",   "stat":"swing_speed", "amount":0.15, "cost":130},
	],
}

# Ability upgrades — reduce cooldown or extend duration per slot
const ABILITY_UPGRADES : Array = [
	{ "slot": 0, "label": "⚔ Attack — Cooldown -15s",  "type": "cooldown", "amount": 15.0, "cost": 400 },
	{ "slot": 0, "label": "⚔ Attack — Duration +3s",   "type": "duration", "amount": 3.0,  "cost": 500 },
	{ "slot": 0, "label": "⚔ Attack — Cooldown -30s",  "type": "cooldown", "amount": 30.0, "cost": 800 },
	{ "slot": 0, "label": "⚔ Attack — Duration +6s",   "type": "duration", "amount": 6.0,  "cost": 900 },
	{ "slot": 1, "label": "🛡 Defense — Cooldown -10s", "type": "cooldown", "amount": 10.0, "cost": 350 },
	{ "slot": 1, "label": "🛡 Defense — Duration +2s",  "type": "duration", "amount": 2.0,  "cost": 450 },
	{ "slot": 1, "label": "🛡 Defense — Cooldown -20s", "type": "cooldown", "amount": 20.0, "cost": 700 },
	{ "slot": 1, "label": "🛡 Defense — Duration +5s",  "type": "duration", "amount": 5.0,  "cost": 850 },
	{ "slot": 2, "label": "🌀 Motion — Cooldown -10s",  "type": "cooldown", "amount": 10.0, "cost": 300 },
	{ "slot": 2, "label": "🌀 Motion — Duration +2s",   "type": "duration", "amount": 2.0,  "cost": 400 },
	{ "slot": 2, "label": "🌀 Motion — Cooldown -20s",  "type": "cooldown", "amount": 20.0, "cost": 650 },
	{ "slot": 2, "label": "🌀 Motion — Duration +4s",   "type": "duration", "amount": 4.0,  "cost": 750 },
]

# ─────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────
enum State { CLOSED, OPEN, PLAY, PLACEMENT, ATTACK_TARGET }
var _state : State = State.CLOSED
# Tracks how many times each stat has been purchased — drives escalating cost
var _upgrade_purchase_counts : Dictionary = {}   # "stat_key" -> int
const UPGRADE_COST_SCALE : float = 1.45   # each purchase makes that stat 45% more expensive

# ─────────────────────────────────────────────────────────────
# PLACEMENT
# ─────────────────────────────────────────────────────────────
var _placement_scene      : PackedScene        = null
var _current_turret_index : int                = -1
var _ghost                : Node3D             = null
var _ghost_material       : StandardMaterial3D = null
var _ghost_rotation_y     : float              = 0.0

# ─────────────────────────────────────────────────────────────
# PLAYER BINDING
# ─────────────────────────────────────────────────────────────
var player              : Node = null
var _player_team_id     : int  = 1
var _player_instance_id : int  = -1
var _device_id          : int  = -1

# ─────────────────────────────────────────────────────────────
# REFS
# ─────────────────────────────────────────────────────────────
var game_manager : Node = null

# ─────────────────────────────────────────────────────────────
# UI REFS
# ─────────────────────────────────────────────────────────────
var shop_panel           : Panel
var tab_container        : TabContainer
var status_label         : Label
var tab_hint_label       : Label
var gold_label           : Label
var play_hint_label      : Label
var placement_hint_label : Label

var _tab_buttons   : Array             = [[], [], [], [], [], [], [], [], []]
var _all_buttons   : Array[Dictionary] = []
var _focused_tab   : int               = 0
var _focused_index : int               = 0

var _creep_catalogue       : Array[Dictionary] = []
var _picker_selected_index : int               = -1
var _patrol_editor         : PatrolEditor       = null

var _picker_rows_vbox  : VBoxContainer
var _picker_detail     : PanelContainer
var _picker_name_lbl   : Label
var _picker_desc_lbl   : Label
var _picker_cost_lbl   : Label
var _picker_confirm    : Button
var _picker_cmd_attack : Button
var _picker_cmd_defend : Button
var _picker_cmd_patrol : Button
var _picker_cmd_stay   : Button
var _picker_gold_lbl   : Label
var _picker_squad_lbl  : Label
var _picker_row_btns   : Array[Button] = []

var _ability_slot_panels : Array[PanelContainer] = []

var _ui_refresh_timer : float = 0.0
const UI_REFRESH_INTERVAL := 0.25


# ═════════════════════════════════════════════════════════════
# READY
# ═════════════════════════════════════════════════════════════
func _ready() -> void:
	add_to_group("shop")
	# top_level makes this Control render relative to the viewport root,
	# not its parent — so it always fills the full screen even when nested
	# inside other containers.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index      = 1000
	visible      = true
	call_deferred("_apply_screen_rect")

	game_manager = get_tree().get_first_node_in_group("game_manager")

	# Register every purchasable scene with PurchaseRelay's spawner on every
	# peer (these arrays are editor-assigned consts, identical per player)
	# so any client can instantiate a server-replicated purchase, not just
	# the buyer -- MultiplayerSpawner requires the scene known in advance.
	for _sc in turret_scenes:        PurchaseRelay.register_scene(_sc)
	for _sc in attack_creep_scenes:  PurchaseRelay.register_scene(_sc)
	for _sc in defend_creep_scenes:  PurchaseRelay.register_scene(_sc)

	_build_shop_ui()
	_build_all_tabs()
	_init_patrol_editor()

	_panel_visible(false)
	call_deferred("_fix_size")

	print("[Shop] _ready | gm=%s" % str(is_instance_valid(game_manager)))


# ─────────────────────────────────────────────────────────────
# BIND PLAYER
# ─────────────────────────────────────────────────────────────
func bind_player(p: Node) -> void:
	player              = p
	_player_team_id     = int(p.get("team_id"))   if "team_id"   in p else 1
	_player_instance_id = p.get_instance_id()
	_device_id          = int(p.get("device_id")) if "device_id" in p else -1

	if not is_instance_valid(game_manager):
		game_manager = get_tree().get_first_node_in_group("game_manager")

	if p.has_signal("abilities_changed"):
		if not p.abilities_changed.is_connected(_refresh_abilities_tab):
			p.abilities_changed.connect(_refresh_abilities_tab)
	if p.has_signal("crystals_changed"):
		if not p.crystals_changed.is_connected(_refresh_crystal_tab):
			p.crystals_changed.connect(_refresh_crystal_tab)

	# TalentTree signal → refresh trinket + ability tabs on every pickup
	var tt := get_node_or_null("/root/TalentTree")
	if is_instance_valid(tt) and tt.has_signal("tree_updated"):
		if not tt.tree_updated.is_connected(_on_talent_tree_updated):
			tt.tree_updated.connect(_on_talent_tree_updated)

	visible = true
	call_deferred("_fix_size")
	call_deferred("_refresh_abilities_tab")

	print("[Shop] bind_player | P%s | team=%d | device=%d | gm=%s" % [
		str(p.get("player_id") if "player_id" in p else "?"),
		_player_team_id, _device_id,
		str(is_instance_valid(game_manager))
	])


# ─────────────────────────────────────────────────────────────
# SIZE FIX
# ─────────────────────────────────────────────────────────────
func _apply_screen_rect() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	if vp_size == Vector2.ZERO:
		await get_tree().process_frame
		vp_size = get_viewport().get_visible_rect().size
	if vp_size == Vector2.ZERO: return
	# Use anchors + explicit size to fill screen regardless of parent
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 0.0; offset_right = 0.0; offset_top = 0.0; offset_bottom = 0.0
	size     = vp_size
	position = Vector2.ZERO
	if is_instance_valid(shop_panel):
		shop_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		shop_panel.offset_left = 0.0; shop_panel.offset_right  = 0.0
		shop_panel.offset_top  = 0.0; shop_panel.offset_bottom = 0.0
		shop_panel.size     = vp_size
		shop_panel.position = Vector2.ZERO


func _fix_size() -> void:
	_apply_screen_rect()


# ─────────────────────────────────────────────────────────────
# VISIBILITY HELPERS
# ─────────────────────────────────────────────────────────────
func _panel_visible(v: bool) -> void:
	if is_instance_valid(shop_panel):
		shop_panel.visible      = v
		shop_panel.mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	# Root mouse filter: STOP when open (blocks clicks from reaching other shops),
	# IGNORE when closed (doesn't intercept anything)
	mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	# Restrict clickable area to this player's screen quadrant when open
	if v:
		_clip_to_player_quadrant()


func _clip_to_player_quadrant() -> void:
	var ssm := get_tree().get_first_node_in_group("splitscreen_manager")
	if not is_instance_valid(ssm): return
	if not is_instance_valid(player): return
	var pid : int = int(player.get("player_id") if "player_id" in player else 1)
	var total : int = int(ssm.get_player_count()) if ssm.has_method("get_player_count") else 1
	if total <= 1: return  # fullscreen — no clipping needed
	var screen := get_viewport().get_visible_rect().size
	var hw := screen.x * 0.5; var hh := screen.y * 0.5
	var idx := pid - 1
	var qrect : Rect2
	match total:
		2: qrect = Rect2(Vector2(hw * idx, 0), Vector2(hw, screen.y))
		3:
			if idx < 2: qrect = Rect2(Vector2(hw * idx, 0), Vector2(hw, hh))
			else:       qrect = Rect2(Vector2(0, hh), Vector2(screen.x, hh))
		4: qrect = Rect2(Vector2(hw*(idx%2), hh*(idx/2)), Vector2(hw, hh))
		_: qrect = Rect2(Vector2.ZERO, screen)
	# Apply quadrant as clip rect on shop panel
	if is_instance_valid(shop_panel):
		shop_panel.clip_contents = true

func _play_hint_visible(v: bool) -> void:
	if is_instance_valid(play_hint_label): play_hint_label.visible = v

func _notify_player(shop_is_open: bool) -> void:
	if not is_instance_valid(player): return
	if player.has_method("notify_shop_state"):
		player.notify_shop_state(shop_is_open)
	elif "shop_open" in player:
		player.set("shop_open", shop_is_open)


# ═════════════════════════════════════════════════════════════
# PROCESS
# ═════════════════════════════════════════════════════════════
func _process(delta: float) -> void:
	if _state == State.PLACEMENT and is_instance_valid(_ghost):
		var hit = _raycast_ground()
		if hit is Vector3:
			_ghost.global_position = hit
			_ghost.rotation.y      = _ghost_rotation_y
			_set_ghost_tint(_is_placement_valid(hit))
			_ghost.visible = true
		else:
			_ghost.visible = false

	if is_instance_valid(shop_panel) and shop_panel.visible:
		_ui_refresh_timer -= delta
		if _ui_refresh_timer <= 0.0:
			_ui_refresh_timer = UI_REFRESH_INTERVAL
			_refresh_button_states()
			_refresh_gold_label()
			_refresh_picker_gold()
			_refresh_abilities_tab()
			_refresh_crystal_tab()


# ═════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════
func open_shop() -> void:
	if _state == State.CLOSED:
		_open_shop()


func toggle_shop() -> void:
	print("[Shop] toggle_shop | state=%s" % State.keys()[_state])
	match _state:
		State.CLOSED:        _open_shop()
		State.OPEN:          _enter_play_mode()
		State.PLAY:          _exit_play_mode()
		State.PLACEMENT:     _cancel_placement()
		State.ATTACK_TARGET: _cancel_attack_target()

func handle_escape() -> void:
	match _state:
		State.OPEN, State.PLAY: _close_shop()
		State.PLACEMENT:        _cancel_placement()
		State.ATTACK_TARGET:    _cancel_attack_target()

func close_shop() -> void:
	if _state == State.CLOSED: return
	_close_shop()

func toggle_play_mode() -> void:
	toggle_shop()


# ═════════════════════════════════════════════════════════════
# STATE TRANSITIONS
# ═════════════════════════════════════════════════════════════
func _open_shop() -> void:
	_state = State.OPEN
	# Enable SubViewport local input so buttons receive clicks
	_set_viewport_input(true)
	# Note: player enters topdown via _cycle_tab before this is called.
	# Don't call set_topdown_mode again — it causes double camera switch
	# which can reset handle_input_locally back to false.
	_panel_visible(true)
	_play_hint_visible(false)
	_notify_player(true)
	_refresh_gold_label()
	_refresh_abilities_tab()
	print("[Shop] opened")

func _close_shop() -> void:
	_state = State.CLOSED
	_panel_visible(false)
	_play_hint_visible(false)
	_destroy_ghost()
	# Notify player FIRST (clears shop_open flag) then disable topdown
	_notify_player(false)
	_set_viewport_input(false)
	if is_instance_valid(player) and player.has_method("set_topdown_mode"):
		player.set_topdown_mode(false)
	Input.flush_buffered_events()
	print("[Shop] closed → FPS mode")

func _enter_play_mode() -> void:
	_state = State.PLAY
	_panel_visible(false)
	_play_hint_visible(true)
	# Notify player shop panel is gone — but keep topdown mode ON
	_notify_player(false)
	# Ensure topdown stays active for play mode
	if is_instance_valid(player):
		if player.has_method("set_topdown_mode"):
			player.set_topdown_mode(true)
		if "can_fire"    in player: player.can_fire    = true
		if "fire_locked" in player: player.fire_locked = false
		if player.has_method("set_fire_locked"): player.set_fire_locked(false)
	print("[Shop] PLAY MODE — topdown active, panel hidden, LMB fires")

func _exit_play_mode() -> void:
	_state = State.OPEN
	_panel_visible(true)
	_play_hint_visible(false)
	# Topdown stays on — we're back in shop view
	_notify_player(true)
	# Re-lock fire while shop is open
	if is_instance_valid(player):
		if "can_fire"    in player: player.can_fire    = false
		if "fire_locked" in player: player.fire_locked = true
		if player.has_method("set_fire_locked"): player.set_fire_locked(true)
	print("[Shop] exited PLAY mode → OPEN")


# ═════════════════════════════════════════════════════════════
# INPUT
# ═════════════════════════════════════════════════════════════
func _is_my_event(event: InputEvent) -> bool:
	# Gamepad: match device index
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return event.device == _device_id
	# Keyboard/Mouse: only for KBM player AND only when this shop panel is visible
	if _device_id == -1:
		if not is_instance_valid(shop_panel) or not shop_panel.visible: return false
		return true
	return false

func _input(event: InputEvent) -> void:
	if not _is_my_event(event): return
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed: return

	if _state == State.PLACEMENT:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT:  _place_turret()
			MOUSE_BUTTON_RIGHT: _cancel_placement()
			MOUSE_BUTTON_WHEEL_UP:
				_ghost_rotation_y += deg_to_rad(15.0)
				if is_instance_valid(_ghost): _ghost.rotation.y = _ghost_rotation_y
			MOUSE_BUTTON_WHEEL_DOWN:
				_ghost_rotation_y -= deg_to_rad(15.0)
				if is_instance_valid(_ghost): _ghost.rotation.y = _ghost_rotation_y
		get_viewport().set_input_as_handled()
		return

	if _state == State.ATTACK_TARGET:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT:
				var hit = _raycast_ground()
				if hit is Vector3: _issue_attack_move(hit)
			MOUSE_BUTTON_RIGHT:
				_cancel_attack_target()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not _is_my_event(event): return
	if _state == State.PLACEMENT:
		if event is InputEventKey and (event as InputEventKey).pressed:
			if (event as InputEventKey).keycode == KEY_R:
				_ghost_rotation_y += deg_to_rad(45.0)
				if is_instance_valid(_ghost): _ghost.rotation.y = _ghost_rotation_y
				get_viewport().set_input_as_handled()
		return
	if _state != State.OPEN: return
	if not _is_my_event(event): return
	if not (event is InputEventKey): return
	if _device_id != -1: return   # keyboard nav is KBM-only; gamepad uses buttons
	var kev := event as InputEventKey
	if not kev.pressed or kev.echo: return

	match kev.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_activate_focused()
			get_viewport().set_input_as_handled()
		KEY_UP:
			_focused_index = max(0, _focused_index - 1)
			_focus_button()
			get_viewport().set_input_as_handled()
		KEY_DOWN:
			_focused_index = min(_tab_buttons[_focused_tab].size() - 1, _focused_index + 1)
			_focus_button()
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			_focused_tab   = max(0, _focused_tab - 1)
			_focused_index = 0
			tab_container.current_tab = _focused_tab
			_focus_button()
			get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_focused_tab   = min(TAB_NAMES.size() - 1, _focused_tab + 1)
			_focused_index = 0
			tab_container.current_tab = _focused_tab
			_focus_button()
			get_viewport().set_input_as_handled()


# ═════════════════════════════════════════════════════════════
# RAYCAST
# ═════════════════════════════════════════════════════════════
func _get_active_camera() -> Camera3D:
	if is_instance_valid(player):
		# Try player's topdown camera first (shop is open = topdown mode)
		for prop in ["td_camera", "topdown_camera", "fps_camera"]:
			if prop in player:
				var cam : Camera3D = player.get(prop) as Camera3D
				if is_instance_valid(cam) and cam.current: return cam
		# Walk children for any active camera
		for child in player.find_children("*", "Camera3D", true, false):
			var cam := child as Camera3D
			if is_instance_valid(cam) and cam.current: return cam
	return get_viewport().get_camera_3d()

func _raycast_ground() -> Variant:
	var cam := _get_active_camera()
	if not cam: return null
	var mpos  := get_viewport().get_mouse_position()
	var from  := cam.project_ray_origin(mpos)
	var to    := from + cam.project_ray_normal(mpos) * 300.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	return get_viewport().get_world_3d().direct_space_state.intersect_ray(query).get("position", null)

func _is_placement_valid(pos: Vector3) -> bool:
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and b.team_id == _player_team_id:
			return pos.distance_to(b.global_position) <= MAX_TURRET_DIST
	return true


# ═════════════════════════════════════════════════════════════
# GHOST TURRET
# ═════════════════════════════════════════════════════════════
func _spawn_ghost(scene: PackedScene) -> void:
	_destroy_ghost()
	var spawned : Node = scene.instantiate()
	if not (spawned is Node3D): spawned.queue_free(); push_warning("[Shop] Turret scene root must be Node3D"); return
	_ghost = spawned as Node3D
	get_tree().current_scene.add_child(_ghost)
	_ghost.set_process(false)
	_ghost.set_physics_process(false)
	if "projectile_scene" in _ghost: _ghost.set("projectile_scene", null)
	_disable_collision_recursive(_ghost)
	_ghost_material              = StandardMaterial3D.new()
	_ghost_material.albedo_color = Color(0.3, 0.6, 1.0, GHOST_ALPHA)
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_apply_ghost_mat(_ghost)
	_ghost.visible = false

func _set_ghost_tint(valid: bool) -> void:
	if not _ghost_material: return
	_ghost_material.albedo_color = Color(0.3, 0.6, 1.0, GHOST_ALPHA) if valid \
		else Color(1.0, 0.2, 0.2, GHOST_ALPHA)

func _apply_ghost_mat(node: Node) -> void:
	if node is MeshInstance3D:
		var mi    := node as MeshInstance3D
		var count := mi.mesh.get_surface_count() if mi.mesh else 0
		for i in range(max(count, 1)):
			mi.set_surface_override_material(i, _ghost_material)
	for c in node.get_children(): _apply_ghost_mat(c)

func _disable_collision_recursive(node: Node) -> void:
	if node is CollisionShape3D: (node as CollisionShape3D).disabled = true
	if node is PhysicsBody3D:
		(node as PhysicsBody3D).collision_layer = 0
		(node as PhysicsBody3D).collision_mask  = 0
	if node is Area3D:
		(node as Area3D).collision_layer = 0
		(node as Area3D).collision_mask  = 0
	for c in node.get_children(): _disable_collision_recursive(c)

func _destroy_ghost() -> void:
	if is_instance_valid(_ghost): _ghost.queue_free()
	_ghost = null; _ghost_material = null


# ═════════════════════════════════════════════════════════════
# BUILD SHOP UI SHELL
# ═════════════════════════════════════════════════════════════
func _build_shop_ui() -> void:
	shop_panel = Panel.new()
	shop_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shop_panel.modulate     = Color(1, 1, 1, SHOP_PANEL_ALPHA)
	shop_panel.visible      = false
	shop_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shop_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for s in ["margin_left","margin_top","margin_right","margin_bottom"]:
		margin.add_theme_constant_override(s, 20 if s in ["margin_top","margin_bottom"] else 28)
	shop_panel.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	margin.add_child(root_vbox)

	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title := Label.new()
	title.text                  = "ARMORY SHOP"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	title.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	gold_label = Label.new()
	gold_label.text                 = "💰 0"
	gold_label.add_theme_font_size_override("font_size", 20)
	gold_label.add_theme_color_override("font_color", Color(0.96, 0.48, 0.15))
	gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_row.add_child(gold_label)

	var hint := Label.new()
	hint.text                 = "TAB = Play Mode   |   ESC = Close   |   ↑↓←→ + ENTER = Buy"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vbox.add_child(hint)

	tab_hint_label = Label.new()
	tab_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tab_hint_label.add_theme_font_size_override("font_size", 12)
	root_vbox.add_child(tab_hint_label)

	tab_container = TabContainer.new()
	tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_container.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	tab_container.tab_changed.connect(_on_tab_changed)
	root_vbox.add_child(tab_container)

	for tab_name in TAB_NAMES:
		var scroll := ScrollContainer.new()
		scroll.name                   = tab_name
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
		tab_container.add_child(scroll)
		var vb := VBoxContainer.new()
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_theme_constant_override("separation", 8)
		scroll.add_child(vb)

	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 14)
	root_vbox.add_child(status_label)

	placement_hint_label = Label.new()
	placement_hint_label.text                 = "LMB: Place   RMB/ESC: Cancel   Scroll/R: Rotate"
	placement_hint_label.add_theme_font_size_override("font_size", 15)
	placement_hint_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5, 0.95))
	placement_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	placement_hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	placement_hint_label.offset_top    = -40.0
	placement_hint_label.offset_bottom = 0.0
	placement_hint_label.visible       = false
	add_child(placement_hint_label)

	play_hint_label = Label.new()
	play_hint_label.text                 = "▶ PLAY MODE  [LMB] Move/Fire   [Q/E/F] Abilities   [TAB] Back to Shop   [ESC] Close Shop"
	play_hint_label.add_theme_font_size_override("font_size", 13)
	play_hint_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.3, 0.95))
	play_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	play_hint_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	play_hint_label.offset_top    = 6.0
	play_hint_label.offset_bottom = 36.0
	play_hint_label.visible       = false
	add_child(play_hint_label)


# ═════════════════════════════════════════════════════════════
# POPULATE TABS
# ═════════════════════════════════════════════════════════════
func _build_all_tabs() -> void:
	_populate_turret_tab()
	_populate_player_upgrade_tab()
	_populate_creep_upgrade_tab()
	_populate_creep_tab()
	_populate_abilities_tab()
	_populate_trinket_tab()
	_populate_crystal_tab()
	_populate_weapon_upgrade_tab()
	_populate_perks_tab()

func _get_tab_vbox(index: int) -> VBoxContainer:
	var child := tab_container.get_child(index)
	if child is ScrollContainer: return child.get_child(0) as VBoxContainer
	return child as VBoxContainer


# ─────────────────────────────────────────────────────────────
# TAB 0 — TURRETS
# ─────────────────────────────────────────────────────────────
func _populate_turret_tab() -> void:
	var vbox := _get_tab_vbox(TAB_TURRETS)
	if not vbox: return
	if turret_scenes.is_empty():
		vbox.add_child(_make_placeholder("No turrets configured"))
		return
	for i in turret_scenes.size():
		var cost     := turret_costs[i] if i < turret_costs.size() else 500
		var name_str := turret_scenes[i].resource_path.get_file().get_basename()
		var btn      := _make_button("🏰 %s — %d 🪙" % [name_str, cost])
		btn.pressed.connect(_on_turret_selected.bind(i))
		vbox.add_child(btn)
		_register_button(TAB_TURRETS, btn, cost)


# ─────────────────────────────────────────────────────────────
# TAB 1 — PLAYER UPGRADES  (includes ability upgrades)
# ─────────────────────────────────────────────────────────────
func _populate_player_upgrade_tab() -> void:
	var vbox := _get_tab_vbox(TAB_PLAYER_UPG)
	if not vbox: return

	vbox.add_child(_make_section_label("— Player Upgrades —"))
	for i in PLAYER_UPGRADES.size():
		var upg      : Dictionary = PLAYER_UPGRADES[i]
		var base_cost: int        = PLAYER_UPGRADE_COSTS[i] if i < PLAYER_UPGRADE_COSTS.size() else 0
		var cost     : int        = _scaled_upgrade_cost(base_cost, "player_" + upg["stat"])
		var times    : int        = _upgrade_purchase_counts.get("player_" + upg["stat"], 0)
		var tier_str : String     = " (×%d)" % (times+1) if times > 0 else ""
		var btn      := _make_button("%s — %d 🪙%s" % [upg["label"], cost, tier_str])
		btn.pressed.connect(_on_player_upgrade_selected.bind(i))
		vbox.add_child(btn)
		_register_button(TAB_PLAYER_UPG, btn, cost)

	vbox.add_child(_make_section_label("— Base Upgrades —"))
	for i in BASE_UPGRADES.size():
		var upg  : Dictionary = BASE_UPGRADES[i]
		var cost : int        = BASE_UPGRADE_COSTS[i] if i < BASE_UPGRADE_COSTS.size() else 0
		var btn  := _make_button("🏯 %s — %d 🪙" % [upg["label"], cost])
		btn.pressed.connect(_on_base_upgrade_selected.bind(i))
		vbox.add_child(btn)
		_register_button(TAB_PLAYER_UPG, btn, cost)

	vbox.add_child(HSeparator.new())
	vbox.add_child(_make_section_label("— Special Ability Upgrades —"))

	var sub := Label.new()
	sub.text                 = "Upgrade your equipped abilities — reduce cooldown or extend duration.\nRequires a trinket equipped in that slot first."
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	sub.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	var slot_icons := ["⚔", "🛡", "🌀"]
	for i in ABILITY_UPGRADES.size():
		var upg  : Dictionary = ABILITY_UPGRADES[i]
		var cost : int        = upg["cost"]
		var slot : int        = upg["slot"]
		var btn  := _make_button("%s %s — %d 🪙" % [slot_icons[slot], upg["label"], cost])
		btn.name = "AbilityUpgBtn_%d" % i
		btn.pressed.connect(_on_ability_upgrade_selected.bind(i))
		vbox.add_child(btn)
		_register_button(TAB_PLAYER_UPG, btn, cost)


# ─────────────────────────────────────────────────────────────
# TAB 2 — CREEP UPGRADES  (global zombie upgrades only)
# ─────────────────────────────────────────────────────────────
func _populate_creep_upgrade_tab() -> void:
	var vbox := _get_tab_vbox(TAB_CREEP_UPG)
	if not vbox: return

	vbox.add_child(_make_section_label("— Global Zombie Upgrades —"))
	var sub := Label.new()
	sub.text                 = "Applied to all your zombies immediately and all future spawns."
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	for i in CREEP_UPGRADES.size():
		var upg      : Dictionary = CREEP_UPGRADES[i]
		var base_cost: int        = CREEP_UPGRADE_COSTS[i] if i < CREEP_UPGRADE_COSTS.size() else 0
		var cost     : int        = _scaled_upgrade_cost(base_cost, "creep_" + upg["stat"])
		var times    : int        = _upgrade_purchase_counts.get("creep_" + upg["stat"], 0)
		var tier_str : String     = " (×%d)" % (times+1) if times > 0 else ""
		var btn  := _make_button("%s — %d 🪙%s" % [upg["label"], cost, tier_str])
		btn.pressed.connect(_on_creep_upgrade_selected.bind(i, _player_team_id))
		vbox.add_child(btn)
		_register_button(TAB_CREEP_UPG, btn, cost)


# ─────────────────────────────────────────────────────────────
# TAB 3 — CREEPS  (picker with inline per-creep upgrades)
# ─────────────────────────────────────────────────────────────
func _populate_creep_tab() -> void:
	var vbox := _get_tab_vbox(TAB_CREEPS)
	if not vbox: return

	vbox.add_child(_make_section_label("— Creeps —"))

	var squad_row := HBoxContainer.new()
	squad_row.add_theme_constant_override("separation", 12)
	vbox.add_child(squad_row)

	_picker_gold_lbl = Label.new()
	_picker_gold_lbl.text                  = "💰 0"
	_picker_gold_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	squad_row.add_child(_picker_gold_lbl)

	_picker_squad_lbl = Label.new()
	_picker_squad_lbl.text                  = "Squad: 0"
	_picker_squad_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_squad_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	squad_row.add_child(_picker_squad_lbl)

	var sel_all := Button.new()
	sel_all.text = "Select All"
	sel_all.pressed.connect(_picker_select_all)
	squad_row.add_child(sel_all)

	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", 4)
	vbox.add_child(cmd_row)

	_picker_cmd_attack = _make_cmd_button("🧟 Deploy")
	_picker_cmd_defend = _make_cmd_button("🛡 Defend")
	_picker_cmd_patrol = _make_cmd_button("↺ Patrol")
	_picker_cmd_stay   = _make_cmd_button("■ Stay")

	_picker_cmd_attack.pressed.connect(func(): _send_creeps_attack())
	_picker_cmd_defend.pressed.connect(func(): _apply_ai_mode(2))
	_picker_cmd_patrol.pressed.connect(_open_patrol_editor)
	_picker_cmd_stay.pressed.connect(func():   _apply_ai_mode(4))

	for b in [_picker_cmd_attack, _picker_cmd_defend, _picker_cmd_patrol, _picker_cmd_stay]:
		cmd_row.add_child(b)
	cmd_row.add_child(VSeparator.new())
	var btn_edit := _make_cmd_button("✏ Path")
	btn_edit.pressed.connect(_open_patrol_editor)
	cmd_row.add_child(btn_edit)

	var patrol_row := HBoxContainer.new()
	patrol_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(patrol_row)

	var btn_send := Button.new()
	btn_send.text                  = "▶ Send Patrol"
	btn_send.name                  = "BtnSendPatrol"
	btn_send.disabled              = true
	btn_send.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_send.custom_minimum_size.y = 36
	btn_send.pressed.connect(_on_send_patrol_pressed)
	patrol_row.add_child(btn_send)

	var btn_clear := Button.new()
	btn_clear.text                  = "✕ Clear"
	btn_clear.size_flags_horizontal = Control.SIZE_SHRINK_END
	btn_clear.custom_minimum_size.y = 36
	btn_clear.pressed.connect(_on_clear_patrol_pressed)
	patrol_row.add_child(btn_clear)

	vbox.add_child(HSeparator.new())

	var picker_hbox := HBoxContainer.new()
	picker_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_hbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	picker_hbox.add_theme_constant_override("separation", 10)
	vbox.add_child(picker_hbox)

	var list_scroll := ScrollContainer.new()
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.custom_minimum_size     = Vector2(200, 200)
	list_scroll.size_flags_horizontal   = Control.SIZE_SHRINK_BEGIN
	list_scroll.size_flags_vertical     = Control.SIZE_EXPAND_FILL
	picker_hbox.add_child(list_scroll)

	_picker_rows_vbox = VBoxContainer.new()
	_picker_rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_rows_vbox.add_theme_constant_override("separation", 6)
	list_scroll.add_child(_picker_rows_vbox)

	_picker_detail = PanelContainer.new()
	_picker_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_detail.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_picker_detail.visible               = false
	picker_hbox.add_child(_picker_detail)

	var dm := MarginContainer.new()
	dm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for s in ["margin_left","margin_top","margin_right","margin_bottom"]:
		dm.add_theme_constant_override(s, 12)
	_picker_detail.add_child(dm)

	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 6)
	dm.add_child(dv)

	_picker_name_lbl = Label.new()
	_picker_name_lbl.add_theme_font_size_override("font_size", 20)
	dv.add_child(_picker_name_lbl)

	_picker_cost_lbl = Label.new()
	_picker_cost_lbl.add_theme_font_size_override("font_size", 13)
	dv.add_child(_picker_cost_lbl)

	_picker_desc_lbl = Label.new()
	_picker_desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_picker_desc_lbl.add_theme_font_size_override("font_size", 12)
	dv.add_child(_picker_desc_lbl)

	dv.add_child(HSeparator.new())

	_picker_confirm = Button.new()
	_picker_confirm.text                  = "Deploy"
	_picker_confirm.custom_minimum_size.y = 44
	_picker_confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_confirm.pressed.connect(_picker_confirm_purchase)
	dv.add_child(_picker_confirm)

	_build_creep_catalogue()


# ─────────────────────────────────────────────────────────────
# TAB 4 — TALENT TREE (ability selection + tier unlocks)
# ─────────────────────────────────────────────────────────────
const _ATTACK_POOL : Array = [
	{"id":"rapid_fire",   "name":"⚡ Rapid Fire",      "slot":0,"cooldown":120.0,"duration":8.0,  "desc":"Fire rate x2.5 for 8s.","tier":0},
	{"id":"frenzy",       "name":"⚡ Frenzy",          "slot":0,"cooldown":100.0,"duration":6.0,  "desc":"Rapid fire 6s.","tier":0},
	{"id":"double_damage","name":"💀 Death Mark",      "slot":0,"cooldown":150.0,"duration":10.0, "desc":"2x damage 10s.","tier":1},
	{"id":"berserker",    "name":"🔥 Berserker",       "slot":0,"cooldown":130.0,"duration":8.0,  "desc":"Fire x1.8 move x1.6.","tier":1},
	{"id":"fire_weapon",  "name":"🔥 Fire Weapon",     "slot":0,"cooldown":125.0,"duration":9.0,  "desc":"Burn damage over time.","tier":2},
	{"id":"explosive",    "name":"💥 Explosive Rounds","slot":0,"cooldown":145.0,"duration":7.0,  "desc":"Bullets explode on hit.","tier":2},
	{"id":"vampiric",     "name":"🩸 Vampiric Strike", "slot":0,"cooldown":135.0,"duration":8.0,  "desc":"Heal 30pct damage dealt.","tier":3},
	{"id":"execute",      "name":"Execute",            "slot":0,"cooldown":160.0,"duration":5.0,  "desc":"Instant kill below 25pct HP.","tier":3},
]
const _DEFENSE_POOL : Array = [
	{"id":"void_shield",  "name":"Shield",           "slot":1,"cooldown":90.0, "duration":6.0,  "desc":"Full immunity 6s.","tier":0},
	{"id":"blood_rite",   "name":"💚 Blood Rite",    "slot":1,"cooldown":80.0, "amount":60.0,   "desc":"Restore 60 HP.","tier":0},
	{"id":"iron_skin",    "name":"🪨 Iron Skin",     "slot":1,"cooldown":110.0,"duration":12.0, "desc":"Reduce damage 60pct.","tier":1},
	{"id":"energy_shield","name":"🔵 Energy Shield", "slot":1,"cooldown":105.0,"amount":75.0,   "desc":"75 temp HP.","tier":1},
	{"id":"reflect",      "name":"🔄 Mirror Guard",  "slot":1,"cooldown":120.0,"duration":7.0,  "desc":"Reflect 100pct damage.","tier":2},
	{"id":"frost_armor",  "name":"Frost Armor",      "slot":1,"cooldown":115.0,"duration":10.0, "desc":"Attackers slowed 60pct.","tier":2},
	{"id":"second_wind",  "name":"💨 Second Wind",   "slot":1,"cooldown":180.0,"duration":0.0,  "desc":"Auto-revive at 30pct HP.","tier":3},
	{"id":"camouflage",   "name":"🌿 Camouflage",    "slot":1,"cooldown":90.0, "duration":12.0, "desc":"Hard to see 12s.","tier":3},
]
const _MOTION_POOL : Array = [
	{"id":"void_dash",   "name":"💨 Void Dash",    "slot":2,"cooldown":60.0, "distance":8.0,  "desc":"Dash forward.","tier":0},
	{"id":"phase_shift", "name":"👻 Phase Shift",  "slot":2,"cooldown":75.0, "duration":5.0,  "desc":"Semi-invisible 5s.","tier":0},
	{"id":"overclock",   "name":"🌀 Overclock",    "slot":2,"cooldown":90.0, "duration":6.0,  "desc":"Speed x1.3 for 6s.","tier":1},
	{"id":"blink",       "name":"Blink",           "slot":2,"cooldown":70.0, "distance":12.0, "desc":"Teleport 12m.","tier":1},
	{"id":"sprint",      "name":"🏃 Sprint",       "slot":2,"cooldown":80.0, "duration":5.0,  "desc":"Speed x1.6 for 5s.","tier":2},
	{"id":"haste",       "name":"Haste",           "slot":2,"cooldown":110.0,"duration":4.0,  "desc":"Speed x1.8 + fire x1.5.","tier":2},
	{"id":"evasion",     "name":"🎭 Evasion",      "slot":2,"cooldown":85.0, "duration":6.0,  "desc":"50pct dodge 6s.","tier":3},
	{"id":"double_jump", "name":"🦘 Double Jump",  "slot":2,"cooldown":40.0, "duration":20.0, "desc":"Double jump 20s.","tier":3},
]
const TIER_THRESHOLDS : Array = [0, 3, 8, 16]   # pickups to unlock each tier
const _SLOT_NAMES  : Array = ["⚔ ATTACK [Q]", "🛡 DEFENSE [E]", "🌀 MOTION [F]"]
const _SLOT_COLORS : Array = [Color(1.0,0.35,0.1), Color(0.25,0.55,1.0), Color(0.2,0.9,0.5)]
const _TIER_LABELS : Array = ["TIER I", "TIER II — 1 Trinket", "TIER III — 2 Trinkets", "TIER IV — 3 Trinkets"]

var _tt_tree_cols : Array = []
var _tt_status_lbl : Label = null
var _tt_built : bool = false

func _populate_abilities_tab() -> void:
	var vbox := _get_tab_vbox(TAB_ABILITIES)
	if not vbox: return

	vbox.add_child(_make_section_label("— Equipped Abilities —"))

	var keys_lbl := Label.new()
	keys_lbl.text = "Q = Attack slot   E = Defense slot   F = Motion slot"
	keys_lbl.add_theme_font_size_override("font_size", 11)
	keys_lbl.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
	keys_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(keys_lbl)

	# 3 equipped-ability panels (one per slot)
	_ability_slot_panels.clear()
	for slot in 1:
		var sc : Color = _SLOT_COLORS[slot]
		var panel := PanelContainer.new()
		panel.name = "SlotPanel_%d" % slot
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sbox := StyleBoxFlat.new()
		sbox.bg_color = Color(0.07, 0.08, 0.10, 0.95)
		sbox.set_border_width_all(2); sbox.border_color = sc
		sbox.set_corner_radius_all(4)
		sbox.content_margin_left = 10; sbox.content_margin_right  = 10
		sbox.content_margin_top  = 5;  sbox.content_margin_bottom = 5
		panel.add_theme_stylebox_override("panel", sbox)
		vbox.add_child(panel)
		_ability_slot_panels.append(panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		panel.add_child(row)

		var slot_lbl := Label.new()
		slot_lbl.text = _SLOT_NAMES[slot]
		slot_lbl.add_theme_font_size_override("font_size", 12)
		slot_lbl.add_theme_color_override("font_color", sc)
		slot_lbl.custom_minimum_size.x = 120
		row.add_child(slot_lbl)

		var ability_lbl := Label.new()
		ability_lbl.name = "AbilityLbl"
		ability_lbl.text = "— Empty —"
		ability_lbl.add_theme_font_size_override("font_size", 12)
		ability_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
		ability_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ability_lbl)

		var cd_lbl := Label.new()
		cd_lbl.name = "CdLbl"
		cd_lbl.add_theme_font_size_override("font_size", 11)
		cd_lbl.add_theme_color_override("font_color", Color(0.85, 0.6, 0.2))
		cd_lbl.custom_minimum_size.x = 60
		row.add_child(cd_lbl)

		var use_btn := Button.new()
		use_btn.name = "UseBtn"
		use_btn.text = "USE"
		use_btn.custom_minimum_size = Vector2(60, 28)
		use_btn.disabled = true
		use_btn.focus_mode = Control.FOCUS_NONE
		var s2 := slot
		use_btn.pressed.connect(func():
			if is_instance_valid(player) and player.has_method("activate_ability"):
				player.activate_ability(s2))
		row.add_child(use_btn)

	vbox.add_child(HSeparator.new())
	vbox.add_child(_make_section_label("— Collected Trinkets — Pick one per slot to equip —"))

	var hint := Label.new()
	hint.text = "You can only equip 1 ability per slot. Click EQUIP to switch."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.45, 0.47, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(hint)

	# Trinket list — rebuilt by _refresh_abilities_tab
	var trinket_list := VBoxContainer.new()
	trinket_list.name = "TrinketList"
	trinket_list.add_theme_constant_override("separation", 4)
	trinket_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(trinket_list)

	_tt_built = true


func _on_talent_tree_updated(_pid: int) -> void:
	call_deferred("_refresh_abilities_tab")
	call_deferred("_refresh_trinket_tab")


func _populate_trinket_tab() -> void:
	var vbox := _get_tab_vbox(TAB_TRINKETS)
	if not vbox: return
	vbox.add_child(_make_section_label("— Collected Trinkets —"))

	var sub := Label.new()
	sub.text = "Trinkets permanently unlock ability tiers. Collected from killed enemies and found near bases."
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	var count_lbl := Label.new()
	count_lbl.name = "TrinketCountLabel"
	count_lbl.text = "No trinkets collected yet."
	count_lbl.add_theme_font_size_override("font_size", 13)
	count_lbl.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(count_lbl)

	vbox.add_child(HSeparator.new())

	var list := VBoxContainer.new()
	list.name = "TrinketTabList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	vbox.add_child(list)


func _refresh_trinket_tab() -> void:
	var vbox := _get_tab_vbox(TAB_TRINKETS)
	if not vbox: return
	var list := vbox.find_child("TrinketTabList", true, false) as VBoxContainer
	var count_lbl := vbox.find_child("TrinketCountLabel", true, false) as Label
	if not is_instance_valid(list): return

	for c in list.get_children(): c.queue_free()

	if not is_instance_valid(player):
		if is_instance_valid(count_lbl): count_lbl.text = "No player bound."
		return

	var tt  : Node = get_node_or_null("/root/TalentTree")
	var pid : int  = int(player.get("player_id") if "player_id" in player else 0)

	if not is_instance_valid(tt) or not tt.has_method("get_collected_abilities"):
		if is_instance_valid(count_lbl): count_lbl.text = "TalentTree not found."
		return

	var total := 0
	var slot_labels := ["🧟 Deploy", "🛡 Defense", "🌀 Motion"]

	for slot in 1:
		var abilities : Array = tt.get_collected_abilities(pid, slot)
		total += abilities.size()
		var sc : Color = _SLOT_COLORS[slot]

		var hdr := Label.new()
		hdr.text = "%s — %d trinket%s  (tier progress: %s)" % [
			slot_labels[slot], abilities.size(),
			"s" if abilities.size() != 1 else "",
			tt.progress_text(pid, slot) if tt.has_method("progress_text") else "?"]
		hdr.add_theme_font_size_override("font_size", 13)
		hdr.add_theme_color_override("font_color", sc)
		list.add_child(hdr)

		if abilities.is_empty():
			var none_lbl := Label.new()
			none_lbl.text = "  None yet"
			none_lbl.add_theme_font_size_override("font_size", 11)
			none_lbl.add_theme_color_override("font_color", Color(0.38, 0.40, 0.46))
			list.add_child(none_lbl)
		else:
			for abil in abilities:
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				list.add_child(row)

				var icon_map := {"common":"🔮","uncommon":"💎","rare":"✨","legendary":"🌟"}
				var tier : int = int(abil.get("tier", 0))
				var stars : String = ["★","★★","★★★","★★★★"][clampi(tier, 0, 3)]
				var icon_lbl := Label.new()
				icon_lbl.text = stars
				icon_lbl.add_theme_font_size_override("font_size", 14)
				icon_lbl.add_theme_color_override("font_color", sc)
				row.add_child(icon_lbl)

				var info := VBoxContainer.new()
				info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(info)

				var name_lbl := Label.new()
				name_lbl.text = abil.get("name", "Unknown")
				name_lbl.add_theme_font_size_override("font_size", 12)
				name_lbl.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
				info.add_child(name_lbl)

				var desc_lbl := Label.new()
				desc_lbl.text = abil.get("desc", "")
				desc_lbl.add_theme_font_size_override("font_size", 10)
				desc_lbl.add_theme_color_override("font_color", Color(0.48, 0.50, 0.58))
				info.add_child(desc_lbl)

				# Quick-equip from trinket tab
				var is_eq : bool = false
				if "ability_slots" in player:
					var eq = player.ability_slots[slot]
					is_eq = eq != null and eq.get("id","") == abil.get("id","")
				var eq_btn := Button.new()
				eq_btn.text = "✓ ON" if is_eq else "EQUIP"
				eq_btn.custom_minimum_size = Vector2(72, 26)
				eq_btn.add_theme_font_size_override("font_size", 10)
				eq_btn.focus_mode = Control.FOCUS_NONE
				var d : Dictionary = abil.duplicate(); var sl : int = slot
				eq_btn.pressed.connect(func():
					if is_instance_valid(player) and player.has_method("equip_ability"):
						player.equip_ability(sl, {} if is_eq else d)
					_refresh_abilities_tab()
					_refresh_crystal_tab()
					_refresh_trinket_tab())
				row.add_child(eq_btn)

		var sep := HSeparator.new()
		sep.modulate = Color(1,1,1,0.15)
		list.add_child(sep)

	if is_instance_valid(count_lbl):
		count_lbl.text = "%d trinket%s collected" % [total, "s" if total != 1 else ""] 			if total > 0 else "No trinkets collected yet."


func _on_talent_equip(data: Dictionary) -> void:
	if not is_instance_valid(player): return
	var slot     : int  = int(data.get("slot",0))
	var pid      : int  = int(player.get("player_id") if "player_id" in player else 0)
	var tt       : Node = get_node_or_null("/root/TalentTree")
	var tier     : int  = int(data.get("tier",0))
	var unlocked : int  = tt.tier_unlocked(pid, slot) if is_instance_valid(tt) else 3
	if tier > unlocked:
		_show_status("🔒 Pick up %d more trinket(s) to unlock this!" % (tier - unlocked))
		return
	if player.has_method("equip_ability"):
		player.equip_ability(slot, data)
		_show_status("Equipped: %s" % data.get("name","?"))
	elif is_instance_valid(tt) and tt.has_method("queue_ability"):
		tt.queue_ability(pid, data)
		_show_status("Queued: %s" % data.get("name","?"))
	_refresh_abilities_tab()


func _refresh_abilities_tab() -> void:
	if not is_instance_valid(player): return
	var tt  : Node = get_node_or_null("/root/TalentTree")
	var pid : int  = int(player.get("player_id") if "player_id" in player else 0)

	# ── Update the 3 equipped-slot panels ─────────────────────
	for slot in 1:
		if slot >= _ability_slot_panels.size(): break
		var panel := _ability_slot_panels[slot]
		if not is_instance_valid(panel): continue
		var albl := panel.find_child("AbilityLbl", true, false) as Label
		var clbl := panel.find_child("CdLbl",      true, false) as Label
		var ubtn := panel.find_child("UseBtn",      true, false) as Button
		if not albl: continue
		var data  = player.ability_slots[slot]
		var cd    : float = player.ability_cooldowns[slot]
		if data == null:
			albl.text = "— Empty —  (find trinkets near base!)"
			albl.add_theme_color_override("font_color", Color(0.38, 0.38, 0.42))
			if clbl: clbl.text = ""
			if ubtn: ubtn.text = "USE"; ubtn.disabled = true
		else:
			albl.text = data.get("name", "?")
			albl.add_theme_color_override("font_color", Color(0.92, 0.88, 0.82))
			if cd > 0.0:
				if clbl: clbl.text = "%.0fs" % cd
				if ubtn: ubtn.text = "%.0fs" % cd; ubtn.disabled = true
			else:
				if clbl: clbl.text = "READY"
				if ubtn: ubtn.text = "USE"; ubtn.disabled = false

	# ── Rebuild trinket list from TalentTree collected data ────
	if not _tt_built: return
	var trinket_list := _get_tab_vbox(TAB_ABILITIES).find_child("TrinketList", true, false) as VBoxContainer
	if not is_instance_valid(trinket_list): return

	# Clear old cards
	for c in trinket_list.get_children():
		c.queue_free()

	if not is_instance_valid(tt) or not tt.has_method("get_collected_abilities"):
		var empty_lbl := Label.new()
		empty_lbl.text = "Pick up trinkets in the world to unlock abilities here."
		empty_lbl.add_theme_color_override("font_color", Color(0.45, 0.47, 0.55))
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		trinket_list.add_child(empty_lbl)
		return

	var slot_labels : Array = ["⚔ ATTACK [Q]", "🛡 DEFENSE [E]", "🌀 MOTION [F]"]
	var any_collected := false

	for slot in 1:
		var abilities : Array = tt.get_collected_abilities(pid, slot)
		if abilities.is_empty(): continue
		any_collected = true

		# Slot header
		var hdr := Label.new()
		hdr.text = slot_labels[slot]
		hdr.add_theme_font_size_override("font_size", 12)
		hdr.add_theme_color_override("font_color", _SLOT_COLORS[slot])
		trinket_list.add_child(hdr)

		# One card per collected ability
		for abil_data in abilities:
			var card := _make_trinket_equip_card(abil_data, slot, player, tt, pid)
			trinket_list.add_child(card)

		trinket_list.add_child(HSeparator.new())

	if not any_collected:
		var empty_lbl := Label.new()
		empty_lbl.text = "No trinkets collected yet. Find them near your base!"
		empty_lbl.add_theme_color_override("font_color", Color(0.45, 0.47, 0.55))
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		trinket_list.add_child(empty_lbl)


func _make_trinket_equip_card(abil: Dictionary, slot: int, p: Node, tt: Node, pid: int) -> PanelContainer:
	var sc    : Color  = _SLOT_COLORS[slot]
	var is_eq : bool   = false
	if "ability_slots" in p:
		var eq = p.ability_slots[slot]
		is_eq = eq != null and eq.get("id", "") == abil.get("id", "")

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.08, 0.16, 0.10, 0.98) if is_eq else Color(0.07, 0.08, 0.10, 0.95)
	sbox.set_border_width_all(2)
	sbox.border_color = Color(0.15, 0.85, 0.4) if is_eq else sc * Color(1,1,1,0.45)
	sbox.set_corner_radius_all(4)
	sbox.content_margin_left = 10; sbox.content_margin_right  = 10
	sbox.content_margin_top  = 5;  sbox.content_margin_bottom = 5
	card.add_theme_stylebox_override("panel", sbox)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)

	# Name + description
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = abil.get("name", "Unknown")
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color",
		Color(0.2, 1.0, 0.5) if is_eq else Color(0.92, 0.88, 0.82))
	info.add_child(name_lbl)

	var desc_lbl := Label.new()
	var cd_str := "CD: %.0fs" % abil.get("cooldown", 0.0)
	if abil.get("duration", 0.0) > 0.0:
		cd_str += "  Duration: %.0fs" % abil["duration"]
	elif "amount" in abil:
		cd_str += "  Effect: +%.0f" % abil["amount"]
	desc_lbl.text = "%s  •  %s" % [abil.get("desc", ""), cd_str]
	desc_lbl.add_theme_font_size_override("font_size", 10)
	desc_lbl.add_theme_color_override("font_color", Color(0.48, 0.50, 0.58))
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	info.add_child(desc_lbl)

	# Equip / Equipped button
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(80, 30)
	btn.add_theme_font_size_override("font_size", 11)
	btn.focus_mode = Control.FOCUS_NONE

	if is_eq:
		btn.text = "✓ ON"
		btn.disabled = false
		# Clicking again unequips
		var d : Dictionary = abil.duplicate(); var sl : int = slot
		btn.pressed.connect(func():
			if is_instance_valid(p) and p.has_method("equip_ability"):
				p.equip_ability(sl, {})   # empty dict = unequip
			_refresh_abilities_tab()
			_refresh_crystal_tab())
	else:
		btn.text = "EQUIP"
		btn.disabled = false
		var d : Dictionary = abil.duplicate(); var sl : int = slot
		btn.pressed.connect(func():
			if is_instance_valid(p) and p.has_method("equip_ability"):
				p.equip_ability(sl, d)
			_refresh_abilities_tab()
			_refresh_crystal_tab())
	row.add_child(btn)
	return card





# ─────────────────────────────────────────────────────────────
# TAB 6 — CRYSTALS
# ─────────────────────────────────────────────────────────────
func _populate_crystal_tab() -> void:
	var vbox := _get_tab_vbox(TAB_CRYSTALS)
	if not vbox: return

	vbox.add_child(_make_section_label("— Crystal Enchantment Upgrades —"))

	var info := Label.new()
	info.text = "Spend crystals collected from zombie kills to boost enchantment damage.\nEach upgrade also increases your weakness to the opposing element."
	info.add_theme_font_size_override("font_size", 11)
	info.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(info)

	var crystal_lbl := Label.new()
	crystal_lbl.name = "CrystalCountLbl"
	crystal_lbl.text = "✦ Crystals: 0"
	crystal_lbl.add_theme_font_size_override("font_size", 16)
	crystal_lbl.add_theme_color_override("font_color", Color(0.7, 0.4, 1.0))
	crystal_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(crystal_lbl)

	vbox.add_child(HSeparator.new())

	const ENCHANTS := [
		{"name": "🔥 Fire",     "idx": 1, "weak": "❄ Ice",      "color": Color(1.0, 0.4, 0.1)},
		{"name": "❄ Ice",      "idx": 2, "weak": "🔥 Fire",    "color": Color(0.3, 0.7, 1.0)},
		{"name": "☠ Poison",  "idx": 3, "weak": "⚡ Electric", "color": Color(0.3, 0.9, 0.2)},
		{"name": "⚡ Electric","idx": 4, "weak": "☠ Poison",  "color": Color(1.0, 0.95, 0.1)},
		{"name": "🌑 Shadow",  "idx": 5, "weak": "🩸 Vampiric","color": Color(0.6, 0.1, 0.9)},
		{"name": "🩸 Vampiric","idx": 6, "weak": "🌑 Shadow",  "color": Color(0.9, 0.1, 0.3)},
	]
	const COSTS    := [8, 20, 40, 70, 110]   # crystals per upgrade tier
	const BONUS    := 0.15                    # +15% per upgrade

	for entry in ENCHANTS:
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sbox := StyleBoxFlat.new()
		sbox.bg_color = Color(0.07, 0.07, 0.10, 0.95)
		sbox.set_border_width_all(1)
		sbox.border_color = entry["color"] * Color(1,1,1,0.5)
		sbox.set_corner_radius_all(4)
		sbox.content_margin_left = 8; sbox.content_margin_right = 8
		sbox.content_margin_top  = 6; sbox.content_margin_bottom = 6
		panel.add_theme_stylebox_override("panel", sbox)
		vbox.add_child(panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		panel.add_child(row)

		var name_col := VBoxContainer.new()
		name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_col)

		var name_lbl := Label.new()
		name_lbl.text = entry["name"]
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", entry["color"])
		name_col.add_child(name_lbl)

		var mult_lbl := Label.new()
		mult_lbl.name = "MultLbl_%d" % int(entry["idx"])
		mult_lbl.add_theme_font_size_override("font_size", 11)
		mult_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
		name_col.add_child(mult_lbl)

		var weak_lbl := Label.new()
		weak_lbl.text = "Weak vs: %s" % entry["weak"]
		weak_lbl.add_theme_font_size_override("font_size", 10)
		weak_lbl.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
		name_col.add_child(weak_lbl)

		# Upgrade buttons for each tier
		var btn_col := VBoxContainer.new()
		btn_col.add_theme_constant_override("separation", 3)
		row.add_child(btn_col)

		for tier in COSTS.size():
			var cost : int  = COSTS[tier]
			var eidx : int  = int(entry["idx"])
			var btn := Button.new()
			btn.text = "+%.0f%% — %d✦" % [BONUS * 100.0, cost]
			btn.custom_minimum_size = Vector2(110, 26)
			btn.add_theme_font_size_override("font_size", 10)
			btn.focus_mode = Control.FOCUS_NONE
			btn.pressed.connect(func(): _buy_crystal_upgrade(eidx, cost, BONUS))
			btn_col.add_child(btn)

func _buy_crystal_upgrade(enchant_idx: int, cost: int, bonus: float) -> void:
	if not is_instance_valid(player): _show_status("⚠ No player bound"); return
	var crystals : int = int(player.get("crystals") if "crystals" in player else 0)
	if crystals < cost: _show_status("⚠ Need %d ✦ crystals" % cost); return
	if NetworkManager.is_networked:
		player.rpc_request_crystal_enchant.rpc_id(1, enchant_idx, cost, bonus)
		return
	if not player.has_method("spend_crystals") or not player.spend_crystals(cost):
		_show_status("⚠ Not enough crystals"); return
	if player.has_method("upgrade_enchant"):
		player.upgrade_enchant(enchant_idx, bonus)
	_refresh_crystal_tab()

func _refresh_crystal_tab() -> void:
	var vbox := _get_tab_vbox(TAB_CRYSTALS)
	if not vbox: return
	var crystals : int = int(player.get("crystals") if is_instance_valid(player) and "crystals" in player else 0)
	var lbl := vbox.find_child("CrystalCountLbl", true, false) as Label
	if is_instance_valid(lbl): lbl.text = "✦ Crystals: %d" % crystals
	# Update mult labels
	if not is_instance_valid(player): return
	var mults : Array = player.get("enchant_damage_mult") if "enchant_damage_mult" in player else []
	for i in 1:
		for idx in range(1, 7):
			var ml := vbox.find_child("MultLbl_%d" % idx, true, false) as Label
			if is_instance_valid(ml):
				var m : float = float(mults[idx]) if idx < mults.size() else 1.0
				ml.text = "Damage: x%.2f" % m

# ═══════════════════════════════════════════════════════════════
# MISSING FUNCTIONS — restored
# ═══════════════════════════════════════════════════════════════

# ── UI helpers ────────────────────────────────────────────────
# PILLAR 2 -- AUDIO (2026-07-20): "add a soft UI click sound to menu and
# order interactions". shopui.gd had ZERO audio playback anywhere despite
# many real Button.new() sites -- a genuine, real UI sound asset
# (ESM_Select_Tap_UI_Sound...wav) was already sitting in the project,
# unused. Wired into the two shared button factories (_make_button/
# _make_cmd_button), which cover most of this shop's buttons; the
# handful of buttons still built via direct Button.new() elsewhere in
# this file are a follow-up, not yet covered by this pass.
const UI_CLICK_SOUND := preload("res://assets/textures/retro_nature_pack/models/FBX/trees/ESM_Select_Tap_UI_Sound_9_Sound_FX_Arcade_Synth_User_Interface_Short_Electronic.wav")
var _ui_click_player : AudioStreamPlayer = null

func _play_ui_click() -> void:
	if not is_instance_valid(_ui_click_player):
		_ui_click_player = AudioStreamPlayer.new()
		_ui_click_player.stream = UI_CLICK_SOUND
		_ui_click_player.volume_db = -8.0
		if AudioServer.get_bus_index("SFX") >= 0:
			_ui_click_player.bus = "SFX"
		add_child(_ui_click_player)
	_ui_click_player.play()

func _make_button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = BTN_MIN_HEIGHT
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(_play_ui_click)
	_apply_btn_styles(b)
	return b

func _make_cmd_button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = 34
	b.focus_mode = Control.FOCUS_ALL
	b.pressed.connect(_play_ui_click)
	_apply_btn_styles(b)
	return b

func _apply_btn_styles(b: Button) -> void:
	var sn := StyleBoxFlat.new()
	sn.bg_color = Color(0.12, 0.13, 0.17, 0.90)
	sn.set_corner_radius_all(4)
	sn.content_margin_left = 8; sn.content_margin_right  = 8
	sn.content_margin_top  = 4; sn.content_margin_bottom = 4
	b.add_theme_stylebox_override("normal", sn)

	var sh := StyleBoxFlat.new()
	sh.bg_color = Color(0.22, 0.24, 0.32, 0.95)
	sh.set_corner_radius_all(4)
	sh.set_border_width_all(1); sh.border_color = Color(0.75, 0.65, 0.30, 0.85)
	sh.content_margin_left = 8; sh.content_margin_right  = 8
	sh.content_margin_top  = 4; sh.content_margin_bottom = 4
	b.add_theme_stylebox_override("hover", sh)

	var sf := StyleBoxFlat.new()
	sf.bg_color = Color(0.18, 0.22, 0.32, 0.95)
	sf.set_corner_radius_all(4)
	sf.set_border_width_all(2); sf.border_color = Color(0.30, 0.65, 1.0, 0.90)
	sf.content_margin_left = 8; sf.content_margin_right  = 8
	sf.content_margin_top  = 4; sf.content_margin_bottom = 4
	b.add_theme_stylebox_override("focus", sf)

	var sp := StyleBoxFlat.new()
	sp.bg_color = Color(0.08, 0.09, 0.12, 0.98)
	sp.set_corner_radius_all(4)
	sp.set_border_width_all(1); sp.border_color = Color(0.55, 0.45, 0.20, 0.70)
	sp.content_margin_left = 8; sp.content_margin_right  = 8
	sp.content_margin_top  = 4; sp.content_margin_bottom = 4
	b.add_theme_stylebox_override("pressed", sp)

func _make_section_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 14)
	return l

func _make_placeholder(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

func _refresh_player_upgrade_tab() -> void:
	# Repopulate player upgrade buttons so displayed prices reflect purchase counts
	var vbox := _get_tab_vbox(TAB_PLAYER_UPG)
	if not is_instance_valid(vbox): return
	for ch in vbox.get_children(): ch.queue_free()
	for i in PLAYER_UPGRADES.size():
		var upg      : Dictionary = PLAYER_UPGRADES[i]
		var base_cost: int        = PLAYER_UPGRADE_COSTS[i] if i < PLAYER_UPGRADE_COSTS.size() else 0
		var cost     : int        = _scaled_upgrade_cost(base_cost, "player_" + upg["stat"])
		var times    : int        = _upgrade_purchase_counts.get("player_" + upg["stat"], 0)
		var tier_str : String     = " (×%d)" % (times+1) if times > 0 else ""
		var btn      := _make_button("%s — %d 🪙%s" % [upg["label"], cost, tier_str])
		btn.pressed.connect(_on_player_upgrade_selected.bind(i))
		vbox.add_child(btn)
		_register_button(TAB_PLAYER_UPG, btn, cost)


func _refresh_creep_upgrade_tab() -> void:
	var vbox := _get_tab_vbox(TAB_CREEP_UPG)
	if not is_instance_valid(vbox): return
	for ch in vbox.get_children(): ch.queue_free()
	for i in CREEP_UPGRADES.size():
		var upg      : Dictionary = CREEP_UPGRADES[i]
		var base_cost: int        = CREEP_UPGRADE_COSTS[i] if i < CREEP_UPGRADE_COSTS.size() else 0
		var cost     : int        = _scaled_upgrade_cost(base_cost, "creep_" + upg["stat"])
		var times    : int        = _upgrade_purchase_counts.get("creep_" + upg["stat"], 0)
		var tier_str : String     = " (×%d)" % (times+1) if times > 0 else ""
		var btn      := _make_button("%s — %d 🪙%s" % [upg["label"], cost, tier_str])
		btn.pressed.connect(_on_creep_upgrade_selected.bind(i, _player_team_id))
		vbox.add_child(btn)
		_register_button(TAB_CREEP_UPG, btn, cost)


func _set_viewport_input(enabled: bool) -> void:
	print("[Shop] _set_viewport_input=%s" % str(enabled))
	# Try direct SubViewport first
	var vp := get_viewport()
	if vp is SubViewport:
		(vp as SubViewport).handle_input_locally = enabled
		(vp as SubViewport).gui_disable_input = not enabled
		print("[Shop] direct SubVP ok")
	# Also notify SSM so it can raise canvas layer for input priority
	var ssm := get_tree().get_first_node_in_group("splitscreen_manager")
	if is_instance_valid(ssm) and ssm.has_method("set_viewport_input") and is_instance_valid(player):
		var pid := int(player.get("player_id") if "player_id" in player else 1) - 1
		ssm.set_viewport_input(pid, enabled)


func _show_status(text: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = text

func _refresh_gold_label() -> void:
	if not is_instance_valid(game_manager) or not is_instance_valid(gold_label): return
	gold_label.text = "💰 %d" % game_manager.get_gold(_player_team_id)

func _refresh_button_states() -> void:
	if not is_instance_valid(game_manager): return
	var gold : int = game_manager.get_gold(_player_team_id)
	# Iterate backwards so we can prune freed buttons without index shifting
	for i in range(_all_buttons.size() - 1, -1, -1):
		var entry : Dictionary = _all_buttons[i]
		var btn = entry.get("btn")
		if not is_instance_valid(btn):
			_all_buttons.remove_at(i)
			continue
		if entry["tab"] in [TAB_CREEPS, TAB_ABILITIES, TAB_TRINKETS]: continue
		if entry["cost"] == 0: continue
		(btn as Button).disabled = entry["cost"] > gold

func _refresh_picker_gold() -> void:
	if not is_instance_valid(game_manager) or not is_instance_valid(_picker_gold_lbl): return
	var gold : int = game_manager.get_gold(_player_team_id)
	_picker_gold_lbl.text  = "💰 %d" % gold
	_picker_squad_lbl.text = "Squad: %d" % _count_owned_units()
	for i in _picker_row_btns.size():
		if i >= _creep_catalogue.size(): break
		_picker_row_btns[i].modulate = Color.WHITE \
			if gold >= _creep_catalogue[i]["cost"] else Color(0.55, 0.55, 0.55, 0.8)
	if _picker_selected_index >= 0: _refresh_picker_confirm()

func _refresh_picker_confirm() -> void:
	if _picker_selected_index < 0: return
	var entry := _creep_catalogue[_picker_selected_index]
	var gold  : int  = game_manager.get_gold(_player_team_id) if is_instance_valid(game_manager) else 0
	var can   : bool = gold >= entry["cost"]
	_picker_cost_lbl.text    = "Cost: %d 🪙  (have %d)" % [entry["cost"], gold]
	_picker_confirm.text     = "Deploy %d 🪙" % entry["cost"] if can else "Need %d 🪙" % entry["cost"]
	_picker_confirm.disabled = not can


# ── Turret placement ──────────────────────────────────────────
func _enter_placement_mode(index: int) -> void:
	_current_turret_index = index
	_placement_scene      = turret_scenes[index]
	_ghost_rotation_y     = 0.0
	_state                = State.PLACEMENT
	_panel_visible(false)
	if is_instance_valid(placement_hint_label): placement_hint_label.visible = true
	_spawn_ghost(_placement_scene)

func _cancel_placement() -> void:
	_destroy_ghost()
	_placement_scene = null; _current_turret_index = -1
	_state = State.OPEN
	if is_instance_valid(placement_hint_label): placement_hint_label.visible = false
	_panel_visible(true)

func _place_turret() -> void:
	var hit : Variant = _raycast_ground()
	if not hit is Vector3: return
	if not _is_placement_valid(hit): _show_status("⚠ Too far from base!"); return
	var cost2 := turret_costs[_current_turret_index] if _current_turret_index < turret_costs.size() else 500
	# Networked: server spawns the turret under PurchaseRelay's
	# MultiplayerSpawner-watched root and it replicates to every peer,
	# rather than each client instantiating its own disconnected copy.
	if NetworkManager.is_networked:
		var owner_path : NodePath = player.get_path() if is_instance_valid(player) else NodePath()
		PurchaseRelay.rpc_request_buy_turret.rpc_id(1, _player_team_id, _placement_scene.resource_path,
			hit, _ghost_rotation_y, owner_path, cost2)
		_destroy_ghost()
		_placement_scene = null; _current_turret_index = -1; _ghost_rotation_y = 0.0
		_state = State.OPEN
		if is_instance_valid(placement_hint_label): placement_hint_label.visible = false
		_panel_visible(true)
		_show_status("✅ Turret requested…")
		return
	if not _check_funds(cost2): return
	var inst := _placement_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(inst)
	inst.global_position = hit
	inst.rotation.y      = _ghost_rotation_y
	if "team_id"  in inst: inst.team_id  = _player_team_id
	if "owner_id" in inst: inst.owner_id = _player_instance_id
	if not inst.is_in_group("towers"): inst.add_to_group("towers")
	_destroy_ghost()
	_placement_scene = null; _current_turret_index = -1; _ghost_rotation_y = 0.0
	_state = State.OPEN
	if is_instance_valid(placement_hint_label): placement_hint_label.visible = false
	_panel_visible(true)
	_show_status("✅ Turret placed!")


# ── Attack target ─────────────────────────────────────────────
func _cancel_attack_target() -> void:
	_state = State.OPEN; _panel_visible(true); _show_status("Attack cancelled.")

func _issue_attack_move(dest: Vector3) -> void:
	_for_each_owned_unit(func(u):
		if not u.has_method("set_ai_mode"): return
		u.set_ai_mode(1)
		if "move_target"     in u: u.move_target     = dest
		if "has_move_target" in u: u.has_move_target = true)
	_state = State.OPEN; _panel_visible(true); _show_status("⚔ Zombies moving!")


# ── Purchase handlers ─────────────────────────────────────────
func _scaled_upgrade_cost(base_cost: int, stat_key: String) -> int:
	var times : int = _upgrade_purchase_counts.get(stat_key, 0)
	return int(float(base_cost) * pow(UPGRADE_COST_SCALE, times))


func _record_upgrade_purchase(stat_key: String) -> void:
	_upgrade_purchase_counts[stat_key] = _upgrade_purchase_counts.get(stat_key, 0) + 1


func _check_funds(cost: int) -> bool:
	if not is_instance_valid(game_manager): _show_status("⚠ No GameManager!"); return false
	if not game_manager.spend_gold(_player_team_id, cost): _show_status("⚠ Need %d 🪙" % cost); return false
	return true

func _on_turret_selected(index: int) -> void:
	var cost := turret_costs[index] if index < turret_costs.size() else 500
	if not is_instance_valid(game_manager): _show_status("⚠ No GameManager!"); return
	if game_manager.get_gold(_player_team_id) < cost:
		_show_status("⚠ Need %d 🪙" % cost); return
	_enter_placement_mode(index)

func _on_player_upgrade_selected(index: int) -> void:
	var upg  : Dictionary = PLAYER_UPGRADES[index]
	var stat : String     = upg["stat"]
	var base_cost : int   = PLAYER_UPGRADE_COSTS[index] if index < PLAYER_UPGRADE_COSTS.size() else 0
	var cost : int        = _scaled_upgrade_cost(base_cost, "player_" + stat)
	# Networked: send the request and return -- the server validates+spends
	# gold, applies the upgrade to its own authoritative Player copy (needed
	# for CombatRelay's damage calc to see it), then broadcasts to every
	# peer's mirror. Cost is recorded optimistically here since the shop UI
	# already gates buttons on local (near-real-time-synced) gold, matching
	# the plan's "client waits for the replicated result to appear."
	if NetworkManager.is_networked:
		if not is_instance_valid(player): return
		player.rpc_request_player_upgrade.rpc_id(1, stat, upg["amount"], cost)
		_record_upgrade_purchase("player_" + stat)
		var next_cost_net : int = _scaled_upgrade_cost(base_cost, "player_" + stat)
		_show_status("⬆ %s requested…  (next: %d 🪙)" % [upg["label"], next_cost_net])
		_refresh_player_upgrade_tab()
		return
	if not _check_funds(cost): return
	_record_upgrade_purchase("player_" + stat)
	if is_instance_valid(player) and player.has_method("apply_upgrade"):
		player.apply_upgrade(stat, upg["amount"])
	var next_cost : int = _scaled_upgrade_cost(base_cost, "player_" + stat)
	_show_status("⬆ %s!  (next: %d 🪙)" % [upg["label"], next_cost])
	_refresh_player_upgrade_tab()

func _on_base_upgrade_selected(index: int) -> void:
	var cost : int = BASE_UPGRADE_COSTS[index] if index < BASE_UPGRADE_COSTS.size() else 0
	var upg : Dictionary = BASE_UPGRADES[index]
	# Networked: Base is a static main.tscn child like GamePhaseController --
	# every peer has its own disconnected local copy, so HP needs the
	# request/apply/broadcast shape, same as gold, rather than a direct
	# local mutation.
	if NetworkManager.is_networked:
		# Resolved fresh via "economy_controller" rather than the cached
		# `game_manager` var above -- main.tscn has a second, unrelated
		# node also in the shared "game_manager" group that doesn't
		# implement rpc_request_base_upgrade. See game_phase_script.gd's
		# _ready() for the full explanation.
		var econ := get_tree().get_first_node_in_group("economy_controller")
		if not is_instance_valid(econ): _show_status("⚠ No GameManager!"); return
		econ.rpc_request_base_upgrade.rpc_id(1, _player_team_id, upg["amount"], cost)
		_show_status("🏯 %s requested…" % upg["label"])
		return
	if not _check_funds(cost): return
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and b.team_id == _player_team_id:
			# REAL BUG FIX: see game_phase_script.gd's _apply_base_upgrade for
			# the full explanation -- basenode.gd has no max_health/
			# current_health fields, only health/health_value, so this
			# fallback was always a silent no-op.
			if b.has_method("add_health"): b.add_health(upg["amount"])
			elif "health" in b:
				b.health += upg["amount"]
				if "health_value" in b: b.health_value = b.health
			_show_status("🏯 %s!" % upg["label"]); return
	_show_status("⚠ Base not found!")

func _on_creep_upgrade_selected(index: int, tid: int) -> void:
	var upg  : Dictionary = CREEP_UPGRADES[index].duplicate()
	var stat : String     = upg["stat"]
	var base_cost : int   = CREEP_UPGRADE_COSTS[index] if index < CREEP_UPGRADE_COSTS.size() else 0
	var cost : int        = _scaled_upgrade_cost(base_cost, "creep_" + stat)
	upg["team_id"] = tid
	if NetworkManager.is_networked:
		# See _on_base_upgrade_selected's comment above -- same
		# "economy_controller" vs shared "game_manager" group ambiguity.
		var econ := get_tree().get_first_node_in_group("economy_controller")
		if not is_instance_valid(econ): _show_status("⚠ No GameManager!"); return
		econ.rpc_request_creep_tier_upgrade.rpc_id(1, tid, upg, cost)
		_record_upgrade_purchase("creep_" + stat)
		var next_cost_net : int = _scaled_upgrade_cost(base_cost, "creep_" + stat)
		_show_status("⬆ T%d %s requested…  (next: %d 🪙)" % [tid, upg["label"], next_cost_net])
		_refresh_creep_upgrade_tab()
		return
	if not _check_funds(cost): return
	_record_upgrade_purchase("creep_" + stat)
	if is_instance_valid(game_manager) and game_manager.has_method("add_creep_upgrade"):
		game_manager.add_creep_upgrade(tid, upg)
	var next_cost : int = _scaled_upgrade_cost(base_cost, "creep_" + stat)
	_show_status("⬆ T%d %s!  (next: %d 🪙)" % [tid, upg["label"], next_cost])
	_refresh_creep_upgrade_tab()

func _on_ability_upgrade_selected(index: int) -> void:
	if not is_instance_valid(player): return
	var upg  : Dictionary = ABILITY_UPGRADES[index]
	var slot : int        = upg["slot"]
	var data = player.ability_slots[slot]
	if data == null: _show_status("⚠ No ability in slot %d — equip one first!" % slot); return
	if NetworkManager.is_networked:
		player.rpc_request_ability_upgrade.rpc_id(1, slot, upg["type"], upg["amount"], upg["cost"])
		_show_status("⬆ %s requested…" % upg["label"])
		return
	if not _check_funds(upg["cost"]): return
	if upg["type"] == "cooldown":
		player.ability_slots[slot]["cooldown"] = maxf(player.ability_slots[slot].get("cooldown",120.0) - upg["amount"], 10.0)
		_show_status("⬆ Cooldown -%.0fs!" % upg["amount"])
	elif upg["type"] == "duration":
		player.ability_slots[slot]["duration"] = player.ability_slots[slot].get("duration",5.0) + upg["amount"]
		_show_status("⬆ Duration +%.0fs!" % upg["amount"])
	if player.has_signal("abilities_changed"): player.abilities_changed.emit()


# ── Creep catalogue ───────────────────────────────────────────
func _build_creep_catalogue() -> void:
	_creep_catalogue.clear(); _picker_row_btns.clear()
	_tab_buttons[TAB_CREEPS].clear()
	for ch in _picker_rows_vbox.get_children(): ch.queue_free()

	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	var pid : int = int(player.get("player_id") if is_instance_valid(player) and "player_id" in player else 0)

	if is_instance_valid(dm):
		var deck_ids : Array = dm.get_player_deck(pid)
		_picker_rows_vbox.add_child(_make_section_label("— Your Creep Deck —"))
		for creep_id in deck_ids:
			var def : Dictionary = dm.get_creep_def(creep_id)
			if def.is_empty(): continue
			var scene : PackedScene = _get_scene_for_id(creep_id)
			if not is_instance_valid(scene): continue
			var cost : int = def.get("cost", 100)
			var lbl : String = "%s %s" % [def.get("icon","🧟"), def["name"]]
			_creep_catalogue.append({"label":lbl,"cost":cost,"scene":scene,"kind":"creep","desc":def.get("ability","")})
			_add_picker_row(_creep_catalogue.size()-1, def.get("icon","🧟"), def["name"], cost)
		if not _creep_catalogue.is_empty(): return

	# Fallback: use inspector-assigned defend scenes renamed to "Creeps"
	if not defend_creep_scenes.is_empty():
		_picker_rows_vbox.add_child(_make_section_label("— Creeps —"))
		for i in defend_creep_scenes.size():
			var lbl  := defend_creep_labels[i] if i < defend_creep_labels.size() else "Creep %d" % i
			var cost := defend_creep_costs[i]  if i < defend_creep_costs.size()  else 100
			_creep_catalogue.append({"label":lbl,"cost":cost,"scene":defend_creep_scenes[i],"kind":"creep","desc":""})
			_add_picker_row(_creep_catalogue.size()-1, "🧟", lbl, cost)
		return
	_picker_rows_vbox.add_child(_make_placeholder("No creeps configured — select a deck first"))

func _get_scene_for_id(creep_id: String) -> PackedScene:
	var id_map := {"zombie":0,"berserker":1,"leaper":2,"shaman":3,"tank":4}
	var idx : int = id_map.get(creep_id, -1) as int
	if idx >= 0 and idx < defend_creep_scenes.size(): return defend_creep_scenes[idx]
	if idx >= 0 and idx < attack_creep_scenes.size(): return attack_creep_scenes[idx]
	return null

func _add_picker_row(cat_index: int, icon: String, lbl: String, cost: int) -> void:
	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_rows_vbox.add_child(wrapper)
	var btn := Button.new()
	btn.text = "%s %s\n%d 🪙" % [icon, lbl, cost]
	btn.custom_minimum_size.y = BTN_MIN_HEIGHT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.toggle_mode = true; btn.focus_mode = Control.FOCUS_ALL
	var ci := cat_index; var ri := _picker_row_btns.size()
	btn.pressed.connect(func(): _picker_select(ci))
	btn.focus_entered.connect(_on_button_focused.bind(TAB_CREEPS, ri))
	btn.mouse_entered.connect(func(): btn.grab_focus())
	wrapper.add_child(btn)
	_picker_row_btns.append(btn)
	_tab_buttons[TAB_CREEPS].append(btn)
	var sep := HSeparator.new(); sep.modulate = Color(1,1,1,0.2)
	wrapper.add_child(sep)

func _picker_select(index: int) -> void:
	_picker_selected_index = index
	for i in _picker_row_btns.size():
		_picker_row_btns[i].button_pressed = (i == index)
	var entry := _creep_catalogue[index]
	_picker_name_lbl.text  = entry["label"]
	_picker_desc_lbl.text  = entry.get("desc","")
	_picker_detail.visible = true
	_refresh_picker_confirm()

func _picker_select_all() -> void:
	_show_status("Squad: %d." % _count_owned_units())

func _picker_confirm_purchase() -> void:
	if _picker_selected_index < 0: return
	var entry : Dictionary = _creep_catalogue[_picker_selected_index]
	# Networked: server spawns the creep(s) under PurchaseRelay's
	# MultiplayerSpawner-watched root and they replicate to every peer.
	# NOTE: the outside-the-walls repositioning _place_defense_creep_outside_base
	# does for defense creeps below is NOT ported server-side (needs a
	# ground raycast, more than this seam's scope) -- a networked defense
	# creep purchase spawns at the spawner's default lane position instead
	# of nudged outside the base walls. Known, bounded simplification, same
	# class as Phase 2's rocket-splash caveat.
	if NetworkManager.is_networked:
		if not is_instance_valid(player): return
		PurchaseRelay.rpc_request_buy_creep.rpc_id(1, _player_team_id, entry["scene"].resource_path,
			entry["kind"], player.get_path(), entry["cost"], creep_spawn_count)
		_show_status("%s %s requested…" % ["⚔" if entry["kind"]=="attack" else "🛡", entry["label"]])
		_picker_selected_index = -1
		for b in _picker_row_btns: b.button_pressed = false
		_picker_detail.visible = false; _refresh_picker_gold()
		return
	if not _check_funds(entry["cost"]): return
	var spawned := false
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if not ("team_id" in s) or s.team_id != _player_team_id: continue
		if not s.has_method("spawn_purchased_creep"): continue
		for _i in range(creep_spawn_count):
			var creep : Node = s.spawn_purchased_creep(entry["scene"], player)
			if not is_instance_valid(creep): continue
			if "owner_id" in creep: creep.owner_id = _player_instance_id
			if "team_id"  in creep: creep.team_id  = _player_team_id
			if entry["kind"] == "attack":
				if creep.has_method("set_ai_mode"): creep.set_ai_mode(1)
				if "owner_player" in creep: creep.owner_player = null
			else:
				if creep.has_method("set_ai_mode"): creep.set_ai_mode(2)
				if "owner_player" in creep: creep.owner_player = player
				# Teleport defense creep OUTSIDE castle walls
				_place_defense_creep_outside_base(creep)
		spawned = true; break
	if spawned:
		_show_status("%s %s deployed!" % ["⚔" if entry["kind"]=="attack" else "🛡", entry["label"]])
	else:
		# Fallback: spawn from player base directly
		if is_instance_valid(player) and player.has_method("spawn_creep_at_base"):
			var creep : Node = player.spawn_creep_at_base(entry["scene"], entry["kind"])
			if is_instance_valid(creep):
				_show_status("%s %s deployed!" % ["⚔" if entry["kind"]=="attack" else "🛡", entry["label"]])
				spawned = true
		if not spawned:
			_show_status("⚠ No spawner for team %d" % _player_team_id)
	_picker_selected_index = -1
	for b in _picker_row_btns: b.button_pressed = false
	_picker_detail.visible = false; _refresh_picker_gold()


# ── AI commands ───────────────────────────────────────────────
func _place_defense_creep_outside_base(creep: Node) -> void:
	if not (creep is Node3D): return
	# Find friendly base and enemy base
	var friendly_base : Node3D = null
	var enemy_base    : Node3D = null
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == _player_team_id: friendly_base = b as Node3D
		else: enemy_base = b as Node3D
	if not is_instance_valid(friendly_base): return
	# Direction: push TOWARD enemy base (out through castle front gate)
	# This guarantees the spawn is outside the castle walls, not inside
	var push_dir : Vector3 = Vector3.FORWARD
	if is_instance_valid(enemy_base):
		push_dir = enemy_base.global_position - friendly_base.global_position
		push_dir.y = 0.0
		if push_dir.length_squared() > 0.01: push_dir = push_dir.normalized()
	# Spread in an arc around the forward direction (±60°)
	var arc_angle := randf_range(-PI / 3.0, PI / 3.0)
	var spread_dir := push_dir.rotated(Vector3.UP, arc_angle)
	var radius := randf_range(16.0, 20.0)   # castle half-width is 14, so 16+ clears walls
	var pos := friendly_base.global_position + spread_dir * radius
	# Raycast to find ground Y
	var space := get_tree().root.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(
		Vector3(pos.x, 50.0, pos.z), Vector3(pos.x, -20.0, pos.z))
	ray.collision_mask = 1
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		pos.y = (hit.position as Vector3).y + 0.3
	else:
		pos.y = friendly_base.global_position.y + 0.3
	(creep as Node3D).global_position = pos
	print("[Shop] Defense creep placed at %s (dist from base: %.1f)" % [
		str(pos.snapped(Vector3.ONE)),
		friendly_base.global_position.distance_to(pos)])


func _send_creeps_attack() -> void:
	var eb := _find_enemy_base()
	if is_instance_valid(eb):
		var count := 0
		_for_each_owned_unit(func(u):
			if not u.has_method("set_ai_mode"): return
			u.set_ai_mode(1)
			if "move_target" in u: u.move_target = eb.global_position
			if "has_move_target" in u: u.has_move_target = true
			count += 1)
		_show_status("⚔ %d zombies attacking!" % count)
	else:
		_state = State.ATTACK_TARGET; _panel_visible(false); _show_status("⚔ Click target.")

func _apply_ai_mode(mode: int) -> void:
	var count := 0
	_for_each_owned_unit(func(u):
		if not u.has_method("set_ai_mode"): return
		u.set_ai_mode(mode)
		if "owner_player" in u: u.owner_player = player if mode == 2 else null
		count += 1)
	var labels := {1:"⚔ %d attacking",2:"🛡 %d defending",3:"↺ %d patrolling",4:"■ %d holding"}
	_show_status(labels.get(mode,"Done") % count)

func command_owned_units(mode_index: int) -> void:
	match mode_index:
		0: _send_creeps_attack()
		1: _apply_ai_mode(2)
		2: _apply_ai_mode(3)
		3: _apply_ai_mode(4)


# ── Patrol editor ─────────────────────────────────────────────
func _init_patrol_editor() -> void:
	if is_instance_valid(_patrol_editor): return
	_patrol_editor = PatrolEditor.new()
	add_child(_patrol_editor)
	var cam := get_viewport().get_camera_3d()
	_patrol_editor.init(cam, status_label)
	_patrol_editor.patrol_path_set.connect(_on_patrol_path_set)
	_patrol_editor.editor_closed.connect(_on_patrol_editor_closed)

func _open_patrol_editor() -> void:
	if not is_instance_valid(_patrol_editor): _init_patrol_editor()
	if is_instance_valid(player):
		var cam := player.get_node_or_null("Head/Camera3D") as Camera3D
		if is_instance_valid(cam): _patrol_editor._camera = cam
	_panel_visible(false); _patrol_editor.open()

func _on_patrol_editor_closed() -> void:
	_panel_visible(true)
	var count := _patrol_editor._waypoints.size() if is_instance_valid(_patrol_editor) else 0
	_show_status("Patrol: %d waypoints." % count)
	var btn := find_child("BtnSendPatrol", true, false) as Button
	if btn: btn.disabled = (count == 0)

func _on_send_patrol_pressed() -> void:
	if is_instance_valid(_patrol_editor): _patrol_editor.send_patrol()

func _on_clear_patrol_pressed() -> void:
	if is_instance_valid(_patrol_editor): _patrol_editor.clear_waypoints()
	var btn := find_child("BtnSendPatrol", true, false) as Button
	if btn: btn.disabled = true
	_show_status("Patrol cleared.")

func _on_patrol_path_set(points: Array) -> void:
	_for_each_owned_unit(func(u):
		if not u.has_method("set_ai_mode"): return
		if u.has_method("set_patrol_points"): u.set_patrol_points(points)
		elif "patrol_points" in u: u.patrol_points = points
		u.set_ai_mode(3)
		if "owner_player" in u: u.owner_player = null)
	_show_status("↺ %d waypoints, %d zombies." % [points.size(), _count_owned_units()])


# ── Unit helpers ──────────────────────────────────────────────
func _is_my_unit(u: Node) -> bool:
	if not is_instance_valid(u): return false
	if "owner_id" in u: return int(u.owner_id) == _player_instance_id
	return "team_id" in u and int(u.team_id) == _player_team_id

func _for_each_owned_unit(cb: Callable) -> void:
	for u in get_tree().get_nodes_in_group("units"):
		if _is_my_unit(u): cb.call(u)

func _count_owned_units() -> int:
	var n := 0
	for u in get_tree().get_nodes_in_group("units"):
		if _is_my_unit(u): n += 1
	return n

func _find_enemy_base() -> Node3D:
	var et := 2 if _player_team_id == 1 else 1
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and "team_id" in b and b.team_id == et:
			return b as Node3D
	return null


# ── Keyboard nav ──────────────────────────────────────────────
func _register_button(tab_index: int, btn: Button, cost: int) -> void:
	var idx : int = (_tab_buttons[tab_index] as Array).size()
	_tab_buttons[tab_index].append(btn)
	_all_buttons.append({"btn":btn,"cost":cost,"tab":tab_index,"idx":idx})
	btn.focus_entered.connect(_on_button_focused.bind(tab_index, idx))
	btn.mouse_entered.connect(func(): btn.grab_focus())

func _on_button_focused(tab: int, idx: int) -> void:
	_focused_tab = tab; _focused_index = idx; _update_tab_hint()

func _on_tab_changed(tab: int) -> void:
	_focused_tab = tab; _focused_index = 0; _update_tab_hint(); _focus_button()

func _update_tab_hint() -> void:
	if not is_instance_valid(tab_hint_label): return
	if _focused_tab < 0 or _focused_tab >= TAB_NAMES.size(): return
	if _focused_tab >= _tab_buttons.size(): return
	var count : int = _tab_buttons[_focused_tab].size()
	tab_hint_label.text = "%s  %s" % [
		TAB_NAMES[_focused_tab],
		"%d/%d" % [_focused_index+1, count] if count > 0 else "—"]

func _focus_button() -> void:
	_update_tab_hint()
	var btns : Array = _tab_buttons[_focused_tab]
	# Remove any stale (freed) button refs before focusing
	btns = btns.filter(func(b): return is_instance_valid(b))
	_tab_buttons[_focused_tab] = btns
	if btns.size() > 0:
		_focused_index = clamp(_focused_index, 0, btns.size()-1)
		(btns[_focused_index] as Button).grab_focus()

func _activate_focused() -> void:
	var btns : Array = _tab_buttons[_focused_tab]
	if _focused_index < btns.size():
		(btns[_focused_index] as Button).emit_signal("pressed")


# ── Lane helpers ──────────────────────────────────────────────
func _assign_surround_offset(creep: Node, slot: int, total: int) -> void:
	if not is_instance_valid(creep) or not "attack_offset" in creep: return
	var angle  := (TAU / float(maxi(total,1))) * float(slot) + randf_range(-CREEP_SPREAD,CREEP_SPREAD)
	var radius := CREEP_ORBIT_R + randf_range(-0.4, 0.6)
	creep.attack_offset = Vector3(cos(angle)*radius, 0.0, sin(angle)*radius)

func _get_lane_waypoints(lane_id: int) -> Array:
	if Engine.has_singleton("AIDirector"):
		var d = Engine.get_singleton("AIDirector")
		if d and d.has_method("get_lane_waypoints"):
			return d.get_lane_waypoints(lane_id)
	return []

func _get_lane_for_spawner(spawner: Node3D) -> int:
	if not is_instance_valid(spawner): return 2
	var pos := spawner.global_position
	if pos.x < -15 and pos.z < -10: return 1
	elif pos.x < -15 and pos.z > 10: return 3
	else: return 2


# ─────────────────────────────────────────────────────────────
# TAB 7 — WEAPON UPGRADES
# ─────────────────────────────────────────────────────────────
func _populate_weapon_upgrade_tab() -> void:
	var vbox := _get_tab_vbox(TAB_WEAPONS)
	if not vbox: return
	vbox.add_theme_constant_override("separation", 6)

	var weapons := {
		"laser":  "🔵 Laser Rifle",
		"rocket": "🚀 Rocket Launcher",
		"flame":  "🔥 Flamethrower",
		"sword":  "⚔ Sword",
	}

	for wkey in weapons.keys():
		vbox.add_child(_make_section_label("— %s —" % weapons[wkey]))
		if not WEAPON_UPGRADES.has(wkey): continue
		for upg in WEAPON_UPGRADES[wkey]:
			var btn := _make_button("%s — %d 🪙" % [upg["label"], upg["cost"]])
			var _wk : String = wkey; var _upg : Dictionary = upg
			btn.pressed.connect(func(): _on_weapon_upgrade_selected(_wk, _upg))
			vbox.add_child(btn)
			_register_button(TAB_WEAPONS, btn, upg["cost"])


func _on_weapon_upgrade_selected(weapon_key: String, upg: Dictionary) -> void:
	var cost : int = upg["cost"]
	if not is_instance_valid(player): return
	var stat   : String = upg["stat"]
	var amount : float  = upg["amount"]
	# Networked: CombatRelay.gd reads weapon.get("damage") server-side to
	# compute damage, so a weapon-stat upgrade only applied to this client's
	# own local weapon copy would be invisible to the server's damage calc.
	# Route through player.gd's rpc_request_weapon_upgrade instead, which
	# applies to the server's authoritative copy and broadcasts the mirror.
	if NetworkManager.is_networked:
		player.rpc_request_weapon_upgrade.rpc_id(1, weapon_key, stat, amount, cost)
		_show_status("⬆ %s requested…" % upg["label"])
		return
	if not _check_funds(cost): return
	# Apply to the matching weapon in WeaponManager
	var wm : Node = player.get("weapon_manager") if "weapon_manager" in player else null
	if not is_instance_valid(wm): return
	var applied := false
	if wm.has_method("get_weapons_of_type"):
		for w in wm.get_weapons_of_type(weapon_key):
			_apply_weapon_stat(w, stat, amount); applied = true
	if not applied:
		# Fallback: search all weapons for matching class/name
		var weapons_arr : Array = wm.get("weapons") if "weapons" in wm else []
		for w in weapons_arr:
			if not is_instance_valid(w): continue
			var wname : String = w.get_class().to_lower()
			if weapon_key in wname or (weapon_key == "laser" and ("laser" in wname or "bolt" in wname)) 				or (weapon_key == "rocket" and "rocket" in wname) 				or (weapon_key == "flame" and "flame" in wname) 				or (weapon_key == "sword" and "sword" in wname):
				_apply_weapon_stat(w, stat, amount); applied = true
	_show_status("⬆ %s!" % upg["label"])


func _apply_weapon_stat(w: Node, stat: String, amount: float) -> void:
	match stat:
		"damage":
			if "damage" in w: w.set("damage", float(w.get("damage")) + amount)
		"fire_rate":
			if "fire_rate" in w: w.set("fire_rate", maxf(float(w.get("fire_rate")) * (1.0 - amount), 0.05))
		"ammo_cap":
			if "max_ammo" in w:
				var inc : float = float(w.get("max_ammo")) * amount if amount < 1.0 else amount
				w.set("max_ammo", int(float(w.get("max_ammo")) + inc))
				w.set("ammo",     int(float(w.get("ammo"))     + inc))
		"proj_speed":
			if "proj_speed"     in w: w.set("proj_speed",     float(w.get("proj_speed"))     * (1.0 + amount))
			if "bullet_speed"   in w: w.set("bullet_speed",   float(w.get("bullet_speed"))   * (1.0 + amount))
			if "projectile_speed" in w: w.set("projectile_speed", float(w.get("projectile_speed")) * (1.0 + amount))
		"attack_range":
			if "attack_range"   in w: w.set("attack_range",   float(w.get("attack_range"))   * (1.0 + amount))
		"swing_speed":
			if "swing_cooldown" in w: w.set("swing_cooldown", maxf(float(w.get("swing_cooldown")) * (1.0 - amount), 0.1))
			if "attack_speed"   in w: w.set("attack_speed",   float(w.get("attack_speed"))   * (1.0 + amount))
		"blast_radius":
			if "explosion_radius" in w: w.set("explosion_radius", float(w.get("explosion_radius")) * (1.0 + amount))
		"burn_time":
			if "burn_duration"  in w: w.set("burn_duration",  float(w.get("burn_duration"))  * (1.0 + amount))
		"range":
			if "range"          in w: w.set("range",          float(w.get("range"))          * (1.0 + amount))
			if "max_range"      in w: w.set("max_range",      float(w.get("max_range"))      * (1.0 + amount))


# ─────────────────────────────────────────────────────────────
# TAB 8 — CLASS PERKS
# ─────────────────────────────────────────────────────────────
func _populate_perks_tab() -> void:
	var vbox := _get_tab_vbox(TAB_PERKS)
	if not vbox: return
	vbox.add_theme_constant_override("separation", 8)

	var class_id : int = 0
	if is_instance_valid(player) and "player_class" in player:
		class_id = int(player.get("player_class"))

	var perks : Array = CLASS_PERKS.get(class_id, DEFAULT_PERKS)
	vbox.add_child(_make_section_label("Choose ONE perk for this match:"))

	for perk in perks:
		var is_selected : bool = _selected_perk_id == perk["id"]
		var btn_text    : String = "%s  %s\n%s" % [
			("✅ " if is_selected else ""), perk["label"], perk["desc"]]
		var btn := _make_button(btn_text)
		btn.custom_minimum_size.y = 60
		if is_selected:
			btn.modulate = Color(0.6, 1.0, 0.6)
		var _pid : String = perk["id"]
		var _perk : Dictionary = perk
		btn.pressed.connect(func(): _on_perk_selected(_perk, vbox))
		vbox.add_child(btn)
		_register_button(TAB_PERKS, btn, 0)


func _on_perk_selected(perk: Dictionary, vbox: VBoxContainer) -> void:
	if _selected_perk_id == perk["id"]:
		return  # already selected
	_selected_perk_id = perk["id"]

	# Apply stat bonus if any
	if is_instance_valid(player) and perk["stat"] != "" and perk["amount"] != 0:
		if player.has_method("apply_upgrade"):
			player.apply_upgrade(perk["stat"], float(perk["amount"]))

	# Store perk id on player for special handling
	if is_instance_valid(player) and "selected_perk" in player:
		player.set("selected_perk", perk["id"])

	_show_status("⭐ Perk selected: %s" % perk["label"])

	# Refresh perk buttons — collect first, then free
	var children : Array = vbox.get_children()
	for child in children:
		vbox.remove_child(child)
		child.queue_free()
	_populate_perks_tab()
