# ============================================================
# player.gd — Hybrid FPS ↔ TopDown Controller
# ============================================================
extends CharacterBody3D

# ── Identity ──────────────────────────────────────────────────
var player_id : int = 1
var team_id   : int = 1
var device_id : int = -1
# local_input_slot: which LOCAL device-input actions (p{n}_*) this instance reads.
# In local split-screen, one process owns every player, so this always equals
# player_id -- unchanged there. Over the network, each client process has
# exactly ONE local human and always reads slot 1, regardless of the
# network-facing player_id the server assigned (1-4). See _a() below and
# C:\Users\gbran\.claude\plans\reactive-sparking-finch.md Phase 1.
var local_input_slot : int = 1

# ── Movement exports ─────────────────────────────────────────
@export_group("Movement")
@export var walk_speed    : float = 7.0
@export var sprint_speed  : float = 11.0
@export var acceleration  : float = 14.0
@export var air_control   : float = 4.0
@export var jump_velocity : float = 6.5
@export var gravity_force : float = 20.0

@export var debug_mouse : bool = false

@export_group("Mouse")
@export var mouse_sensitivity : float = 0.15
@export var mouse_smoothing   : float = 10.0
@export var _invert_movement  : bool  = false
@export var max_look_up       : float = 89.0
@export var max_look_down     : float = -89.0

@export_group("Camera FX")
@export var headbob_amount  : float = 0.05
@export var headbob_speed   : float = 10.0
@export var sway_amount     : float = 1.5
@export var sway_smoothing  : float = 8.0
@export var tilt_amount     : float = 3.0

@export_group("Top Down")
@export var topdown_height        : float = 22.0
@export var weapon_offset          : Vector3 = Vector3(0.15, -0.2, -0.4)
@export var td_zoom_min           : float = 20.0
@export var td_zoom_max           : float = 28.0
@export var td_zoom_speed         : float = 1.2
@export var td_enemy_scan_radius  : float = 25.0
@export var topdown_angle         : float = -70.0
@export var topdown_follow_speed  : float = 7.0
@export var td_aim_smoothing      : float = 14.0
@export var td_flip_facing        : bool  = false
@export var dash_speed            : float = 18.0
@export var dash_time             : float = 0.15
@export var dash_cooldown         : float = 0.8

@export_group("FPS")
@export var eye_height : float = 1.65

@export_group("Aim Assist")
@export var aim_assist_radius   : float = 4.0
@export var aim_assist_strength : float = 0.18
@export var bullet_magnetism    : float = 0.22
@export var magnetism_radius    : float = 3.5

@export_group("Audio")
@export var footstep_sounds          : Array[AudioStream] = []
@export var footstep_sounds_concrete : Array[AudioStream] = []
@export var footstep_sounds_dirt     : Array[AudioStream] = []
@export var damage_sounds    : Array[AudioStream] = []
@export var death_sounds     : Array[AudioStream] = []
@export var hurt_sounds      : Array[AudioStream] = []
@export var respawn_sounds   : Array[AudioStream] = []
@export var shop_open_sound  : AudioStream = null
@export var shop_close_sound : AudioStream = null
@export_range(0.0,1.0,0.05) var shop_sound_volume : float = 0.8

# ── Node refs ─────────────────────────────────────────────────
@onready var head           : Node3D        = get_node_or_null("CameraPivot") as Node3D
@onready var fps_pivot      : Node3D        = $CameraRoot/FPSPivot
@onready var fps_camera     : Camera3D      = _get_fps_camera()
@onready var td_pivot       : Node3D        = $CameraRoot/TopDownPivot
@onready var td_camera      : Camera3D      = _get_td_camera()
@onready var animation_tree : AnimationTree = get_node_or_null("AnimationTree")

# weapon_manager is found at runtime — NOT via $WeaponsManager
# because it lives under Camera3D, not directly under Player
var weapon_manager : Node = null

func _get_fps_camera() -> Camera3D:
	for path in ["CameraRoot/FPSPivot/FPSCamera",
				 "CameraRoot/FPSPivot/Camera3D",
				 "CameraRoot/FPSPivot/Camera",
				 "Head/Camera3D", "Head/Camera"]:
		var n := get_node_or_null(path)
		if n is Camera3D: return n as Camera3D
	var found := find_children("*", "Camera3D", true, false)
	if not found.is_empty(): return found[0] as Camera3D
	return null

func _get_td_camera() -> Camera3D:
	for path in ["CameraRoot/TopDownPivot/TopDownCamera",
				 "CameraRoot/TopDownPivot/Camera3D",
				 "CameraRoot/TopDownPivot/Camera",
				 "TopDownPivot/TopDownCamera", "TopDownCamera"]:
		var n := get_node_or_null(path)
		if n is Camera3D: return n as Camera3D
	var found := find_children("*", "Camera3D", true, false)
	if found.size() >= 2: return found[1] as Camera3D
	return null

const ANIM_MOVE       := "parameters/Locomotion/blend_position"
const ANIM_SHOOT      := "parameters/shoot_shot/request"
const ANIM_JUMP       := "parameters/jump/request"
const ANIM_DEATH      := "parameters/death/request"
const ANIM_SHOOT_FILT := "parameters/shot/request"

enum CameraMode { FPS, TOPDOWN }
var current_mode : CameraMode = CameraMode.FPS
var topdown_mode : bool = false
var shop_open    : bool = false
var _tab_state   : int  = 0
var _deck_open              : bool         = false
var _class_selecting        : bool         = false
var _class_select_ui        : Node         = null
var hud                     : Node         = null   # this player's own HUD — set by SSM

var health     : float = 100.0
var max_health : float = 100.0
var is_dead    : bool  = false
var upgrades   : Dictionary = {
	"move_speed":0.0,"damage":0.0,"fire_rate":0.0,
	"reload_speed":0.0,"max_health":0.0
}

# ── Kill streak tracking ─────────────────────────────────────
var _kill_streak_count  : int   = 0
var _kill_streak_timer  : float = 0.0
const KILL_STREAK_WINDOW : float = 4.0

# ── Sword durability ─────────────────────────────────────────
var sword_charge     : float = 100.0
var sword_max_charge : float = 100.0
const SWORD_DRAIN_PER_KILL : float = 8.0

# ── Ultimate kill-charge ──────────────────────────────────────
var ult_charge     : float = 0.0
var ult_charge_max : float = 100.0
const ULT_CHARGE_PER_KILL : float = 12.0
const ULT_CHARGE_PER_DMG  : float = 0.04   # charge gained per damage point dealt
# Ult charge spent when a class ability fires (slot 3 = movement, always free)
const ULT_ABILITY_COSTS : Array[float] = [8.0, 15.0, 25.0, 0.0]

# ── Class lock ───────────────────────────────────────────────
var _class_lock_timer    : float = 0.0
const CLASS_LOCK_DURATION : float = 120.0

# ── Ability synergy ───────────────────────────────────────────
var _last_ability_used  : int   = -1
var _last_ability_time  : float = -1.0
const SYNERGY_WINDOW    : float = 3.0
var _synergy_active     : bool  = false
var _synergy_timer      : float = 0.0
const SYNERGY_DURATION  : float = 6.0

# ── Selected perk ─────────────────────────────────────────────
var selected_perk : String = ""

# ── Grenades ──────────────────────────────────────────────────
var frag_grenades       : int   = 3
var flame_grenades      : int   = 2
var _frag_cd            : float = 0.0
var _flame_cd           : float = 0.0
const FRAG_COOLDOWN     : float = 8.0
const FLAME_COOLDOWN    : float = 10.0
const FRAG_RADIUS       : float = 8.0
const FRAG_DAMAGE       : float = 180.0
const FLAME_RADIUS      : float = 10.0
const FLAME_DAMAGE      : float = 40.0
const FLAME_DURATION    : float = 5.0

# ── Purifier beacon ───────────────────────────────────────────
var _purifier_cd        : float = 0.0
const PURIFIER_COOLDOWN : float = 45.0

var ability_slots     : Array        = [null]
var ability_cooldowns : Array[float] = [0.0]
var _rapid_fire_timer    : float = 0.0
var _double_damage_timer : float = 0.0
var _shield_timer        : float = 0.0
var _ghost_timer         : float = 0.0
var _on_ladder           : bool  = false
var _on_grav_lift        : bool  = false
var _grav_lift_exit_y    : float = 0.0
var _grav_lift_speed     : float = 8.0
var _ladder_top_y        : float = 0.0
var _ladder_climb_speed  : float = 5.0
var _sprint_boost_timer  : float = 0.0
var _berserk_timer       : float = 0.0

var mouse_input  : Vector2 = Vector2.ZERO
var smooth_mouse : Vector2 = Vector2.ZERO
var _dbg_mouse_count  : int   = 0
var _dbg_mouse_timer  : float = 0.0

var move_input   : Vector2 = Vector2.ZERO
var wish_dir     : Vector3 = Vector3.ZERO
var aim_direction: Vector3 = Vector3.FORWARD

var _td_aim_angle                    : float = 0.0
var _fps_rotation_y_before_topdown   : float = 0.0
var _fps_camera_basis_before_topdown : Basis = Basis()
var _td_zoom_time   : float = 0.0
var _td_zoom_base   : float = 0.0
const TD_ZOOM_SPEED : float = 0.35
const TD_ZOOM_RANGE : float = 1.8
var _transitioning   : bool        = false
var _transition_cl   : CanvasLayer = null
var _transition_rect : ColorRect   = null
var _grappler          : Node = null
var _mounted_dragon    : Node = null
var _dragon_zoom       : float = 55.0
var _dragon_zoom_min   : float = 20.0
var _dragon_zoom_max   : float = 90.0
var _movement_locked   : bool  = false
var _grappler_equipped : bool  = false
var _deck_ui           : Node  = null
var _jump_count        : int   = 0
var _max_jumps         : int   = 2
var _is_sliding        : bool  = false
var _slide_timer       : float = 0.0
var _slide_dir         : Vector3 = Vector3.ZERO
const SLIDE_SPEED      : float = 14.0
const SLIDE_DURATION   : float = 0.55

var crystals             : int   = 0
var enchant_damage_mult  : Array = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
var enchant_weakness     : Array = [0,   2,   1,   4,   3,   6,   5  ]
signal crystals_changed(total: int)
var _combat_zoom       : float   = 22.0
var virtual_cursor_pos : Vector2 = Vector2.ZERO
var cursor_velocity    : Vector2 = Vector2.ZERO
var _dash_active  : bool    = false
var _dash_timer   : float   = 0.0
var _dash_cd      : float   = 0.0
var _dash_dir     : Vector3 = Vector3.ZERO

var headbob_timer : float = 0.0
var shop          : Control = null
var recoil        : float   = 0.0
var _sfx          : AudioStreamPlayer3D = null
var _footstep     : AudioStreamPlayer3D = null
var _foot_timer   : float = 0.0
var cursor_node   : Control = null
var cursor_pos    : Vector2 = Vector2.ZERO
var _minimap      : Node    = null

signal health_changed(current: float, maximum: float)
signal abilities_changed()
signal died()
signal respawned()


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	_deck_open = false
	print("=== PLAYER.GD v7 LOADED — if you don't see this, wrong file ===")
	call_deferred("_show_class_select")
	add_to_group("player")
	add_to_group("players")
	add_to_group("units")
	health = max_health

	print("[Player] fps_camera: ", fps_camera)
	print("[Player] td_camera:  ", td_camera)

	if not is_instance_valid(fps_camera):
		push_error("[Player] fps_camera is NULL — check $CameraRoot/FPSPivot/FPSCamera exists"); return
	if not is_instance_valid(td_camera):
		push_error("[Player] td_camera is NULL — check $CameraRoot/TopDownPivot/TopDownCamera exists"); return

	# Networked: only the locally-controlled player's camera should ever
	# activate, or every client would see through whichever player's camera
	# happened to init last. Local split-screen is unaffected -- SSM parents
	# each player under its own SubViewport, where "current" is scoped
	# per-viewport rather than a scene-tree-wide top-level camera.
	var _cameras_active : bool = not _is_remote_puppet()
	fps_camera.current   = _cameras_active
	fps_camera.position  = Vector3.ZERO
	fps_camera.rotation  = Vector3.ZERO
	fps_camera.near      = 0.03
	fps_pivot.position   = Vector3(0.0, eye_height, 0.0)

	var cam_root := get_node_or_null("CameraRoot") as Node3D
	if is_instance_valid(cam_root):
		cam_root.position = Vector3.ZERO
		cam_root.rotation = Vector3.ZERO

	td_camera.current = false
	td_pivot.position = Vector3(0.0, topdown_height, 0.0)
	call_deferred("_init_td_camera_look")

	print("[Player] cameras OK | fps=%s | td=%s" % [fps_camera.name, td_camera.name])

	if device_id == -1:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		Input.use_accumulated_input = false
		print("[Player] Mouse captured | raw input enabled")

	_sfx = AudioStreamPlayer3D.new(); add_child(_sfx)
	var af := get_node_or_null("AudioFootstep")
	if is_instance_valid(af) and af is AudioStreamPlayer3D:
		_footstep = af as AudioStreamPlayer3D
	else:
		_footstep = AudioStreamPlayer3D.new(); add_child(_footstep)

	# ── Weapon binding — deferred so SSM finishes attaching scene tree ──
	call_deferred("_bind_weapon_manager")

	if is_instance_valid(animation_tree):
		animation_tree.active = true
		for param in ["parameters/Locomotion/blend_position",
					  "parameters/move_blend/blend_position"]:
			animation_tree.set(param, 0.0)

	floor_snap_length   = 0.4
	floor_stop_on_slope = false
	floor_max_angle     = deg_to_rad(50.0)

	get_tree().create_timer(0.2).timeout.connect(_setup_body_layers)
	get_tree().create_timer(0.5).timeout.connect(_find_grappler)

	var _aura_script := load("res://scripts/PlayerEnergyAura.gd") if ResourceLoader.exists("res://scripts/PlayerEnergyAura.gd") else null
	if not is_instance_valid(_aura_script):
		for _ap in ["res://PlayerEnergyAura.gd","res://scripts/aura/PlayerEnergyAura.gd","res://player/PlayerEnergyAura.gd"]:
			if ResourceLoader.exists(_ap): _aura_script = load(_ap); break
	if is_instance_valid(_aura_script):
		var _aura_node : Node = _aura_script.new()
		_aura_node.name = "PlayerEnergyAura"
		add_child(_aura_node)
		print("[Player] Energy aura attached from: ", _aura_script.resource_path)
	else:
		push_warning("[Player] PlayerEnergyAura.gd not found — place it at res://scripts/PlayerEnergyAura.gd")

	# Restore crystals from run save (class is restored in _show_class_select)
	var _rsm_r := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(_rsm_r) and _rsm_r.has_save():
		var _sc : int = _rsm_r.get_player_crystals(player_id)
		if _sc > 0:
			crystals = _sc
			crystals_changed.emit(crystals)

	var _mm_scr : Script = null
	for _mm_path in ["res://MinimapOverlay.gd", "res://scripts/MinimapOverlay.gd"]:
		if ResourceLoader.exists(_mm_path):
			_mm_scr = load(_mm_path) as Script
			break
	if is_instance_valid(_mm_scr):
		_minimap = _mm_scr.new()
		_minimap.name = "MinimapOverlay"
		add_child(_minimap)


# ============================================================
# WEAPON MANAGER BINDING — deferred, searches full scene tree
# ============================================================
func _bind_weapon_manager() -> void:
	# Own subtree FIRST — in split screen every player has their own WeaponsManager
	# descendant.  Never grab a sibling player's WM.
	var own := find_children("WeaponsManager", "Node", true, false)
	if not own.is_empty() and is_instance_valid(own[0]) and own[0].has_method("bind_player"):
		weapon_manager = own[0]

	# Group fallback — only accept nodes that live under this player
	if not is_instance_valid(weapon_manager):
		for node in get_tree().get_nodes_in_group("weapon_manager"):
			if is_instance_valid(node) and node.has_method("bind_player") \
					and is_ancestor_of(node):
				weapon_manager = node
				break

	if is_instance_valid(weapon_manager):
		weapon_manager.bind_player(self, fps_camera)
		print("[Player] WeaponsManager bound at: ", weapon_manager.get_path())
	else:
		push_error("[Player] WeaponsManager NOT FOUND — check scene tree")


func _show_class_select() -> void:
	# If a run save already recorded a class for this player, restore it directly
	var _rsm_cs := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(_rsm_cs) and _rsm_cs.has_save():
		var _saved_cls : int = _rsm_cs.get_player_class(player_id)
		if _saved_cls != 0:
			_on_class_chosen(_saved_cls)
			return

	var scr : Script = null
	for _sp in ["res://scripts/ClassSelectUI.gd", "res://ClassSelectUI.gd"]:
		if ResourceLoader.exists(_sp): scr = load(_sp) as Script; break
	if not is_instance_valid(scr):
		push_warning("[Player] ClassSelectUI.gd not found — skipping class select")
		call_deferred("_show_deck_ui"); return

	_class_selecting = true

	# ── Determine this player's screen quadrant ────────────────────────────────
	# quad_size = pixel dimensions of this player's viewport area
	# quad_pos  = top-left corner of that area in root-Window screen coordinates
	var quad_size : Vector2 = get_tree().root.get_visible_rect().size
	var quad_pos  : Vector2 = Vector2.ZERO
	var ssm := get_tree().get_first_node_in_group("splitscreen_manager")
	if is_instance_valid(ssm) and ssm.has_method("get_viewport_for_player"):
		var sv : Viewport = ssm.get_viewport_for_player(self)
		if is_instance_valid(sv):
			quad_size = Vector2(sv.size)
			# SubViewportContainer is the parent; its .position gives the screen offset
			var ctn := sv.get_parent()
			if is_instance_valid(ctn) and ctn is Control:
				quad_pos = (ctn as Control).position

	# ── Add ClassSelectUI to the ROOT WINDOW (not inside SubViewport) ──────────
	# This is the key fix for mouse input in split-screen:
	#   • SubViewport.push_input() does NOT propagate _input() to child nodes,
	#     so any UI inside a SubViewport can't reliably receive mouse clicks.
	#   • At root level the standard Godot GUI system routes clicks correctly.
	# A CanvasLayer at layer=200 renders above the SSM_Canvas (layer=-100) that
	# holds the SubViewportContainers, so it appears on top of all game content.
	# ClassSelectUI.screen_offset positions it at the correct quadrant on screen.
	var layer_node := CanvasLayer.new()
	layer_node.name  = "ClassSelectLayer_P%d" % player_id
	layer_node.layer = 200
	get_tree().root.add_child(layer_node)

	var ui : Node = scr.new()
	ui.set("player_id",     player_id)
	ui.set("device_id",     device_id)
	ui.set("viewport_size", quad_size)
	ui.set("screen_offset", quad_pos)
	layer_node.add_child(ui)
	_class_select_ui = layer_node   # freeing this frees the UI too

	print("[Player] P%d ClassSelectUI → root layer 200  offset=%s  size=%s" % [
		player_id, str(quad_pos), str(quad_size)])

	# KBM player needs visible mouse to click cards
	if device_id == -1:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if is_instance_valid(ssm) and ssm.has_method("warp_mouse_to_player"):
			ssm.warp_mouse_to_player(player_id - 1)

	if ui.has_signal("class_chosen"):
		ui.class_chosen.connect(_on_class_chosen)


func _on_class_chosen(class_id: int) -> void:
	_class_selecting = false
	# Free the root-level CanvasLayer that hosted ClassSelectUI (frees UI too).
	if is_instance_valid(_class_select_ui):
		_class_select_ui.queue_free()
		_class_select_ui = null
	# Restore mouse capture for KBM-FPS players — deck UI will override this next
	if device_id == -1 and current_mode == CameraMode.FPS:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var cls : PlayerClass = PlayerClass.NONE
	match class_id:
		1:  cls = PlayerClass.NECROMANCER
		2:  cls = PlayerClass.BERSERKER
		3:  cls = PlayerClass.PALADIN
		4:  cls = PlayerClass.SHADOWBLADE
		5:  cls = PlayerClass.STORMCALLER
		6:  cls = PlayerClass.BLOODMAGE
		7:  cls = PlayerClass.TIMEWEAVER
		8:  cls = PlayerClass.VOIDWALKER
		9:  cls = PlayerClass.IRONCLAD
		10: cls = PlayerClass.PLAGUEMASTER
		11: cls = PlayerClass.SOULREAPER
		12: cls = PlayerClass.WARLOCK
		13: cls = PlayerClass.PHOENIX
		14: cls = PlayerClass.GRAVEMIND
		15: cls = PlayerClass.DOOMSLAYER
	set_player_class(cls)
	call_deferred("_show_deck_ui")


func _show_deck_ui() -> void:
	if _deck_open: return
	await get_tree().process_frame
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var pid : int = int(get("player_id") if "player_id" in self else 1)

	# Find which viewport this player belongs to via SSM
	var parent_vp : Node = get_viewport()
	var ssm := get_tree().get_first_node_in_group("splitscreen_manager")
	if is_instance_valid(ssm) and ssm.has_method("get_player_viewport"):
		var pv : Node = ssm.call("get_player_viewport", pid - 1)
		if is_instance_valid(pv): parent_vp = pv

	_deck_ui = null
	for node in get_tree().get_nodes_in_group("creep_deck_ui"):
		if is_instance_valid(node) and node.has_meta("owner_pid") and int(node.get_meta("owner_pid")) == pid:
			_deck_ui = node; break
	if not is_instance_valid(_deck_ui):
		var scr : Script = null
		for _dp in ["res://scripts/CreepDeckUI.gd", "res://CreepDeckUI.gd",
				"res://ui/CreepDeckUI.gd", "res://scenes/CreepDeckUI.gd"]:
			if ResourceLoader.exists(_dp): scr = load(_dp) as Script; break
		if not is_instance_valid(scr):
			push_warning("[Player P%d] CreepDeckUI.gd not found" % pid); return
		_deck_ui = Control.new()
		_deck_ui.set_script(scr)
		_deck_ui.set_meta("owner_pid", pid)
		_deck_ui.add_to_group("creep_deck_ui")
		# Add to player's SubViewport so it fills their screen quadrant
		parent_vp.add_child(_deck_ui)
	# Allow all containers to pass mouse so every player can click their deck
	if is_instance_valid(ssm) and ssm.has_method("set_all_containers_mouse_pass"):
		ssm.set_all_containers_mouse_pass(true)
	if _deck_ui.has_method("show_for_player"):
		_deck_open = true
		_deck_ui.show_for_player(pid, parent_vp)
		if _deck_ui.has_signal("deck_confirmed"):
			if not _deck_ui.deck_confirmed.is_connected(_on_deck_confirmed):
				_deck_ui.deck_confirmed.connect(_on_deck_confirmed)

func _on_deck_confirmed(pid: int, deck: Array) -> void:
	_deck_open = false
	# Restore gamepad players' containers to IGNORE so their mouse doesn't bleed into KBM space
	var ssm2 := get_tree().get_first_node_in_group("splitscreen_manager")
	if is_instance_valid(ssm2) and ssm2.has_method("set_all_containers_mouse_pass"):
		ssm2.set_all_containers_mouse_pass(false)
	# NOTE: players live in the scene root, so get_viewport() returns the root Window,
	# never a SubViewport. Do NOT touch handle_input_locally here — that is SSM's
	# responsibility and must always stay true on player SubViewports.
	print("[Player] Deck confirmed for P%d: %s" % [pid, str(deck)])
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("set_player_deck"):
		dm.set_player_deck(pid, deck)
	var gpc := get_tree().get_first_node_in_group("game_manager")
	if is_instance_valid(gpc) and gpc.has_method("set_team_ready"):
		gpc.set_team_ready(team_id, true)
	# Free rather than hide — ensures a fresh DeckUI node each game (no stale static state)
	if is_instance_valid(_deck_ui):
		_deck_ui.queue_free()
		_deck_ui = null
	if current_mode == CameraMode.FPS:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _bind_screen_shake() -> void:
	var ss := get_tree().get_first_node_in_group("screen_shake")
	if is_instance_valid(ss) and is_instance_valid(fps_camera):
		ss.bind_camera(fps_camera)

func _on_player_died(killer_name: String = "", weapon: String = "") -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		var rs := h.find_child("RespawnScreen", true, false)
		if is_instance_valid(rs) and rs.has_method("show_death"):
			rs.show_death(killer_name, weapon)
			if not rs.respawn_requested.is_connected(_do_respawn):
				rs.respawn_requested.connect(_do_respawn)
			break

func _do_respawn() -> void:
	health = max_health
	velocity = Vector3.ZERO
	is_dead  = false
	if is_instance_valid(fps_camera): fps_camera.rotation = Vector3.ZERO
	var spawn_pos : Vector3 = global_position
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not (b is Node3D): continue
		if "team_id" in b and int(b.get("team_id")) == team_id:
			spawn_pos = (b as Node3D).global_position + Vector3(randf_range(-4,4), 2, randf_range(-4,4))
			break
	if spawn_pos == global_position:
		var bnames := ["Base","base","Base1"] if team_id == 1 else ["Base 2","base2","Base2"]
		for bname in bnames:
			var bn := get_tree().root.find_child(bname, true, false)
			if is_instance_valid(bn) and bn is Node3D:
				spawn_pos = (bn as Node3D).global_position + Vector3(randf_range(-4,4), 2, randf_range(-4,4))
				break
	global_position = spawn_pos
	health_changed.emit(health, max_health)

func _try_interact_or_ability() -> void:
	for d in get_tree().get_nodes_in_group("dragon"):
		if not is_instance_valid(d) or not (d is Node3D): continue
		if global_position.distance_to((d as Node3D).global_position) <= 10.0:
			_try_interact(); return
	if is_instance_valid(_mounted_dragon):
		_try_interact(); return

func _try_interact() -> void:
	if is_instance_valid(_mounted_dragon) and _mounted_dragon.has_method("dismount"):
		_mounted_dragon.dismount()
		_mounted_dragon = null; return
	for d in get_tree().get_nodes_in_group("dragon"):
		if not is_instance_valid(d) or not (d is Node3D): continue
		if global_position.distance_to((d as Node3D).global_position) > 8.0: continue
		if d.has_method("try_mount") and d.try_mount(self):
			_mounted_dragon = d
			_show_message("🐉 Dragon mounted!  WASD=steer  Space=flap  Shift=dive  LMB=fire  E=dismount", Color(0.9, 0.6, 0.2))
			return

func set_movement_locked(locked: bool) -> void:
	_movement_locked = locked

func _find_grappler() -> void:
	for ch in get_children():
		if not is_instance_valid(ch): continue
		if ch.name == "GrapplerGun" or (ch.get_script() != null and "GrapplerGun" in str(ch.get_script().resource_path)):
			_grappler = ch; break
	if not is_instance_valid(_grappler):
		push_warning("[Player] GrapplerGun not found"); return
	_grappler.add_to_group("grappler")
	if _grappler.has_method("equip"): _grappler.equip(fps_camera, self)
	_grappler.visible = false
	print("[Player] GrapplerGun found and equipped")

func _toggle_grappler() -> void:
	if not is_instance_valid(_grappler): return
	if _grappler_equipped:
		_grappler_equipped = false
		_grappler.visible = false
		if is_instance_valid(weapon_manager):
			weapon_manager.visible = true
			var wep : Node = weapon_manager.get_current_weapon()
			if is_instance_valid(wep): wep.visible = true
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("show_grapple_ui"): h.show_grapple_ui(false); break
	else:
		_grappler_equipped = true
		_grappler.visible = true
		if _grappler.has_method("equip"): _grappler.equip(fps_camera, self)
		if is_instance_valid(weapon_manager):
			var wep : Node = weapon_manager.get_current_weapon()
			if is_instance_valid(wep): wep.visible = false
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("show_grapple_ui"): h.show_grapple_ui(true); break
		if _grappler.has_signal("cooldown_updated"):
			if not _grappler.cooldown_updated.is_connected(_on_grapple_cooldown):
				_grappler.cooldown_updated.connect(_on_grapple_cooldown)

func _on_grapple_cooldown(remaining: float, total: float) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("update_grapple_cooldown"):
			h.update_grapple_cooldown(remaining, total); break

func _setup_body_layers() -> void:
	_set_body_visible(false)

func _get_body_meshes() -> Array:
	var meshes : Array = []
	var weapon_nodes : Array = []
	if is_instance_valid(weapon_manager):
		weapon_nodes = weapon_manager.find_children("*", "Node", true, false)
		weapon_nodes.append(weapon_manager)
	for mesh in find_children("*", "MeshInstance3D", true, false):
		var mi := mesh as MeshInstance3D
		if mi in weapon_nodes: continue
		if is_instance_valid(weapon_manager) and weapon_manager.is_ancestor_of(mi): continue
		if mi.has_meta("is_weapon_mesh"): continue
		meshes.append(mi)
	return meshes

func _refresh_body_visibility() -> void:
	if current_mode == CameraMode.FPS: _set_body_visible(false)
	else: _set_body_visible(true)

func _set_body_visible(visible_flag: bool) -> void:
	for mi in _get_body_meshes():
		(mi as MeshInstance3D).visible = visible_flag


# ============================================================
# INPUT HELPERS
# ============================================================
# True only when networked AND this instance belongs to a different peer --
# i.e. this is a remote player we're just rendering, not controlling. Always
# false in local split-screen (has_multiplayer_peer() is false there).
func _is_remote_puppet() -> bool:
	return multiplayer.has_multiplayer_peer() and not is_multiplayer_authority()

func _a(n: String) -> String: return "p%d_%s" % [local_input_slot, n]
func _act(n: String) -> bool:
	if device_id == -99: return false   # no device assigned — block all input
	if not InputMap.has_action(_a(n)): return false
	if Input.is_action_pressed(_a(n)):
		var ev_list := InputMap.action_get_events(_a(n))
		for ev in ev_list:
			if ev is InputEventKey or ev is InputEventMouseButton:
				return device_id == -1  # KBM-bound action: only KBM player fires it
		return true  # gamepad action: Godot filters by device automatically
	return false
func _act_just(n: String) -> bool:
	if device_id == -99: return false
	if not InputMap.has_action(_a(n)): return false
	if Input.is_action_just_pressed(_a(n)):
		var ev_list := InputMap.action_get_events(_a(n))
		for ev in ev_list:
			if ev is InputEventKey or ev is InputEventMouseButton:
				return device_id == -1
		return true
	return false
func _act_strength(n: String) -> float:
	return Input.get_action_strength(_a(n)) if InputMap.has_action(_a(n)) else 0.0
func _axis(axis: int) -> float:
	if device_id < 0: return 0.0
	var v := Input.get_joy_axis(device_id, axis)
	return v if absf(v) >= 0.15 else 0.0


# ============================================================
# INPUT
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	if _is_remote_puppet(): return   # remote player -- don't read local input for it
	if device_id == -99: return   # no device assigned
	if is_dead: return
	if _class_selecting or _deck_open: return
	if device_id == -1 and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED \
				and current_mode == CameraMode.FPS and not shop_open:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event: InputEvent) -> void:
	if _is_remote_puppet(): return   # remote player -- don't read local input for it
	if device_id == -1 and event is InputEventKey and event.pressed and not event.echo:

		if event.keycode == KEY_K:
			var cam_pos := get_viewport().get_camera_3d().global_position
			print("[DEBUG] Camera at: ", cam_pos)
			print("[DEBUG] Before spawn — z1=%d  z2=%d  z3=%d  total=%d" % [
				ZombieHordeManager.z1_count(),
				ZombieHordeManager.z2_count(),
				ZombieHordeManager.z3_count(),
				ZombieHordeManager.total_count()
			])
			print("[DEBUG] zombie_mesh set: ", ZombieHordeManager.zombie_mesh != null)
			print("[DEBUG] zombie_scene set: ", ZombieHordeManager.zombie_scene != null)
			print("[DEBUG] multimesh visible_count before: ",
				ZombieHordeManager._multimesh.visible_instance_count)

			ZombieHordeManager.spawn_horde(
				1000,
				AABB(Vector3(cam_pos.x - 20, 0.5, cam_pos.z - 20), Vector3(40, 0, 40))
			)
			print("Spawned 1000 zombies")

			# Check one frame later so the tick has run
			await get_tree().process_frame
			print("[DEBUG] After spawn — z1=%d  z2=%d  z3=%d  total=%d" % [
				ZombieHordeManager.z1_count(),
				ZombieHordeManager.z2_count(),
				ZombieHordeManager.z3_count(),
				ZombieHordeManager.total_count()
			])
			print("[DEBUG] multimesh visible_count after: ",
				ZombieHordeManager._multimesh.visible_instance_count)
			print("[DEBUG] First 3 z2 positions: ")
			for i in mini(3, ZombieHordeManager._z2_count):
				print("  [%d] " % i, ZombieHordeManager._z2_pos[i])

		# Press L to print camera vs first zombie distance
		if event.keycode == KEY_L:
			var cam := get_viewport().get_camera_3d()
			print("[DEBUG] Cam pos: ", cam.global_position)
			print("[DEBUG] Cam frustum visible: ", cam.get_frustum())
			print("[DEBUG] zombie_mesh: ", ZombieHordeManager.zombie_mesh)
			print("[DEBUG] mm instance visible: ", ZombieHordeManager._mm_instance.visible)
			print("[DEBUG] mm instance in tree: ", ZombieHordeManager._mm_instance.is_inside_tree())
			print("[DEBUG] z2 count: ", ZombieHordeManager._z2_count)
			if ZombieHordeManager._z2_count > 0:
				var zpos := ZombieHordeManager._z2_pos[0]
				var dist := cam.global_position.distance_to(zpos)
				print("[DEBUG] First z2 zombie at: ", zpos, " | dist from cam: ", dist)
				print("[DEBUG] Is in cam frustum: ",
					cam.is_position_in_frustum(zpos))

	if event is InputEventMouseMotion:
		if device_id == -1 and current_mode == CameraMode.FPS and not shop_open \
				and _targeting_slot < 0:
			mouse_input += (event as InputEventMouseMotion).relative
			if debug_mouse: _dbg_mouse_count += 1
		return

	if device_id == -1 and event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		# Block all gameplay input while selecting class or deck
		if _class_selecting or _deck_open: return
		match (event as InputEventKey).physical_keycode:
			KEY_TAB:
				if device_id == -1: _cycle_tab()
			KEY_ESCAPE:
				get_viewport().set_input_as_handled()
				if _targeting_slot >= 0:
					_cancel_targeting()
				else:
					_handle_pause_or_escape()
			KEY_Q:
				var _qev := event as InputEventKey
				if not _qev.shift_pressed: activate_ability(0)
			KEY_E:  _try_interact_or_ability()
			KEY_R:
				if is_instance_valid(weapon_manager):
					var wep : Node = weapon_manager.get_current_weapon()
					if is_instance_valid(wep) and "enchantment" in wep:
						var e : int = (int(wep.get("enchantment")) + 1) % 7
						wep.set("enchantment", e)
						if wep.has_method("set_enchantment"): wep.set_enchantment(e)
			KEY_F:
				var did_swing : bool = false
				if is_instance_valid(weapon_manager):
					var wep : Node = weapon_manager.get_current_weapon()
					if is_instance_valid(wep) and wep.has_method("swing"):
						wep.swing(); did_swing = true
			KEY_G:
				if not _is_wave_panel_open():
					_enchant_nearby_zombies()
				get_viewport().set_input_as_handled()
			KEY_X: _toggle_grappler()
			KEY_F5: set_topdown_mode(current_mode == CameraMode.FPS)
			KEY_F2:
				var _classes := [
					PlayerClass.NECROMANCER, PlayerClass.BERSERKER, PlayerClass.PALADIN,
					PlayerClass.SHADOWBLADE, PlayerClass.STORMCALLER, PlayerClass.BLOODMAGE,
					PlayerClass.TIMEWEAVER, PlayerClass.VOIDWALKER, PlayerClass.IRONCLAD,
					PlayerClass.PLAGUEMASTER, PlayerClass.SOULREAPER, PlayerClass.WARLOCK,
					PlayerClass.PHOENIX, PlayerClass.GRAVEMIND, PlayerClass.DOOMSLAYER
				]
				var _cur := _classes.find(player_class)
				set_player_class(_classes[(_cur + 1) % _classes.size()])
			KEY_1: _try_class_ability(0)
			KEY_2: _try_class_ability(1)
			KEY_3: _try_class_ability(2)
			KEY_4: _try_class_ability(3)
			KEY_V: _try_fire_ult()
			KEY_T: _throw_grenade(false)   # frag
			KEY_B: _throw_grenade(true)    # flame
			KEY_P: _deploy_purifier()

	if device_id == -1 and not shop_open and not _class_selecting and not _deck_open and event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			# ── Ground-targeting confirmation / cancellation ──
			if _targeting_slot >= 0:
				if mb.button_index == MOUSE_BUTTON_LEFT:
					_confirm_targeting(_target_pos)
					get_viewport().set_input_as_handled()
					return
				elif mb.button_index == MOUSE_BUTTON_RIGHT:
					_cancel_targeting()
					get_viewport().set_input_as_handled()
					return
			if is_instance_valid(_mounted_dragon) and mb.button_index == MOUSE_BUTTON_LEFT:
				return
			if _grappler_equipped and is_instance_valid(_grappler):
				if mb.button_index == MOUSE_BUTTON_LEFT:
					if _grappler.has_method("fire"): _grappler.fire()
					get_viewport().set_input_as_handled(); return
				elif mb.button_index == MOUSE_BUTTON_RIGHT:
					if _grappler.has_method("release"): _grappler.release()
					get_viewport().set_input_as_handled(); return
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				if is_instance_valid(_mounted_dragon):
					_dragon_zoom = clampf(_dragon_zoom - 3.0, _dragon_zoom_min, _dragon_zoom_max)
					_apply_dragon_zoom()
				elif is_instance_valid(weapon_manager): weapon_manager.switch_weapon(-1)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if is_instance_valid(_mounted_dragon):
					_dragon_zoom = clampf(_dragon_zoom + 3.0, _dragon_zoom_min, _dragon_zoom_max)
					_apply_dragon_zoom()
				elif is_instance_valid(weapon_manager): weapon_manager.switch_weapon(1)

	if event is InputEventJoypadButton:
		var btn := event as InputEventJoypadButton
		if btn.pressed and btn.device == device_id:
			match btn.button_index:
				JOY_BUTTON_Y:             _cycle_tab()
				JOY_BUTTON_START:         _handle_pause_or_escape()
				JOY_BUTTON_LEFT_SHOULDER: activate_ability(0)

# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	if is_dead or _class_selecting: return
	if _turret_warn_cooldown > 0.0: _turret_warn_cooldown -= delta

	if current_mode == CameraMode.FPS and not _deck_open:
		if device_id == -1: _handle_mouse_look(delta)
		else: _handle_stick_look(delta)
		_handle_camera_fx(delta)
		_update_fov(delta)

	if current_mode == CameraMode.TOPDOWN:
		_update_dynamic_zoom(delta)
		var cam_pos := global_position + Vector3(0.0, topdown_height, 0.0)
		td_camera.global_position = cam_pos
		td_camera.look_at(global_position + Vector3(0.0, 0.8, 0.0), Vector3.FORWARD)
		td_pivot.global_position = cam_pos

	_tick_ability_cooldowns(delta)
	_tick_ability_effects(delta)
	_tick_class_abilities(delta)
	_tick_meta_systems(delta)
	if is_instance_valid(animation_tree):
		var local_vel : Vector3 = global_transform.basis.inverse() * velocity
		var blend2d   : Vector2 = Vector2(
			local_vel.x / maxf(walk_speed, 0.01),
			local_vel.z / -maxf(walk_speed, 0.01))
		blend2d = blend2d.limit_length(1.0)
		animation_tree.set(ANIM_MOVE, blend2d)

	recoil = lerp(recoil, 0.0, delta * 12.0)


# ============================================================
# PHYSICS
# ============================================================
func _physics_process(delta: float) -> void:
	# Remote players: position/velocity are driven by the replicated
	# MultiplayerSynchronizer state, not local physics -- running
	# move_and_slide() here would fight that. Their AnimationTree still
	# updates from synced velocity in _process() above, so they keep animating.
	if _is_remote_puppet(): return
	if is_dead: return
	if _class_selecting:
		# Keep gravity/floor contact but block all player input
		velocity.x = move_toward(velocity.x, 0.0, 40.0)
		velocity.z = move_toward(velocity.z, 0.0, 40.0)
		if not is_on_floor(): velocity.y -= gravity_force * delta
		move_and_slide()
		return

	if _on_grav_lift:
		if global_position.y < _grav_lift_exit_y - 0.3:
			velocity.y = _grav_lift_speed
			move_and_slide(); return
		else:
			_on_grav_lift = false
			velocity.y = maxf(velocity.y, 3.0)

	if _on_ladder and global_position.y < _ladder_top_y:
		var fwd_input : float = 0.0
		if device_id == -1:
			fwd_input = _act_strength("move_forward") - _act_strength("move_backward")
		else:
			fwd_input = -_axis(JOY_AXIS_LEFT_Y)
		velocity.x = 0.0; velocity.z = 0.0
		velocity.y = fwd_input * _ladder_climb_speed
		if _act_just("jump"):
			_on_ladder = false
			velocity.y = jump_velocity * 0.6
		move_and_slide(); return
	else:
		if _on_ladder and global_position.y >= _ladder_top_y:
			_on_ladder = false

	if is_on_floor():
		if _jump_count > 0:
			var ss := get_tree().get_first_node_in_group("screen_shake")
			if is_instance_valid(ss) and ss.has_method("land"): ss.land()
		_jump_count = 0
		if _is_sliding:
			_slide_timer -= delta
			if _slide_timer <= 0.0: _end_slide()
	else:
		velocity.y -= gravity_force * delta
		if velocity.y < 0.0 and is_on_floor(): velocity.y = 0.0

	if shop_open:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta * 10.0)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta * 10.0)
	elif current_mode == CameraMode.FPS:
		_handle_fps_movement(delta)
	else:
		_handle_topdown_movement(delta)

	if current_mode == CameraMode.TOPDOWN and device_id >= 0:
		var stick := Vector2(_axis(JOY_AXIS_RIGHT_X), _axis(JOY_AXIS_RIGHT_Y))
		if stick.length() > 0.15:
			virtual_cursor_pos += stick * 1200.0 * get_physics_process_delta_time()
			virtual_cursor_pos.x = clamp(virtual_cursor_pos.x, 0.0, float(get_viewport().size.x))
			virtual_cursor_pos.y = clamp(virtual_cursor_pos.y, 0.0, float(get_viewport().size.y))

	_combat()
	_update_footsteps(delta)
	if is_on_wall() and is_on_floor() and not _is_sliding:
		var wall_n : Vector3 = get_wall_normal()
		velocity.x += wall_n.x * 0.5
		velocity.z += wall_n.z * 0.5
	if current_mode == CameraMode.TOPDOWN and not shop_open:
		_face_cursor_topdown(delta)
		_update_cursor()
	fps_camera.rotation.z = 0.0
	move_and_slide()
	_update_weapon_transform()


# ============================================================
# MOUSE LOOK
# ============================================================
func _handle_mouse_look(delta: float) -> void:
	if debug_mouse:
		_dbg_mouse_timer += get_process_delta_time()
		if _dbg_mouse_timer > 1.0:
			_dbg_mouse_timer = 0.0
			print("[MouseDebug] events/s=%d | mode=%s | fps_current=%s | pivot=%s" % [
				_dbg_mouse_count, str(Input.mouse_mode),
				str(fps_camera.current if is_instance_valid(fps_camera) else "null"),
				str(is_instance_valid(fps_pivot))])
			_dbg_mouse_count = 0
	mouse_input.x = clampf(mouse_input.x, -300.0, 300.0)
	mouse_input.y = clampf(mouse_input.y, -300.0, 300.0)
	var safe_delta : float = minf(delta, 0.05)
	smooth_mouse = smooth_mouse.lerp(mouse_input, 1.0 - exp(-mouse_smoothing * safe_delta))
	var rel      := smooth_mouse
	mouse_input   = Vector2.ZERO
	if rel.length_squared() < 0.00001: return
	if is_instance_valid(_mounted_dragon): return
	rotate_y(deg_to_rad(-rel.x * mouse_sensitivity))
	fps_pivot.rotation_degrees.x -= rel.y * mouse_sensitivity
	fps_pivot.rotation_degrees.x  = clamp(fps_pivot.rotation_degrees.x, max_look_down, max_look_up)

func _handle_stick_look(delta: float) -> void:
	var rx : float = _axis(JOY_AXIS_RIGHT_X)
	var ry : float = _axis(JOY_AXIS_RIGHT_Y)
	if absf(rx) < 0.1 and absf(ry) < 0.1: return
	var sens : float = 120.0
	if is_instance_valid(_mounted_dragon): return
	rotate_y(deg_to_rad(-rx * sens * delta))
	fps_pivot.rotation_degrees.x -= ry * sens * delta
	fps_pivot.rotation_degrees.x  = clamp(fps_pivot.rotation_degrees.x, max_look_down, max_look_up)


# ============================================================
# FPS MOVEMENT
# ============================================================
func _handle_fps_movement(delta: float) -> void:
	if _movement_locked or _deck_open: return
	var strafe := 0.0
	var fwd    := 0.0
	if device_id == -1:
		strafe = _act_strength("move_right") - _act_strength("move_left")
		fwd    = _act_strength("move_forward") - _act_strength("move_backward")
	else:
		strafe = _axis(JOY_AXIS_LEFT_X)
		fwd    = -_axis(JOY_AXIS_LEFT_Y)

	move_input = Vector2(strafe, fwd)
	var cam_basis : Basis = fps_camera.global_transform.basis if is_instance_valid(fps_camera) \
		else global_transform.basis
	var forward : Vector3 = Vector3(-cam_basis.z.x, 0, -cam_basis.z.z).normalized()
	var right   : Vector3 = Vector3( cam_basis.x.x, 0,  cam_basis.x.z).normalized()
	wish_dir = (forward * fwd + right * strafe)
	wish_dir.y = 0.0
	if wish_dir.length_squared() > 0.01: wish_dir = wish_dir.normalized()

	var spd := sprint_speed if _act("sprint") else walk_speed
	spd += float(upgrades.get("move_speed", 0.0))
	if _sprint_boost_timer > 0.0: spd *= 1.4
	if _berserk_timer      > 0.0: spd *= 1.6
	if _corruption_slow    > 0.0: spd *= (1.0 - _corruption_slow)

	var ctrl := acceleration if is_on_floor() else air_control
	velocity.x = move_toward(velocity.x, wish_dir.x * spd, ctrl * delta * 10.0)
	velocity.z = move_toward(velocity.z, wish_dir.z * spd, ctrl * delta * 10.0)

	_apply_slide()
	if _act_just("jump") and _jump_count < _max_jumps:
		if _jump_count == 0:
			velocity.y = jump_velocity
		else:
			velocity.y = jump_velocity * 0.85
			var flat := Vector3(velocity.x, 0, velocity.z)
			if flat.length_squared() > 0.01:
				velocity.x = flat.normalized().x * walk_speed * 1.6
				velocity.z = flat.normalized().z * walk_speed * 1.6
			if is_instance_valid(animation_tree):
				animation_tree.set(ANIM_JUMP, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_jump_count += 1
	var slide_key : bool = Input.is_key_pressed(KEY_CTRL) and _act("sprint")
	if slide_key and not _is_sliding and is_on_floor() and Vector2(velocity.x, velocity.z).length() > 1.0:
		_start_slide()
	if _is_sliding and not is_on_floor():
		_end_slide()


# ============================================================
# TOPDOWN MOVEMENT
# ============================================================
func _handle_topdown_movement(delta: float) -> void:
	if _dash_cd  > 0.0: _dash_cd  -= delta
	if _dash_active:
		_dash_timer -= delta
		if _dash_timer <= 0.0: _dash_active = false
		else:
			velocity.x = _dash_dir.x * dash_speed
			velocity.z = _dash_dir.z * dash_speed
			return

	var strafe := 0.0
	var fwd    := 0.0
	if device_id == -1:
		strafe = _act_strength("move_right") - _act_strength("move_left")
		fwd    = _act_strength("move_forward") - _act_strength("move_backward")
	else:
		strafe = _axis(JOY_AXIS_LEFT_X)
		fwd    = -_axis(JOY_AXIS_LEFT_Y)
	move_input = Vector2(strafe, fwd)
	wish_dir   = Vector3(strafe, 0.0, -fwd)
	if wish_dir.length_squared() > 0.01: wish_dir = wish_dir.normalized()

	if _act_just("dash") and _dash_cd <= 0.0 and wish_dir.length_squared() > 0.01:
		_dash_active = true; _dash_timer = dash_time
		_dash_cd = dash_cooldown; _dash_dir = wish_dir.normalized(); return

	var spd := sprint_speed if _act("sprint") else walk_speed
	spd += float(upgrades.get("move_speed", 0.0))
	if wish_dir.length_squared() > 0.01:
		velocity.x = lerp(velocity.x, wish_dir.x * spd, acceleration * delta)
		velocity.z = lerp(velocity.z, wish_dir.z * spd, acceleration * delta)
	else:
		velocity.x = lerp(velocity.x, 0.0, 18.0 * delta)
		velocity.z = lerp(velocity.z, 0.0, 18.0 * delta)
	if _act_just("jump") and _jump_count < _max_jumps:
		if _jump_count == 0:
			velocity.y = jump_velocity
		else:
			velocity.y = jump_velocity * 0.85
			var flat := Vector3(velocity.x, 0, velocity.z)
			if flat.length_squared() > 0.01:
				velocity.x = flat.normalized().x * walk_speed * 1.6
				velocity.z = flat.normalized().z * walk_speed * 1.6
			if is_instance_valid(animation_tree):
				animation_tree.set(ANIM_JUMP, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_jump_count += 1
	var slide_key : bool = Input.is_key_pressed(KEY_CTRL) and _act("sprint")
	if slide_key and not _is_sliding and is_on_floor() and Vector2(velocity.x, velocity.z).length() > 1.0:
		_start_slide()
	if _is_sliding and not is_on_floor():
		_end_slide()


# ============================================================
# TOPDOWN FACING
# ============================================================
func _face_cursor_topdown(delta: float) -> void:
	var target : Vector3
	if device_id >= 0:
		var aim_stick := Vector2(_axis(JOY_AXIS_RIGHT_X), _axis(JOY_AXIS_RIGHT_Y))
		if aim_stick.length() < 0.15: return
		var dir3 := Vector3(aim_stick.x, 0.0, aim_stick.y).normalized()
		aim_direction = dir3
		var target_angle := atan2(dir3.x, dir3.z)
		_td_aim_angle = lerp_angle(_td_aim_angle, target_angle, td_aim_smoothing * delta)
		rotation.y    = _td_aim_angle
		return
	else:
		var mpos   := get_viewport().get_mouse_position()
		var origin := td_camera.project_ray_origin(mpos)
		var ray_dir := td_camera.project_ray_normal(mpos)
		var plane  := Plane(Vector3.UP, global_position.y)
		var hit     = plane.intersects_ray(origin, ray_dir)
		if hit == null: return
		target = hit
	target.y = global_position.y
	var dir := target - global_position
	if dir.length_squared() < 0.001: return
	aim_direction = dir.normalized()
	var target_angle := atan2(dir.x, dir.z)
	_td_aim_angle = lerp_angle(_td_aim_angle, target_angle, td_aim_smoothing * delta)
	rotation.y    = _td_aim_angle


# ============================================================
# CAMERA FX
# ============================================================
func _handle_camera_fx(delta: float) -> void:
	var spd2d := Vector2(velocity.x, velocity.z).length()
	fps_pivot.rotation_degrees.x += recoil
	if spd2d > 0.5 and is_on_floor():
		headbob_timer += delta * headbob_speed
		var target_bob : float = sin(headbob_timer) * headbob_amount
		fps_camera.position.y = lerp(fps_camera.position.y, target_bob, 10.0 * delta)
	else:
		fps_camera.position.y = lerp(fps_camera.position.y, 0.0, 10.0 * delta)
	fps_camera.rotation_degrees.y = lerp(fps_camera.rotation_degrees.y,
		-smooth_mouse.x * 0.01 * sway_amount, sway_smoothing * delta)
	fps_camera.rotation_degrees.z = lerp(fps_camera.rotation_degrees.z,
		-move_input.x * tilt_amount, 6.0 * delta)

func _update_fov(delta: float) -> void:
	var target := 55.0 if _act("aim") else (85.0 if _act("sprint") else 75.0)
	fps_camera.fov = lerp(fps_camera.fov, target, delta * 10.0)


# ============================================================
# COMBAT
# ============================================================
func _combat() -> void:
	if not is_instance_valid(weapon_manager) or shop_open or _class_selecting or _deck_open: return
	var shooting := false
	if current_mode == CameraMode.TOPDOWN:
		if device_id == -1: shooting = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		else: shooting = _axis(JOY_AXIS_TRIGGER_RIGHT) > 0.3
	else:
		shooting = _act("shoot")
	if shooting and not _grappler_equipped and not is_instance_valid(_mounted_dragon):
		weapon_manager.try_shoot()
	elif not shooting:
		weapon_manager.stop_shoot()
	if _act_just("reload"):      weapon_manager.try_reload()
	if _act_just("next_weapon"): weapon_manager.switch_weapon(1)
	if _act_just("prev_weapon"): weapon_manager.switch_weapon(-1)

func apply_recoil(amount: float) -> void: recoil -= amount
func play_shoot_animation() -> void:
	if is_instance_valid(animation_tree):
		animation_tree.set(ANIM_SHOOT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


# ============================================================
# TOPDOWN / FPS MODE SWITCH
# ============================================================
func _get_transition_overlay() -> ColorRect:
	if not is_instance_valid(_transition_cl):
		_transition_cl = CanvasLayer.new()
		_transition_cl.layer = 128
		add_child(_transition_cl)
		_transition_rect = ColorRect.new()
		_transition_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_transition_rect.color = Color(0.0, 0.0, 0.0, 0.0)
		_transition_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_transition_cl.add_child(_transition_rect)
	return _transition_rect


func set_topdown_mode(enabled: bool) -> void:
	if _transitioning: return
	if not is_instance_valid(fps_camera):
		push_error("[Player] fps_camera is null"); return
	if not is_instance_valid(td_camera):
		push_error("[Player] td_camera is null"); return

	_transitioning = true
	var overlay := _get_transition_overlay()
	var tw := create_tween()
	tw.tween_property(overlay, "color", Color(0.0, 0.0, 0.0, 1.0), 0.12)
	tw.tween_callback(func(): _do_mode_switch(enabled))
	tw.tween_property(overlay, "color", Color(0.0, 0.0, 0.0, 0.0), 0.25)
	tw.tween_callback(func(): _transitioning = false)


func _do_mode_switch(enabled: bool) -> void:
	fps_pivot.rotation = Vector3.ZERO
	var ssm := get_tree().get_first_node_in_group("splitscreen_manager")

	if enabled:
		current_mode = CameraMode.TOPDOWN
		topdown_mode = true
		_fps_rotation_y_before_topdown   = rotation.y
		_fps_camera_basis_before_topdown = fps_camera.global_transform.basis
		if device_id == -1:
			var vp_center := get_viewport().get_visible_rect().size * 0.5
			get_viewport().warp_mouse(vp_center)
			cursor_pos = vp_center
		fps_camera.current = false
		td_camera.current  = true
		_force_viewport_camera(td_camera, ssm)
		for sl in find_children("*", "SpotLight3D", true, false):
			if is_instance_valid(sl): (sl as SpotLight3D).rotation_degrees.y = 180.0
		_td_zoom_base = topdown_height
		_td_zoom_time = 0.0
		var start_y : float = fps_camera.global_position.y
		td_pivot.global_position = Vector3(global_position.x, start_y, global_position.z)
		td_pivot.global_rotation = Vector3(deg_to_rad(topdown_angle), 0.0, 0.0)
		td_camera.rotation       = Vector3.ZERO
		td_pivot.global_position.y = global_position.y + topdown_height
		if is_instance_valid(weapon_manager):
			weapon_manager.visible = false
			if weapon_manager.has_method("update_camera"): weapon_manager.update_camera(td_camera)
		_set_body_visible(true)
		if device_id == -1:
			get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)
			Input.flush_buffered_events()
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_spawn_cursor()
		if is_instance_valid(_minimap): _minimap.show_for(self)
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("set_topdown_mode"): h.set_topdown_mode(true)
			elif "crosshair" in h and h.crosshair: h.crosshair.visible = false
		print("[Player] → TOPDOWN | fps.current=%s td.current=%s" % [fps_camera.current, td_camera.current])
	else:
		current_mode = CameraMode.FPS
		topdown_mode = false
		td_camera.current  = false
		fps_camera.current = true
		_force_viewport_camera(fps_camera, ssm)
		fps_pivot.rotation = Vector3.ZERO
		rotation.y = _fps_rotation_y_before_topdown
		for sl in find_children("*", "SpotLight3D", true, false):
			if is_instance_valid(sl): (sl as SpotLight3D).rotation_degrees.y = 0.0
		if is_instance_valid(fps_pivot):
			fps_pivot.position.y = eye_height
		if is_instance_valid(weapon_manager):
			weapon_manager.visible = true
			if weapon_manager.has_method("update_camera"):
				weapon_manager.update_camera(fps_camera)
			if weapon_manager.has_method("reequip_current"):
				weapon_manager.reequip_current()
		_set_body_visible(false)
		_destroy_cursor()
		if is_instance_valid(_minimap): _minimap.hide_map()
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("set_topdown_mode"): h.set_topdown_mode(false)
			elif "crosshair" in h and h.crosshair: h.crosshair.visible = true
		if device_id == -1 and not shop_open:
			get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)
			Input.flush_buffered_events()
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		print("[Player] → FPS | fps.current=%s td.current=%s" % [fps_camera.current, td_camera.current])


# ============================================================
# VIEWPORT CAMERA
# ============================================================
func _apply_dragon_zoom() -> void:
	if is_instance_valid(fps_camera): fps_camera.fov = _dragon_zoom

func _force_viewport_camera(cam: Camera3D, ssm: Node = null) -> void:
	if not is_instance_valid(cam): push_error("[Player] _force_viewport_camera: null cam"); return
	if is_instance_valid(ssm) and ssm.has_method("switch_player_camera"):
		ssm.switch_player_camera(self, cam); return
	var my_world := get_world_3d()
	for vp_node in _find_subviewports(get_tree().root):
		var vp := vp_node as SubViewport
		if not is_instance_valid(vp): continue
		if not vp.own_world_3d and vp.world_3d == my_world:
			RenderingServer.viewport_attach_camera(vp.get_viewport_rid(), cam.get_camera_rid()); return
	if get_tree().get_first_node_in_group("splitscreen_manager") == null:
		cam.make_current()
	else:
		push_warning("[Player] _force_viewport_camera: SSM present but switch failed for %s" % cam.name)

func _find_subviewports(node: Node) -> Array:
	var result : Array = []
	if node is SubViewport: result.append(node)
	for child in node.get_children():
		result.append_array(_find_subviewports(child))
	return result


# ============================================================
# SHOOT HELPERS
# ============================================================
var _crosshair_target : Vector3 = Vector3.ZERO
const _CROSSHAIR_RANGE : float  = 1000.0

func get_shoot_origin() -> Vector3:
	if current_mode == CameraMode.FPS: return fps_camera.global_position
	return global_position + Vector3.UP * 1.2

func get_shoot_direction() -> Vector3:
	if current_mode == CameraMode.FPS:
		var vp_center : Vector2 = get_viewport().get_visible_rect().size * 0.5
		var cam_pos   : Vector3 = fps_camera.project_ray_origin(vp_center)
		var cam_fwd   : Vector3 = fps_camera.project_ray_normal(vp_center)
		var space   := get_world_3d().direct_space_state
		var excl    : Array[RID] = []
		var pn      : Node = self
		while is_instance_valid(pn):
			if pn is CollisionObject3D: excl.append((pn as CollisionObject3D).get_rid())
			pn = pn.get_parent()
		var query := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_fwd * _CROSSHAIR_RANGE)
		query.collision_mask = 0xFFFFFFFF
		query.exclude        = excl
		var hit := space.intersect_ray(query)
		_crosshair_target = hit.position if not hit.is_empty() else cam_pos + cam_fwd * _CROSSHAIR_RANGE
		return _apply_aim_assist(cam_fwd)
	var dir : Vector3 = global_transform.basis.z
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		dir = Vector3(sin(_td_aim_angle), 0.0, cos(_td_aim_angle))
	return _apply_aim_assist(dir.normalized())


# ============================================================
# SHOP
# ============================================================
func bind_shop(shop_node: Control) -> void:
	shop = shop_node
	if is_instance_valid(shop) and shop.has_method("bind_player"):
		if not is_instance_valid(shop.get("player")):
			shop.bind_player(self)

func notify_shop_state(open: bool) -> void:
	shop_open = open
	for h in get_tree().get_nodes_in_group("hud"):
		var qp := h.get_node_or_null("QuestPanel") if is_instance_valid(h) else null
		if is_instance_valid(qp): qp.visible = not open
	if device_id == -1:
		if open or topdown_mode:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			if open and current_mode == CameraMode.TOPDOWN:
				var vp_center := get_viewport().get_visible_rect().size * 0.5
				get_viewport().warp_mouse(vp_center)
				cursor_pos = vp_center
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _handle_pause_or_escape() -> void:
	if shop_open: _cycle_tab(); return
	var pm : Node = null
	for _pm_name in ["PauseMenu", "pause_menu", "pausemenu", "Pausemenu", "PAUSEMENU"]:
		pm = get_node_or_null("/root/" + _pm_name)
		if is_instance_valid(pm): break
	if not is_instance_valid(pm):
		push_warning("[Player] PauseMenu not found"); return
	if pm.get("menu_visible") == true:
		if pm.has_method("hide_menu"): pm.hide_menu()
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if pm.has_method("show_menu"):
			pm.show_menu()
			print("[Player P%d] Pause menu opened" % player_id)

func _cycle_tab() -> void:
	_tab_state = (_tab_state + 1) % 3
	print("[Player P%d] _cycle_tab → state %d | mode=%s shop=%s" % [
		int(get("player_id") if "player_id" in self else 0),
		_tab_state, str(current_mode), str(shop_open)])
	match _tab_state:
		0:
			if shop_open: _close_shop()
			set_topdown_mode(false)
			if device_id == -1:
				Input.flush_buffered_events()
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		1:
			if current_mode == CameraMode.FPS: set_topdown_mode(true)
			call_deferred("_deferred_open_shop")
		2:
			if shop_open: _close_shop()
			if current_mode == CameraMode.FPS: set_topdown_mode(true)
			if device_id == -1: Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			if is_instance_valid(weapon_manager): weapon_manager.visible = false

func _deferred_open_shop() -> void:
	if shop_open: return
	if not is_instance_valid(shop): return
	if shop.has_method("open_shop"): shop.open_shop()
	elif shop.has_method("_open_shop"): shop.call("_open_shop")

func _toggle_shop() -> void:
	if is_instance_valid(shop) and shop.has_method("toggle_shop"): shop.toggle_shop()

func _close_shop() -> void:
	if is_instance_valid(shop) and shop.has_method("close_shop"): shop.close_shop()
	else: shop_open = false

func _play_shop_sound(opening: bool) -> void:
	var s := shop_open_sound if opening else shop_close_sound
	if is_instance_valid(s) and is_instance_valid(_sfx):
		_sfx.stream = s; _sfx.volume_db = linear_to_db(shop_sound_volume); _sfx.play()

func topdown_move(dir: Vector3, _delta: float) -> void:
	var spd := sprint_speed if _act("sprint") else walk_speed
	if dir.length_squared() > 0.01:
		velocity.x = dir.x * spd; velocity.z = dir.z * spd
	else:
		var dt := get_physics_process_delta_time()
		velocity.x = move_toward(velocity.x, 0.0, spd * dt * 10.0)
		velocity.z = move_toward(velocity.z, 0.0, spd * dt * 10.0)

func topdown_fire(dir: Vector3) -> void:
	aim_direction = dir
	if dir.length_squared() > 0.01:
		var flat := Vector3(dir.x, 0.0, dir.z).normalized()
		look_at(global_position + flat, Vector3.UP)
	if is_instance_valid(weapon_manager) and not _grappler_equipped and not is_instance_valid(_mounted_dragon):
		weapon_manager.try_shoot()

func is_panel_open() -> bool: return shop_open

func _is_wave_panel_open() -> bool:
	for h in get_tree().get_nodes_in_group("hud"):
		if "is_wave_open" in h and bool(h.get("is_wave_open")): return true
		var wp = h.get("_wave_choice_panel") if "_wave_choice_panel" in h else null
		if is_instance_valid(wp) and (wp as Control).visible: return true
	return false

func on_weapon_equipped(w: Node) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("_on_weapon_changed"):
			h._on_weapon_changed(w); break


# ============================================================
# DAMAGE / DEATH / RESPAWN
# ============================================================
func take_damage(amount: float, instigator: Node = null) -> void:
	var ss2 := get_tree().get_first_node_in_group("screen_shake")
	if is_instance_valid(ss2) and ss2.has_method("hit"): ss2.hit()
	var ie2 := get_tree().get_first_node_in_group("impact_effects")
	if is_instance_valid(ie2) and ie2.has_method("spawn_blood"):
		ie2.spawn_blood(global_position + Vector3.UP * 1.5, amount / 50.0)
	var mm2 := get_tree().get_first_node_in_group("music_manager")
	if is_instance_valid(mm2) and mm2.has_method("notify_combat"): mm2.notify_combat()
	if is_dead: return
	if instigator != null and "team_id" in instigator:
		if int(instigator.get("team_id")) == team_id: return
	if _shield_timer > 0.0: return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	_play_sound(hurt_sounds)
	var _ins_p = instigator
	var _dtype_p : int = 8
	if is_instance_valid(_ins_p):
		if not (_ins_p.is_in_group("zombies") or _ins_p.is_in_group("minions")): _dtype_p = 0
		if "enchantment" in _ins_p: _dtype_p = int(_ins_p.get("enchantment"))
	var _dn_node := get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(_dn_node) and _dn_node.has_method("spawn_number"):
		_dn_node.spawn_number(amount, global_position + Vector3(0, 2.2, 0), _dtype_p, false)
	if health <= 0.0: _die()

func _die() -> void:
	if is_dead: return
	var ss_d := get_tree().get_first_node_in_group("screen_shake")
	if is_instance_valid(ss_d) and ss_d.has_method("death_impulse"): ss_d.death_impulse()
	is_dead = true; velocity = Vector3.ZERO; died.emit()
	_play_sound(death_sounds)
	# ReviveManager handles respawn — if no revives, it triggers game over
	var rm := get_tree().get_first_node_in_group("revive_manager")
	if is_instance_valid(rm) and rm.has_method("on_player_died"):
		rm.on_player_died(self)
	else:
		await get_tree().create_timer(3.0).timeout; _respawn()

func _respawn() -> void:
	is_dead = false
	max_health = 100.0 + float(upgrades.get("max_health", 0.0))
	health     = max_health
	health_changed.emit(health, max_health)
	if is_instance_valid(weapon_manager):
		if weapon_manager.has_method("reset_to_base_stats"):
			weapon_manager.reset_to_base_stats()
	_rapid_fire_timer=0.0;_double_damage_timer=0.0;_shield_timer=0.0
	_ghost_timer=0.0;_sprint_boost_timer=0.0;_berserk_timer=0.0
	for b in get_tree().get_nodes_in_group("bases"):
		if "team_id" in b and int(b.get("team_id")) == team_id and b is Node3D:
			global_position = (b as Node3D).global_position + Vector3(0,1.5,0); break
	velocity = Vector3.ZERO
	_play_sound(respawn_sounds)
	respawned.emit()
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("play_respawn_glow"): h.play_respawn_glow()
	if not topdown_mode and device_id == -1:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ============================================================
# KILL CALLBACK — call this whenever this player lands a kill
# ============================================================
func on_kill(killed_node: Node = null) -> void:
	# Kill streak
	_kill_streak_count  += 1
	_kill_streak_timer   = KILL_STREAK_WINDOW
	_announce_streak()

	# Sword decay on sword kills, small recharge on gun kills
	if _is_sword_equipped():
		sword_charge = maxf(0.0, sword_charge - SWORD_DRAIN_PER_KILL)
		_update_sword_hud()
		if sword_charge <= 0.0:
			_show_message("⚔ Sword drained! Kill enemies with guns to recharge.", Color(1.0, 0.3, 0.1))
	else:
		# Gun kill recharges sword by 3 per kill
		sword_charge = minf(sword_charge + 3.0, sword_max_charge)
		_update_sword_hud()

	# Ult charge — per-class gain multiplier
	var _ult_kill_mult : float = CLASS_ULT_GAIN_MULT.get(player_class, 1.0)
	ult_charge = minf(ult_charge + ULT_CHARGE_PER_KILL * _ult_kill_mult, ult_charge_max)
	_update_ult_hud()

	# Class mastery
	if Engine.has_singleton("ClassMasteryManager"):
		Engine.get_singleton("ClassMasteryManager").call("register_kill", player_id, int(player_class))

	# Achievements
	if Engine.has_singleton("AchievementManager"):
		Engine.get_singleton("AchievementManager").call("on_kill", player_id, killed_node)


func on_damage_dealt(amount: float) -> void:
	var _ult_dmg_mult : float = CLASS_ULT_GAIN_MULT.get(player_class, 1.0)
	ult_charge = minf(ult_charge + amount * ULT_CHARGE_PER_DMG * _ult_dmg_mult, ult_charge_max)
	_update_ult_hud()


func _announce_streak() -> void:
	const STREAK_NAMES : Array = ["", "", "Double Kill!", "Triple Kill!", "Quad Kill!", "Rampage!", "Unstoppable!", "GODLIKE!"]
	if _kill_streak_count < 2: return
	var idx   : int    = mini(_kill_streak_count, STREAK_NAMES.size() - 1)
	var name  : String = STREAK_NAMES[idx]
	var col : Color = Color(1.0, 0.15, 0.1)
	match idx:
		2: col = Color(0.4, 0.9, 0.4)
		3: col = Color(0.9, 0.8, 0.1)
		4: col = Color(1.0, 0.55, 0.1)
	_hud_message(name, col)


func _my_hud() -> Node:
	# Return this player's own HUD — never broadcasts to other players' screens
	if is_instance_valid(hud): return hud
	# Fallback: find HUD that lives inside our SubViewport
	var vp := get_viewport()
	if is_instance_valid(vp):
		for h in get_tree().get_nodes_in_group("hud"):
			if is_instance_valid(h) and vp.is_ancestor_of(h):
				hud = h; return h
	return null


func _hud_message(text: String, color: Color = Color.WHITE) -> void:
	var h := _my_hud()
	if is_instance_valid(h) and h.has_method("show_message"): h.show_message(text, color)


func _update_sword_hud() -> void:
	var h := _my_hud()
	if is_instance_valid(h) and h.has_method("update_sword_charge"):
		h.update_sword_charge(sword_charge, sword_max_charge)


func _update_ult_hud() -> void:
	var h := _my_hud()
	if is_instance_valid(h) and h.has_method("update_ult_charge"):
		var ult_name : String = CLASS_ULT_NAMES.get(player_class, "ULTIMATE")
		h.update_ult_charge(ult_charge, ult_charge_max, ult_name)


func _try_fire_ult() -> void:
	if ult_charge < ult_charge_max:
		var pct := int(ult_charge / ult_charge_max * 100.0)
		_show_message("⚡ Ult not ready — %d%%" % pct, Color(0.6, 0.6, 0.7))
		return
	ult_charge = 0.0
	_update_ult_hud()
	_fire_ult_ability()


# ============================================================
# ULTIMATE ABILITIES — one per class, V key, kill-charged
# Each is intentionally overpowered (Overwatch ult tier)
# ============================================================
func _fire_ult_ability() -> void:
	var vfx := get_tree().get_first_node_in_group("vfx_manager")
	if is_instance_valid(vfx): vfx.level_up(global_position)
	else: _vfx_burst(global_position, Color(1.0, 0.9, 0.1), 40, 1.2)

	match player_class:

		PlayerClass.NECROMANCER:
			# DEATH RISES — raise every dead zombie on screen as a permanent thrall
			_show_message("☠ DEATH RISES — All fallen obey you!", Color(0.4, 1.0, 0.5))
			var raised := 0
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body): continue
				if body == self: continue
				var dead_val = body.get("is_dead")
				if dead_val is bool and dead_val:
					if "team_id" in body: body.set("team_id", team_id)
					body.set("is_dead", false)
					if "health" in body: body.set("health", float(body.get("max_health") if "max_health" in body else 80.0))
					body.set_physics_process(true)
					raised += 1
					_vfx_burst(body.global_position, Color(0.2, 1.0, 0.4), 8, 0.5)
			_show_message("☠ %d corpses raised!" % raised, Color(0.3, 1.0, 0.5))

		PlayerClass.BERSERKER:
			# WORLD BREAKER — shockwave kills everything in 18m, then 12s of 3× damage + infinite sprint
			_show_message("💥 WORLD BREAKER!", Color(1.0, 0.2, 0.1))
			_vfx_ring(global_position, Color(1.0, 0.3, 0.0), 18.0, 0.8)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				var d := global_position.distance_to(body.global_position)
				if d < 18.0 and body.has_method("take_damage"):
					body.take_damage(99999.0, self)
			_berserk_timer   = 12.0
			_sprint_boost_timer = 12.0
			upgrades["damage"] = upgrades.get("damage", 0.0) + 30.0
			get_tree().create_timer(12.0).timeout.connect(func(): upgrades["damage"] = maxf(0.0, upgrades.get("damage", 0.0) - 30.0))

		PlayerClass.PALADIN:
			# DIVINE WRATH — heal to full, 8s invincibility, holy nova kills all in 12m
			_show_message("✨ DIVINE WRATH — Blessed and Unstoppable!", Color(1.0, 1.0, 0.6))
			health = max_health
			health_changed.emit(health, max_health)
			_shield_timer = 8.0
			_vfx_ring(global_position, Color(1.0, 1.0, 0.4), 12.0, 1.0)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if global_position.distance_to(body.global_position) < 12.0 and body.has_method("take_damage"):
					body.take_damage(99999.0, self)

		PlayerClass.SHADOWBLADE:
			# SHADOW EXECUTION — teleport to up to 8 enemies and one-shot each
			_show_message("🗡 SHADOW EXECUTION — No escape!", Color(0.5, 0.1, 0.9))
			var targets : Array = []
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if "is_dead" in body and body.get("is_dead") is bool and body.get("is_dead"): continue
				targets.append(body)
			targets.sort_custom(func(a, b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
			var kill_count := mini(8, targets.size())
			for i in kill_count:
				var t : Node3D = targets[i] as Node3D
				if not is_instance_valid(t): continue
				var prev_pos := global_position
				global_position = t.global_position + Vector3(0.5, 0, 0.5)
				_vfx_burst(t.global_position, Color(0.5, 0.0, 1.0), 12, 0.4)
				t.take_damage(99999.0, self)
				await get_tree().create_timer(0.1).timeout
			_show_message("🗡 %d enemies executed!" % kill_count, Color(0.7, 0.3, 1.0))

		PlayerClass.STORMCALLER:
			# STORM SURGE — 6s lightning strikes hit every enemy on map every 0.5s
			_show_message("⚡ STORM SURGE — Lightning everywhere!", Color(0.4, 0.8, 1.0))
			var storm_ticks := 12
			for tick in storm_ticks:
				get_tree().create_timer(tick * 0.5).timeout.connect(func():
					for body in get_tree().get_nodes_in_group("units"):
						if not is_instance_valid(body) or body == self: continue
						if "team_id" in body and int(body.get("team_id")) == team_id: continue
						if "is_dead" in body and body.get("is_dead") is bool and body.get("is_dead"): continue
						if body.has_method("take_damage"): body.take_damage(45.0, self)
						_vfx_burst(body.global_position, Color(0.5, 0.9, 1.0), 4, 0.2))

		PlayerClass.BLOODMAGE:
			# BLOOD NOVA — consume 60% HP for a massive nova, then 15s lifesteal every hit
			var sacrifice := max_health * 0.6
			health = maxf(10.0, health - sacrifice)
			health_changed.emit(health, max_health)
			var nova_dmg := sacrifice * 8.0
			_show_message("🩸 BLOOD NOVA — %d damage!" % int(nova_dmg), Color(0.9, 0.1, 0.3))
			_vfx_ring(global_position, Color(1.0, 0.1, 0.3), 25.0, 1.2)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				var d := global_position.distance_to(body.global_position)
				if d < 25.0 and body.has_method("take_damage"):
					body.take_damage(nova_dmg * (1.0 - d / 25.0), self)
			_double_damage_timer = 15.0

		PlayerClass.TIMEWEAVER:
			# TIME STOP — freeze all enemies for 10s, player moves 2× faster
			_show_message("⏳ TIME STOP — The world stands still!", Color(0.6, 0.9, 1.0))
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				body.set_physics_process(false)
				body.set_process(false)
			_sprint_boost_timer = 10.0
			get_tree().create_timer(10.0).timeout.connect(func():
				for body in get_tree().get_nodes_in_group("units"):
					if is_instance_valid(body) and body != self:
						body.set_physics_process(true)
						body.set_process(true))
			_show_message("⏳ Time resumes in 10s…", Color(0.5, 0.8, 1.0))

		PlayerClass.VOIDWALKER:
			# VOID COLLAPSE — black hole pulls all enemies within 30m to your feet, then crushes them
			_show_message("🌀 VOID COLLAPSE — Nothing escapes!", Color(0.4, 0.1, 0.9))
			var pull_targets : Array = []
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if global_position.distance_to(body.global_position) < 30.0:
					pull_targets.append(body)
			# Pull phase
			for t in pull_targets:
				var tw2 := get_tree().create_tween()
				if t is Node3D:
					tw2.tween_property(t, "global_position", global_position + Vector3(randf_range(-1,1), 0, randf_range(-1,1)), 0.8)
			# Crush after pull
			get_tree().create_timer(0.9).timeout.connect(func():
				for t in pull_targets:
					if is_instance_valid(t) and t.has_method("take_damage"):
						t.take_damage(99999.0, self)
				_vfx_burst(global_position, Color(0.3, 0.0, 0.8), 60, 1.5))

		PlayerClass.IRONCLAD:
			# FORTRESS — 12s unkillable, auto-taunt all enemies toward you, reflect damage
			_show_message("🛡 FORTRESS — None shall pass!", Color(0.7, 0.8, 1.0))
			_shield_timer = 12.0
			health = max_health
			health_changed.emit(health, max_health)
			# Force all enemies to charge you
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if "enemy_base" in body: body.set("enemy_base", self)
			_vfx_ring(global_position, Color(0.7, 0.85, 1.0), 6.0, 1.5)

		PlayerClass.PLAGUEMASTER:
			# PANDEMIC — instant-infect every zombie on the map with lethal plague
			_show_message("☣ PANDEMIC — The plague spreads everywhere!", Color(0.2, 0.9, 0.3))
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if "is_dead" in body and body.get("is_dead") is bool and body.get("is_dead"): continue
				# Infect with heavy DoT
				body.set_meta("plague_ult_dot", 25.0)
				body.set_meta("plague_ult_timer", 12.0)
				_vfx_burst(body.global_position, Color(0.1, 0.9, 0.2), 6, 0.4)
			# Tick the plague DoT
			for _i in 24:
				get_tree().create_timer(_i * 0.5).timeout.connect(func():
					for body in get_tree().get_nodes_in_group("units"):
						if not is_instance_valid(body): continue
						if body.has_meta("plague_ult_dot") and body.has_method("take_damage"):
							body.take_damage(body.get_meta("plague_ult_dot"), self))

		PlayerClass.SOULREAPER:
			# HARVEST — instantly kill all enemies below 40% HP; each kill drops a soul explosion
			_show_message("💀 HARVEST — Reap what they sow!", Color(0.8, 0.3, 1.0))
			var reaped := 0
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if "health" in body and "max_health" in body:
					var ratio := float(body.get("health")) / maxf(float(body.get("max_health")), 1.0)
					if ratio <= 0.4 and body.has_method("take_damage"):
						body.take_damage(99999.0, self)
						_vfx_ring(body.global_position, Color(0.7, 0.1, 1.0), 3.0, 0.5)
						reaped += 1
			# Soul explosion: damage enemies near each harvested position
			_show_message("💀 %d souls harvested!" % reaped, Color(0.8, 0.4, 1.0))
			ult_charge = minf(float(reaped) * 5.0, ult_charge_max * 0.3)
			_update_ult_hud()

		PlayerClass.WARLOCK:
			# HELLGATE — summon 15 demon clones of yourself for 25s
			_show_message("🔥 HELLGATE — Demons, rise!", Color(1.0, 0.4, 0.1))
			if ResourceLoader.exists("res://zombie/zombie.tscn"):
				var packed : PackedScene = load("res://zombie/zombie.tscn")
				for i in 15:
					var demon := packed.instantiate()
					if "team_id"    in demon: demon.set("team_id", team_id)
					if "max_health" in demon: demon.set("max_health", 300.0)
					if "health"     in demon: demon.set("health",     300.0)
					if "damage"     in demon: demon.set("damage",     40.0)
					if "move_speed" in demon: demon.set("move_speed", 5.5)
					var dpos := global_position + Vector3(randf_range(-6.0, 6.0), 0.0, randf_range(-6.0, 6.0))
					var sp2 := get_tree().root.get_world_3d().direct_space_state
					if is_instance_valid(sp2):
						var ray2 := PhysicsRayQueryParameters3D.create(Vector3(dpos.x, 200.0, dpos.z), Vector3(dpos.x, -50.0, dpos.z))
						ray2.collision_mask = 1
						var hit2 := sp2.intersect_ray(ray2)
						if not hit2.is_empty(): dpos.y = hit2.position.y + 0.5
					demon.add_to_group("ult_summon")
					get_tree().current_scene.add_child(demon)
					demon.global_position = dpos
					_vfx_burst(demon.global_position, Color(1.0, 0.3, 0.0), 10, 0.5)
				get_tree().create_timer(25.0).timeout.connect(func():
					for d in get_tree().get_nodes_in_group("ult_summon"):
						if is_instance_valid(d): d.queue_free())

		PlayerClass.PHOENIX:
			# SUPERNOVA — massive 35m explosion, then instantly revive with full HP
			_show_message("🔥 SUPERNOVA — BURN!", Color(1.0, 0.5, 0.1))
			_vfx_ring(global_position, Color(1.0, 0.55, 0.1), 35.0, 1.5)
			_vfx_burst(global_position, Color(1.0, 0.7, 0.1), 80, 2.0)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				var d := global_position.distance_to(body.global_position)
				if d < 35.0 and body.has_method("take_damage"):
					body.take_damage(99999.0 * (1.0 - d / 35.0), self)
			# Revive with full HP
			health = max_health
			health_changed.emit(health, max_health)
			_shield_timer = 5.0

		PlayerClass.GRAVEMIND:
			# MIND CONTROL — hijack all enemies within 35m for 20s; they fight for you
			_show_message("🧠 MIND CONTROL — You are MINE!", Color(0.3, 0.9, 0.5))
			var hijacked : Array = []
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if global_position.distance_to(body.global_position) < 35.0:
					body.set("team_id", team_id)
					hijacked.append(body)
					_vfx_burst(body.global_position, Color(0.2, 1.0, 0.5), 8, 0.5)
			get_tree().create_timer(20.0).timeout.connect(func():
				for b in hijacked:
					if is_instance_valid(b): b.set("team_id", 2))
			_show_message("🧠 %d enemies mind-controlled for 20s!" % hijacked.size(), Color(0.3, 1.0, 0.6))

		PlayerClass.DOOMSLAYER:
			# RECKONING — 15s godmode: every melee swing creates a 10m explosion
			_show_message("💀 RECKONING — DOOM HAS COME!", Color(0.9, 0.1, 0.1))
			_shield_timer    = 15.0
			_berserk_timer   = 15.0
			_sprint_boost_timer = 15.0
			health = max_health
			health_changed.emit(health, max_health)
			# Every half-second during reckoning, explosion at player position
			for tick in 30:
				get_tree().create_timer(tick * 0.5).timeout.connect(func():
					_vfx_ring(global_position, Color(1.0, 0.1, 0.0), 10.0, 0.3)
					for body in get_tree().get_nodes_in_group("units"):
						if not is_instance_valid(body) or body == self: continue
						if "team_id" in body and int(body.get("team_id")) == team_id: continue
						if global_position.distance_to(body.global_position) < 10.0:
							if body.has_method("take_damage"): body.take_damage(200.0, self))

		_:
			# Generic fallback ult — massive AoE nuke
			_show_message("⚡ ULTIMATE UNLEASHED!", Color(1.0, 0.85, 0.1))
			_vfx_ring(global_position, Color(1.0, 0.8, 0.1), 20.0, 1.0)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if global_position.distance_to(body.global_position) < 20.0 and body.has_method("take_damage"):
					body.take_damage(500.0, self)


func _throw_grenade(flame: bool) -> void:
	if flame:
		if _flame_cd > 0.0:
			_show_message("🔥 Flame grenade: %.1fs" % _flame_cd, Color(0.7, 0.4, 0.1)); return
		if flame_grenades <= 0:
			_show_message("🔥 No flame grenades!", Color(0.9, 0.4, 0.1)); return
		flame_grenades -= 1
		_flame_cd = FLAME_COOLDOWN
		_do_flame_grenade()
	else:
		if _frag_cd > 0.0:
			_show_message("💥 Frag grenade: %.1fs" % _frag_cd, Color(0.7, 0.7, 0.2)); return
		if frag_grenades <= 0:
			_show_message("💥 No frag grenades!", Color(0.9, 0.8, 0.1)); return
		frag_grenades -= 1
		_frag_cd = FRAG_COOLDOWN
		_do_frag_grenade()


func _do_frag_grenade() -> void:
	# Arc throw toward camera aim, explode on impact or after 2.5s
	var throw_pos := global_position + Vector3.UP * 1.4
	var throw_dir := -get_viewport().get_camera_3d().global_transform.basis.z if is_instance_valid(get_viewport().get_camera_3d()) else -global_transform.basis.z
	_show_message("💥 Frag! [%d left]" % frag_grenades, Color(1.0, 0.9, 0.3))
	_vfx_burst(throw_pos, Color(0.9, 0.8, 0.2), 6, 0.3)
	# Simulate travel and explode at aimed position
	var explode_pos := throw_pos + throw_dir * 18.0
	var space := get_tree().root.get_world_3d().direct_space_state
	if is_instance_valid(space):
		var ray := PhysicsRayQueryParameters3D.create(throw_pos, throw_pos + throw_dir * 25.0)
		ray.collision_mask = 1
		var hit := space.intersect_ray(ray)
		if not hit.is_empty(): explode_pos = hit.position
	get_tree().create_timer(0.5).timeout.connect(func(): _explode_at(explode_pos, FRAG_RADIUS, FRAG_DAMAGE, Color(1.0, 0.8, 0.2)))


func _do_flame_grenade() -> void:
	var throw_pos := global_position + Vector3.UP * 1.4
	var throw_dir := -get_viewport().get_camera_3d().global_transform.basis.z if is_instance_valid(get_viewport().get_camera_3d()) else -global_transform.basis.z
	_show_message("🔥 Flame grenade! [%d left]" % flame_grenades, Color(1.0, 0.45, 0.1))
	_vfx_burst(throw_pos, Color(1.0, 0.4, 0.0), 6, 0.3)
	var explode_pos := throw_pos + throw_dir * 16.0
	var space := get_tree().root.get_world_3d().direct_space_state
	if is_instance_valid(space):
		var ray := PhysicsRayQueryParameters3D.create(throw_pos, throw_pos + throw_dir * 22.0)
		ray.collision_mask = 1
		var hit := space.intersect_ray(ray)
		if not hit.is_empty(): explode_pos = hit.position
	get_tree().create_timer(0.5).timeout.connect(func(): _flame_pool_at(explode_pos))


func _explode_at(pos: Vector3, radius: float, damage: float, col: Color) -> void:
	var vfx := get_tree().get_first_node_in_group("vfx_manager")
	if is_instance_valid(vfx): vfx.explosion(pos, radius / 8.0, col)
	else: _vfx_ring(pos, col, radius, 0.6); _vfx_burst(pos, col, 30, 0.8)
	for body in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(body) or body == self: continue
		if "team_id" in body and int(body.get("team_id")) == team_id: continue
		if body is Node3D:
			var d := pos.distance_to((body as Node3D).global_position)
			if d < radius and body.has_method("take_damage"):
				body.take_damage(damage * (1.0 - d / radius), self)


func _flame_pool_at(pos: Vector3) -> void:
	var vfx := get_tree().get_first_node_in_group("vfx_manager")
	if is_instance_valid(vfx): vfx.explosion(pos, 1.2, Color(1.0, 0.35, 0.05))
	else: _vfx_burst(pos, Color(1.0, 0.4, 0.0), 20, 0.5)
	# Damage in area repeatedly for FLAME_DURATION seconds
	var ticks := int(FLAME_DURATION / 0.5)
	for i in ticks:
		get_tree().create_timer(i * 0.5).timeout.connect(func():
			_vfx_burst(pos, Color(1.0, 0.35, 0.0), 5, 0.25)
			for body in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(body) or body == self: continue
				if "team_id" in body and int(body.get("team_id")) == team_id: continue
				if body is Node3D:
					var d := pos.distance_to((body as Node3D).global_position)
					if d < FLAME_RADIUS and body.has_method("take_damage"):
						body.take_damage(FLAME_DAMAGE * 0.5, self))


func _deploy_purifier() -> void:
	if _purifier_cd > 0.0:
		_show_message("⬟ Purifier: %.0fs" % _purifier_cd, Color(0.4, 0.7, 1.0)); return
	var cm := get_tree().get_first_node_in_group("corruption_manager")
	if not is_instance_valid(cm):
		_show_message("No corruption zones active.", Color(0.6, 0.6, 0.6)); return
	var deploy_pos := global_position
	# Place slightly in front of player
	deploy_pos += -global_transform.basis.z * 2.0
	deploy_pos.y = global_position.y
	cm.deploy_beacon(deploy_pos)
	_purifier_cd = PURIFIER_COOLDOWN


func recharge_sword(amount: float) -> void:
	sword_charge = minf(sword_charge + amount, sword_max_charge)
	_update_sword_hud()
	_hud_message("⚔ Sword recharged!", Color(0.4, 1.0, 0.5))


# ── Tick meta systems each frame ─────────────────────────────
func _tick_meta_systems(delta: float) -> void:
	# Kill streak timer
	if _kill_streak_timer > 0.0:
		_kill_streak_timer -= delta
		if _kill_streak_timer <= 0.0:
			_kill_streak_count = 0

	# Class lock countdown
	if _class_lock_timer > 0.0:
		_class_lock_timer = maxf(0.0, _class_lock_timer - delta)

	# Grenade + purifier cooldowns
	if _frag_cd      > 0.0: _frag_cd      = maxf(0.0, _frag_cd      - delta)
	if _flame_cd     > 0.0: _flame_cd     = maxf(0.0, _flame_cd     - delta)
	if _purifier_cd  > 0.0: _purifier_cd  = maxf(0.0, _purifier_cd  - delta)

	# Synergy window
	if _synergy_active:
		_synergy_timer -= delta
		if _synergy_timer <= 0.0:
			_synergy_active = false

	# Corruption slow (from CorruptionManager via gas clouds or zones)
	var slow : float = 0.0
	for area in get_tree().get_nodes_in_group("gas_cloud"):
		if area is Area3D and (area as Area3D).overlaps_body(self):
			slow = maxf(slow, float(area.get_meta("slow_factor", 0.0)))
	_corruption_slow = slow


var _corruption_slow : float = 0.0


# ============================================================
# UPGRADES
# ============================================================
func apply_upgrade(stat: String, amount: float) -> void:
	if not upgrades.has(stat): upgrades[stat] = 0.0
	upgrades[stat] += amount
	if stat == "max_health":
		max_health += amount; health = minf(health + amount, max_health)
		health_changed.emit(health, max_health); return
	_try_apply_wm_upgrade(stat, amount)

func _try_apply_wm_upgrade(stat: String, amount: float) -> void:
	if not is_instance_valid(weapon_manager): return
	if not weapon_manager.has_method("apply_player_upgrade"):
		for path in ["res://scripts/WeaponManager.gd","res://WeaponManager.gd",
					 "res://scenes/WeaponManager.gd","res://weapons/WeaponManager.gd"]:
			if ResourceLoader.exists(path):
				var scr : Script = load(path)
				if is_instance_valid(scr):
					weapon_manager.set_script(scr)
					if weapon_manager.has_method("bind_player"):
						weapon_manager.bind_player(self, fps_camera)
					break
	if weapon_manager.has_method("apply_player_upgrade"):
		weapon_manager.apply_player_upgrade(stat, amount)


# ============================================================
# ABILITIES
# ============================================================
func equip_ability(slot: int, data: Dictionary) -> void:
	if slot < 0 or slot >= 1: return
	ability_slots[slot] = data if not data.is_empty() else null
	ability_cooldowns[slot] = 0.0
	abilities_changed.emit()

func enter_grav_lift(exit_y: float, speed: float) -> void:
	_on_grav_lift = true; _grav_lift_exit_y = exit_y; _grav_lift_speed = speed

func exit_grav_lift() -> void: _on_grav_lift = false

func enter_ladder(top_y: float) -> void:
	_on_ladder = true; _ladder_top_y = top_y; velocity.y = 0.0

func exit_ladder() -> void: _on_ladder = false

func cancel_invisibility() -> void:
	if _ghost_timer > 0.0:
		_ghost_timer = 0.0; _set_player_alpha(1.0)

var _last_shown_weapon : Node = null
func _update_weapon_transform() -> void:
	pass  # WeaponManager._process() handles weapon positioning

func _set_player_alpha(alpha: float) -> void:
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := mi as MeshInstance3D
		if not is_instance_valid(mesh_inst.mesh): continue
		var surf_count : int = mesh_inst.get_surface_override_material_count()
		for i in surf_count:
			var mat := mesh_inst.get_surface_override_material(i)
			if not is_instance_valid(mat):
				var base_mat := mesh_inst.mesh.surface_get_material(i)
				if not is_instance_valid(base_mat): continue
				mat = base_mat.duplicate()
				mesh_inst.set_surface_override_material(i, mat)
			if mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var col := bm.albedo_color; col.a = alpha; bm.albedo_color = col

func activate_ability(slot: int) -> void:
	if slot < 0 or slot >= 1: return
	var data = ability_slots[slot]
	if data == null or ability_cooldowns[slot] > 0.0: return
	ability_cooldowns[slot] = float(data.get("cooldown", 10.0))
	_trigger_ability(data); abilities_changed.emit()
	var dur : float = float(data.get("duration", 0.0))
	var name_str : String = str(data.get("name", "Ability"))
	var desc_str : String = str(data.get("desc", ""))
	if dur > 0.0: _show_message("✦ %s — %.0fs  %s" % [name_str, dur, desc_str], Color(0.3, 0.95, 1.0))
	else: _show_message("✦ %s  %s" % [name_str, desc_str], Color(0.3, 0.95, 1.0))
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("flash_ability"): h.flash_ability(slot)

func on_trinket_pickup(data: Dictionary, slot: int) -> void:
	equip_ability(slot, data)

func _tick_ability_cooldowns(delta: float) -> void:
	for i in ability_cooldowns.size():
		if ability_cooldowns[i] > 0.0:
			ability_cooldowns[i] = maxf(0.0, ability_cooldowns[i] - delta)
			if ability_cooldowns[i] == 0.0: abilities_changed.emit()

func _tick_ability_effects(delta: float) -> void:
	_rapid_fire_timer    = maxf(0.0, _rapid_fire_timer    - delta)
	_double_damage_timer = maxf(0.0, _double_damage_timer - delta)
	_shield_timer        = maxf(0.0, _shield_timer        - delta)
	_berserk_timer       = maxf(0.0, _berserk_timer       - delta)
	_sprint_boost_timer  = maxf(0.0, _sprint_boost_timer  - delta)
	if _ghost_timer > 0.0:
		_ghost_timer = maxf(0.0, _ghost_timer - delta)
		var alpha : float = 0.18 if _ghost_timer > 0.5 else lerpf(0.18, 1.0, 1.0 - _ghost_timer / 0.5)
		_set_player_alpha(alpha)
	else:
		_set_player_alpha(1.0)

func is_rapid_fire()    -> bool: return _rapid_fire_timer    > 0.0
func is_double_damage() -> bool: return _double_damage_timer > 0.0 or _berserk_timer > 0.0
func is_shielded()      -> bool: return _shield_timer        > 0.0

func get_damage_multiplier() -> float:
	var base : float = 2.0 if is_double_damage() else 1.0
	var flat_bonus : float = float(upgrades.get("damage", 0.0))
	const BASE_WEAPON_DMG : float = 25.0
	return base * ((BASE_WEAPON_DMG + flat_bonus) / BASE_WEAPON_DMG)

func get_fire_rate_multiplier() -> float:
	var m := 1.0
	if is_rapid_fire():      m *= 2.5
	if _berserk_timer > 0.0: m *= 1.8
	return m

func _trigger_ability(data: Dictionary) -> void:
	var id   : String = str(data.get("id", ""))
	var dur  : float  = data.get("duration", 0.0)
	var amt  : float  = data.get("amount",   0.0)
	var dist : float  = data.get("distance", 8.0)
	match id:
		"rapid_fire","frenzy","fire_weapon","frost_weapon","shock_weapon":
			_rapid_fire_timer = dur
		"double_damage","death_mark","crit_strike","execute","berserker":
			if id == "berserker": _berserk_timer = dur
			else: _double_damage_timer = dur
		"void_shield","iron_skin","stone_skin","reflect","frost_armor","evasion","second_wind","cleanse":
			_shield_timer = dur
		"camouflage","phase_shift":
			_ghost_timer = dur
		"regen_aura","overclock","sprint","wind_walk","haste":
			_sprint_boost_timer = dur
			if id == "haste": _rapid_fire_timer = dur
		"blood_rite","soul_drain","energy_shield":
			health = minf(health + amt, max_health + (amt if id=="energy_shield" else 0.0))
			health_changed.emit(health, max_health)
		"void_dash","shadow_step","blink":
			var d := Vector3(velocity.x,0,velocity.z).normalized()
			if d.length_squared() < 0.1: d = -global_transform.basis.z
			global_position += d * dist
		"recall":
			get_tree().create_timer(3.0).timeout.connect(func():
				for b in get_tree().get_nodes_in_group("bases"):
					if "team_id" in b and int(b.get("team_id"))==team_id and b is Node3D:
						global_position=(b as Node3D).global_position+Vector3(0,1.5,0);break)
	abilities_changed.emit()


# ============================================================
# AUDIO
# ============================================================
func _play_sound(sounds: Array[AudioStream]) -> void:
	if sounds.is_empty() or not is_instance_valid(_sfx): return
	_sfx.stream = sounds[randi() % sounds.size()]
	_sfx.pitch_scale = randf_range(0.92, 1.08)
	_sfx.play()

# Returns "concrete", "dirt", or "" by casting a short ray downward and
# reading the "surface_tag" metadata on whatever the player is standing on.
# To tag a floor in the editor: select the StaticBody3D → Add Metadata →
# key: "surface_tag"  type: String  value: "concrete" or "dirt".
func _detect_floor_surface() -> String:
	var space : PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.from    = global_position + Vector3.UP * 0.1
	params.to      = global_position + Vector3.DOWN * 0.5
	params.exclude = [get_rid()]
	var result : Dictionary = space.intersect_ray(params)
	if result.is_empty(): return ""
	var collider = result["collider"]   # Variant — intentionally untyped
	if not is_instance_valid(collider): return ""
	if collider.has_meta("surface_tag"):
		return str(collider.get_meta("surface_tag"))
	return ""

# Picks the surface-specific pool if populated; falls back to generic pool.
func _get_footstep_pool() -> Array[AudioStream]:
	var tag : String = _detect_floor_surface()
	match tag:
		"concrete":
			if not footstep_sounds_concrete.is_empty():
				return footstep_sounds_concrete
		"dirt":
			if not footstep_sounds_dirt.is_empty():
				return footstep_sounds_dirt
	return footstep_sounds

func _update_footsteps(delta: float) -> void:
	var flat : float = Vector2(velocity.x, velocity.z).length()
	var moving : bool = is_on_floor() and flat > 0.5
	if not moving:
		_foot_timer = 0.0
		if is_instance_valid(_footstep) and _footstep.playing:
			var tw := create_tween()
			tw.tween_property(_footstep, "volume_db", -80.0, 0.08)
			tw.tween_callback(_footstep.stop)
			tw.tween_callback(func(): _footstep.volume_db = 0.0)
		return
	_foot_timer -= delta
	if _foot_timer <= 0.0:
		var pool : Array[AudioStream] = _get_footstep_pool()
		if not pool.is_empty():
			_footstep.stream      = pool.pick_random()
			_footstep.pitch_scale = randf_range(0.93, 1.07)
			_footstep.volume_db   = 0.0
			_footstep.play()
		_foot_timer = 0.25 if _act("sprint") else 0.42

func _init_td_camera_look() -> void:
	if is_instance_valid(td_camera) and is_instance_valid(td_pivot):
		var cam_pos := global_position + Vector3(0.0, topdown_height, 0.0)
		td_camera.global_position = cam_pos
		td_camera.look_at(global_position + Vector3(0.0, 0.8, 0.0), Vector3.FORWARD)
		td_pivot.global_position = cam_pos


# ============================================================
# CURSOR
# ============================================================
func _update_cursor() -> void:
	cursor_pos = get_viewport().get_mouse_position()
	if is_instance_valid(cursor_node):
		var h := cursor_node.get_node_or_null("H") as ColorRect
		var v := cursor_node.get_node_or_null("V") as ColorRect
		if h: h.position = cursor_pos - Vector2(10, 1)
		if v: v.position = cursor_pos - Vector2(1, 10)

func _spawn_cursor() -> void:
	_destroy_cursor()
	cursor_node = Control.new()
	cursor_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	cursor_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := ColorRect.new(); h.name = "H"
	h.color = Color(1, 0.1, 0.1); h.custom_minimum_size = Vector2(20, 2)
	var v := ColorRect.new(); v.name = "V"
	v.color = Color(1, 0.1, 0.1); v.custom_minimum_size = Vector2(2, 20)
	cursor_node.add_child(h); cursor_node.add_child(v)
	get_viewport().add_child(cursor_node)

func _destroy_cursor() -> void:
	if is_instance_valid(cursor_node): cursor_node.queue_free()
	cursor_node = null

func _get_cursor_world_pos() -> Vector3:
	var mpos   := get_viewport().get_mouse_position()
	var origin := td_camera.project_ray_origin(mpos)
	var dir    := td_camera.project_ray_normal(mpos)
	var plane  := Plane(Vector3.UP, global_position.y)
	var hit     = plane.intersects_ray(origin, dir)
	return hit if hit != null else global_position + (-global_transform.basis.z * 5.0)


# ============================================================
# DYNAMIC ZOOM
# ============================================================
func _update_dynamic_zoom(delta: float) -> void:
	var combat_score := 0.0
	combat_score += velocity.length() * 0.04
	for z in get_tree().get_nodes_in_group("minions"):
		if not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		var dist : float = global_position.distance_to((z as Node3D).global_position)
		if dist < td_enemy_scan_radius:
			combat_score += (1.0 - (dist / td_enemy_scan_radius)) * 0.3
	combat_score = clamp(combat_score, 0.0, 1.0)
	var target_zoom : float = lerp(td_zoom_min, td_zoom_max, combat_score)
	_combat_zoom = lerp(_combat_zoom, target_zoom, td_zoom_speed * delta)
	var cam_pos := global_position + Vector3(0.0, _combat_zoom, 0.0)
	td_camera.global_position = cam_pos
	td_camera.look_at(global_position + Vector3(0.0, 0.8, 0.0), Vector3.FORWARD)
	td_pivot.global_position  = cam_pos


# ============================================================
# AIM ASSIST
# ============================================================
func _apply_aim_assist(dir: Vector3) -> Vector3:
	if current_mode == CameraMode.FPS:
		var best_t : Node3D = null; var best_s : float = INF
		for z in get_tree().get_nodes_in_group("minions"):
			if not (z is Node3D): continue
			if "team_id" in z and int(z.get("team_id")) == team_id: continue
			var to_e : Vector3 = (z as Node3D).global_position - global_position
			if to_e.length() > 20.0: continue
			var score : float = dir.distance_to(to_e.normalized())
			if score < best_s: best_s = score; best_t = z as Node3D
		if not is_instance_valid(best_t): return dir
		return dir.lerp((best_t.global_position - global_position).normalized(), aim_assist_strength).normalized()

	var view_dist  : float  = topdown_height * 1.4
	var candidates : Array  = []
	for group in ["minions", "units"]:
		for z in get_tree().get_nodes_in_group(group):
			if not (z is Node3D): continue
			if "team_id" in z and int(z.get("team_id")) == team_id: continue
			if z.has_method("is_dead") and z.is_dead(): continue
			if global_position.distance_to((z as Node3D).global_position) > view_dist: continue
			candidates.append(z)
	if candidates.is_empty(): return dir

	var best_target : Node3D = null
	var best_score  : float  = -INF
	for z in candidates:
		var to_e  : Vector3 = (z as Node3D).global_position - global_position
		var flat  : Vector3 = Vector3(to_e.x, 0.0, to_e.z)
		if flat.length_squared() < 0.01: continue
		var dot   : float = dir.dot(flat.normalized())
		var dist  : float = flat.length()
		var score : float = dot * 2.0 + (1.0 - clampf(dist / view_dist, 0.0, 1.0))
		if score > best_score: best_score = score; best_target = z as Node3D
	if not is_instance_valid(best_target) or best_score < 0.3: return dir
	var snap_dir : Vector3 = best_target.global_position - global_position
	snap_dir.y = 0.0
	if snap_dir.length_squared() < 0.01: return dir
	return dir.lerp(snap_dir.normalized(), 0.85).normalized()

func get_magnetized_direction(dir: Vector3) -> Vector3:
	var best_target : Node3D = null
	var best_dot    : float  = 0.92
	for z in get_tree().get_nodes_in_group("minions"):
		if not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		var to_enemy : Vector3 = ((z as Node3D).global_position - global_position).normalized()
		var dot : float = dir.dot(to_enemy)
		if dot > best_dot: best_dot = dot; best_target = z as Node3D
	if not is_instance_valid(best_target): return dir
	return dir.lerp((best_target.global_position - global_position).normalized(), bullet_magnetism).normalized()


# ============================================================
# CRYSTALS / ENCHANTS
# ============================================================
func add_crystal(amount: int = 1) -> void:
	crystals += amount; crystals_changed.emit(crystals)
	var _rsm_ac := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(_rsm_ac): _rsm_ac.set_player_crystals(player_id, crystals)

func get_enchant_mult(enchant_type: int) -> float:
	if enchant_type <= 0 or enchant_type >= enchant_damage_mult.size(): return 1.0
	return enchant_damage_mult[enchant_type]

func upgrade_enchant(enchant_type: int, amount: float) -> void:
	if enchant_type <= 0 or enchant_type >= enchant_damage_mult.size(): return
	enchant_damage_mult[enchant_type] += amount
	_show_message("✦ %s +%.0f%% damage" % [_enchant_name(enchant_type), amount * 100.0])

func _enchant_name(t: int) -> String:
	var names := ["None","Fire","Ice","Poison","Electric","Shadow","Vampiric"]
	return names[clampi(t, 0, names.size()-1)]

func spend_crystals(amount: int) -> bool:
	if crystals < amount: return false
	crystals -= amount; crystals_changed.emit(crystals)
	var _rsm_sc := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(_rsm_sc): _rsm_sc.set_player_crystals(player_id, crystals)
	return true

func _enchant_nearby_zombies() -> void:
	var enchant_type : int = 0
	if is_instance_valid(weapon_manager):
		var wep : Node = weapon_manager.get_current_weapon()
		if is_instance_valid(wep) and "enchantment" in wep:
			enchant_type = int(wep.get("enchantment"))
	if enchant_type == 0:
		_show_message("Equip sword with enchantment first (R to cycle)"); return
	var enchant_names  := ["None","Fire","Ice","Poison","Electric","Shadow","Vampiric"]
	var enchant_colors := [Color.WHITE, Color(1,0.3,0), Color(0.3,0.8,1), Color(0.2,0.9,0.1),
		Color(1,0.95,0.1), Color(0.5,0,0.8), Color(0.8,0,0.2)]
	var count      := 0
	var already_hit: Array = []
	for grp in ["zombies", "minions", "units"]:
		for m in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(m) or already_hit.has(m): continue
			if not (m is Node3D): continue
			if "team_id" in m and int(m.get("team_id")) != team_id: continue
			if m.has_method("is_dead") and m.is_dead(): continue
			if global_position.distance_to((m as Node3D).global_position) > 12.0: continue
			if not m.is_in_group("zombies") and not m.is_in_group("minions"): continue
			already_hit.append(m)
			if m.has_method("receive_energy"): m.receive_energy(8.0)
			m.set_meta("enchantment", enchant_type)
			if m.has_method("apply_enchant_aura"): m.apply_enchant_aura(enchant_type)
			_apply_enchant_aura_to_node(m, enchant_type, enchant_colors[enchant_type])
			count += 1
	if count > 0: _show_message("✦ %d zombies enchanted with %s!" % [count, enchant_names[enchant_type]])
	else: _show_message("No friendly zombies nearby (range: 12m)")

func _apply_enchant_aura_to_node(target: Node, enchant_type: int, col: Color) -> void:
	if not (target is Node3D): return
	for child in target.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			var orig := mi.get_active_material(s)
			if not (orig is StandardMaterial3D): continue
			var glow := (orig as StandardMaterial3D).duplicate() as StandardMaterial3D
			glow.emission_enabled = true; glow.emission = col
			glow.emission_energy_multiplier = 2.5
			mi.set_surface_override_material(s, glow)


# ============================================================
# SLIDE
# ============================================================
func _start_slide() -> void:
	_is_sliding = true; _slide_timer = SLIDE_DURATION
	var flat := Vector3(velocity.x, 0, velocity.z)
	_slide_dir = flat.normalized() if flat.length_squared() > 0.01 else -global_transform.basis.z
	if is_instance_valid(fps_pivot): fps_pivot.position.y = eye_height - 0.2

func _end_slide() -> void:
	if not _is_sliding: return
	_is_sliding = false; _slide_dir = Vector3.ZERO; _slide_timer = 0.0
	if is_instance_valid(fps_pivot):
		var tw := create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(fps_pivot, "position:y", eye_height, 0.15)

func _apply_slide() -> void:
	if not _is_sliding: return
	var spd : float = SLIDE_SPEED * maxf(_slide_timer / SLIDE_DURATION, 0.0)
	velocity.x = _slide_dir.x * spd; velocity.z = _slide_dir.z * spd
	if is_on_floor() and velocity.y < 0.0: velocity.y = 0.0


# ============================================================
# CREEP SPAWNING
# ============================================================
func spawn_creep_at_base(scene: PackedScene, kind: String) -> Node:
	if not is_instance_valid(scene): return null
	var base_pos := Vector3.ZERO
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and "team_id" in b and int(b.get("team_id")) == team_id:
			base_pos = (b as Node3D).global_position; break
	if base_pos == Vector3.ZERO: push_warning("[Player] No base for team %d" % team_id); return null
	var creep : Node = scene.instantiate()
	get_tree().current_scene.add_child(creep)
	var space := get_world_3d().direct_space_state
	var offset := Vector3(randf_range(-3,3), 0, randf_range(-3,3))
	var ray := PhysicsRayQueryParameters3D.create(base_pos + offset + Vector3(0,5,0), base_pos + offset + Vector3(0,-10,0))
	ray.collision_mask = 1
	var hit := space.intersect_ray(ray)
	var spawn_pos : Vector3 = hit.position + Vector3(0,0.2,0) if not hit.is_empty() else base_pos + offset + Vector3(0,1,0)
	if creep is Node3D: (creep as Node3D).global_position = spawn_pos
	if "team_id"  in creep: creep.set("team_id",  team_id)
	if "owner_id" in creep: creep.set("owner_id", get_instance_id())
	var enemy_tid : int = 2 if team_id == 1 else 1
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == enemy_tid:
			if "enemy_base"    in creep: creep.set("enemy_base",    b)
		elif int(b.get("team_id")) == team_id:
			if "friendly_base" in creep: creep.set("friendly_base", b)
	if "enemy_base" in creep and is_instance_valid(creep.get("enemy_base")):
		var eb := creep.get("enemy_base") as Node3D
		var flow : Vector3 = (eb.global_position - (creep as Node3D).global_position)
		flow.y = 0.0
		if flow.length_squared() > 0.01:
			if creep.has_method("set_flow_direction"): creep.set_flow_direction(flow.normalized())
			if "_flow_dir" in creep: creep.set("_flow_dir", flow.normalized())
	var hm := get_tree().get_first_node_in_group("horde_manager")
	if is_instance_valid(hm) and hm.has_method("register"): hm.register(creep)
	if kind == "defend":
		if creep.has_method("set_ai_mode"): creep.set_ai_mode(2)
	else:
		if creep.has_method("set_ai_mode"): creep.set_ai_mode(1)
	return creep

func record_quest_event(event_type: String, amount: int = 1) -> void:
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if not is_instance_valid(qm): return
	var pid : int = int(get("player_id") if "player_id" in self else 0)
	qm.record_event(pid, event_type, amount)

var _turret_warn_cooldown : float = 0.0

func notify_turret_hit_without_rocket(target: Node) -> void:
	if not is_instance_valid(target): return
	if not (target.is_in_group("turrets") or target.is_in_group("towers")): return
	if _turret_warn_cooldown > 0.0: return
	if is_instance_valid(weapon_manager):
		var wep : Node = weapon_manager.get_current_weapon()
		if is_instance_valid(wep) and wep.get_script() != null:
			var sname : String = wep.get_script().resource_path.get_file()
			if "Rocket" in sname or "rocket" in sname: return
	_turret_warn_cooldown = 2.5
	_show_message("🚀 Turrets only take damage from rockets!", Color(1.0, 0.55, 0.1))

func _show_message(text: String, color: Color = Color.WHITE) -> void:
	print("[P%d] %s" % [player_id, text])
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("show_message"): h.show_message(text, color); return
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", color)
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.offset_left = -300; lbl.offset_right = 300
	lbl.offset_top  = -80;  lbl.offset_bottom = -40
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.z_index = 500
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - 30, 1.5).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 1.5).set_delay(0.8)
	tw.chain().tween_callback(lbl.queue_free)
# ============================================================
# CLASS SYSTEM — 15 classes, sword-only abilities
# ============================================================

enum PlayerClass {
	NONE,
	NECROMANCER,
	BERSERKER,
	PALADIN,
	SHADOWBLADE,
	STORMCALLER,
	BLOODMAGE,
	TIMEWEAVER,
	VOIDWALKER,
	IRONCLAD,
	PLAGUEMASTER,
	SOULREAPER,
	WARLOCK,
	PHOENIX,
	GRAVEMIND,
	DOOMSLAYER
}

const CLASS_NAMES : Dictionary = {
	PlayerClass.NONE:        "None",
	PlayerClass.NECROMANCER: "Necromancer",
	PlayerClass.BERSERKER:   "Berserker",
	PlayerClass.PALADIN:     "Paladin",
	PlayerClass.SHADOWBLADE: "Shadowblade",
	PlayerClass.STORMCALLER: "Stormcaller",
	PlayerClass.BLOODMAGE:   "Bloodmage",
	PlayerClass.TIMEWEAVER:  "Timeweaver",
	PlayerClass.VOIDWALKER:  "Voidwalker",
	PlayerClass.IRONCLAD:    "Ironclad",
	PlayerClass.PLAGUEMASTER:"Plaguemaster",
	PlayerClass.SOULREAPER:  "Soulreaper",
	PlayerClass.WARLOCK:     "Warlock",
	PlayerClass.PHOENIX:     "Phoenix",
	PlayerClass.GRAVEMIND:   "Gravemind",
	PlayerClass.DOOMSLAYER:  "Doomslayer",
}

const CLASS_ULT_NAMES : Dictionary = {
	PlayerClass.NONE:        "ULTIMATE",
	PlayerClass.NECROMANCER: "DEATH RISES",
	PlayerClass.BERSERKER:   "WORLD BREAKER",
	PlayerClass.PALADIN:     "DIVINE WRATH",
	PlayerClass.SHADOWBLADE: "SHADOW EXECUTION",
	PlayerClass.STORMCALLER: "STORM SURGE",
	PlayerClass.BLOODMAGE:   "BLOOD NOVA",
	PlayerClass.TIMEWEAVER:  "TIME STOP",
	PlayerClass.VOIDWALKER:  "VOID COLLAPSE",
	PlayerClass.IRONCLAD:    "FORTRESS",
	PlayerClass.PLAGUEMASTER:"PANDEMIC",
	PlayerClass.SOULREAPER:  "HARVEST",
	PlayerClass.WARLOCK:     "HELLGATE",
	PlayerClass.PHOENIX:     "SUPERNOVA",
	PlayerClass.GRAVEMIND:   "MIND CONTROL",
	PlayerClass.DOOMSLAYER:  "RECKONING",
}

# Per-class ult charge gain multiplier applied to both damage and kill credit
const CLASS_ULT_GAIN_MULT : Dictionary = {
	PlayerClass.NONE:         1.0,
	PlayerClass.NECROMANCER:  1.0,
	PlayerClass.BERSERKER:    1.5,
	PlayerClass.PALADIN:      0.8,
	PlayerClass.SHADOWBLADE:  1.2,
	PlayerClass.STORMCALLER:  1.3,
	PlayerClass.BLOODMAGE:    1.1,
	PlayerClass.TIMEWEAVER:   0.9,
	PlayerClass.VOIDWALKER:   1.2,
	PlayerClass.IRONCLAD:     0.7,
	PlayerClass.PLAGUEMASTER: 1.4,
	PlayerClass.SOULREAPER:   1.0,
	PlayerClass.WARLOCK:      1.1,
	PlayerClass.PHOENIX:      0.8,
	PlayerClass.GRAVEMIND:    1.2,
	PlayerClass.DOOMSLAYER:   1.6,
}

# Per-class FPS weapon sway: [bob_amount, bob_speed, sway_amount, tilt_amount]
# bob_amount  — vertical oscillation magnitude (subtle=0.02, heavy=0.12)
# bob_speed   — oscillation frequency (slow=5, twitchy=16)
# sway_amount — mouse-lag yaw scale (tight=0.5, floaty=3.0)
# tilt_amount — strafe roll scale   (rigid=1.0, loose=5.0)
const CLASS_SWAY : Dictionary = {
	PlayerClass.NONE:         [0.05, 10.0, 1.5, 3.0],
	PlayerClass.NECROMANCER:  [0.07,  7.0, 2.0, 2.0],  # slow ethereal drift
	PlayerClass.BERSERKER:    [0.12, 14.0, 1.0, 5.0],  # lurching heavy charge
	PlayerClass.PALADIN:      [0.03,  9.0, 1.0, 1.5],  # rigid disciplined march
	PlayerClass.SHADOWBLADE:  [0.04, 13.0, 2.5, 4.0],  # fluid assassin glide
	PlayerClass.STORMCALLER:  [0.06, 16.0, 3.0, 3.5],  # electric jitter
	PlayerClass.BLOODMAGE:    [0.08,  8.0, 1.8, 2.5],  # rhythmic pulse
	PlayerClass.TIMEWEAVER:   [0.02,  6.0, 0.8, 1.0],  # near-still controlled
	PlayerClass.VOIDWALKER:   [0.09,  5.0, 2.8, 1.5],  # weightless void float
	PlayerClass.IRONCLAD:     [0.10,  7.0, 0.5, 2.0],  # armored lumbering stomp
	PlayerClass.PLAGUEMASTER: [0.07, 11.0, 2.2, 4.5],  # uneven nauseating lurch
	PlayerClass.SOULREAPER:   [0.06,  9.0, 1.5, 3.0],  # reaping stride
	PlayerClass.WARLOCK:      [0.08, 10.0, 2.0, 3.5],  # dark surging steps
	PlayerClass.PHOENIX:      [0.05, 12.0, 1.5, 2.5],  # light rising tempo
	PlayerClass.GRAVEMIND:    [0.11,  6.0, 1.2, 1.8],  # shambling horror crawl
	PlayerClass.DOOMSLAYER:   [0.09, 15.0, 1.2, 4.0],  # military punchy drive
}

const CLASS_ABILITY_KEYS : Array = [KEY_1, KEY_2, KEY_3]

var player_class      : PlayerClass = PlayerClass.NONE
var _class_cooldowns  : Array[float] = [0.0, 0.0, 0.0, 0.0]
var _class_cd_max     : Array[float] = [0.0, 0.0, 0.0, 0.0]
var _sword_equipped   : bool = false

# per-class state
var _necro_thralls       : Array    = []
var _necro_thrall_timer  : float    = 0.0
var _berserker_kills     : int      = 0
var _berserker_rage      : float    = 0.0
var _paladin_aura_timer  : float    = 0.0
var _shadow_stacks       : int      = 0
var _storm_charges       : int      = 0
var _blood_hp_spent      : float    = 0.0
var _time_slow_timer     : float    = 0.0
var _void_rifts          : Array    = []
var _iron_stacks         : int      = 0
var _plague_cloud_timer  : float    = 0.0
var _plague_dps_accum    : float    = 0.0
var _pandemic_timer      : float    = 0.0
var _pandemic_dps_accum  : float    = 0.0
var _phoenix_dps_accum   : float    = 0.0
var _soul_count          : int      = 0
var _warlock_pact_hp     : float    = 0.0
var _phoenix_dead        : bool     = false
var _phoenix_timer       : float    = 0.0
var _phoenix_flame_pos   : Vector3  = Vector3.ZERO
var _phoenix_flame_timer : float    = 0.0
var _gravemind_puppets   : Array    = []
var _doom_mark_target    : Node     = null
var _doom_storm_timer    : float    = 0.0
var _doom_storm_accum    : float    = 0.0
var _doom_storm_pos      : Vector3  = Vector3.ZERO
var _plague_cloud_pos    : Vector3  = Vector3.ZERO

# ── Interactive Ability System ─────────────────────────────────
# 0 = instant  1 = ground-target (click to place)  2 = projectile
# Indexed [class_idx][slot]  where class_idx = int(player_class)-1
const ABILITY_TARGET_TYPE : Array = [
#   s0  s1  s2  s3
	[ 0,  2,  1,  0],  # NECROMANCER
	[ 0,  0,  0,  1],  # BERSERKER
	[ 1,  0,  1,  0],  # PALADIN
	[ 1,  0,  0,  0],  # SHADOWBLADE
	[ 2,  1,  1,  0],  # STORMCALLER
	[ 2,  0,  0,  0],  # BLOODMAGE
	[ 1,  0,  0,  0],  # TIMEWEAVER
	[ 0,  1,  0,  0],  # VOIDWALKER
	[ 0,  0,  0,  0],  # IRONCLAD
	[ 2,  1,  0,  0],  # PLAGUEMASTER
	[ 0,  2,  0,  0],  # SOULREAPER
	[ 2,  0,  0,  0],  # WARLOCK
	[ 2,  0,  1,  0],  # PHOENIX
	[ 0,  0,  1,  0],  # GRAVEMIND
	[ 0,  0,  1,  0],  # DOOMSLAYER
]
# max cast range for ground-target abilities (0 = unlimited)
const ABILITY_TARGET_RANGE : Array = [
	[ 0.0, 0.0, 30.0,  0.0],  # NECROMANCER
	[ 0.0, 0.0,  0.0, 30.0],  # BERSERKER
	[30.0, 0.0, 30.0,  0.0],  # PALADIN
	[25.0, 0.0,  0.0,  0.0],  # SHADOWBLADE
	[ 0.0,28.0, 35.0,  0.0],  # STORMCALLER
	[ 0.0, 0.0,  0.0,  0.0],  # BLOODMAGE
	[28.0, 0.0,  0.0,  0.0],  # TIMEWEAVER
	[ 0.0,25.0,  0.0,  0.0],  # VOIDWALKER
	[ 0.0, 0.0,  0.0,  0.0],  # IRONCLAD
	[ 0.0,22.0,  0.0,  0.0],  # PLAGUEMASTER
	[ 0.0, 0.0,  0.0,  0.0],  # SOULREAPER
	[ 0.0, 0.0,  0.0,  0.0],  # WARLOCK
	[ 0.0, 0.0, 35.0,  0.0],  # PHOENIX
	[ 0.0, 0.0, 32.0,  0.0],  # GRAVEMIND
	[ 0.0, 0.0, 35.0,  0.0],  # DOOMSLAYER
]

var _targeting_slot    : int   = -1       # -1 = not targeting
var _target_indicator  : Node3D = null    # ground circle mesh
var _target_pos        : Vector3 = Vector3.ZERO
var _ability_target_pos : Vector3 = Vector3.ZERO  # used inside ability functions
var _projectiles       : Array  = []      # live moving projectile dicts


# ============================================================
# SET CLASS
# ============================================================
func can_change_class() -> bool:
	if _class_lock_timer > 0.0:
		_show_message("🔒 Class locked for %.0fs" % _class_lock_timer, Color(0.8, 0.3, 0.3))
		return false
	return true


func set_player_class(c: PlayerClass) -> void:
	if player_class != PlayerClass.NONE and not can_change_class(): return
	player_class = c
	_class_lock_timer = CLASS_LOCK_DURATION
	_class_cooldowns = [0.0, 0.0, 0.0, 0.0]
	match c:
		PlayerClass.NECROMANCER:  _class_cd_max = [18.0, 30.0, 60.0, 12.0]
		PlayerClass.BERSERKER:    _class_cd_max = [8.0,  20.0, 45.0, 10.0]
		PlayerClass.PALADIN:      _class_cd_max = [12.0, 25.0, 50.0, 14.0]
		PlayerClass.SHADOWBLADE:  _class_cd_max = [6.0,  15.0, 35.0,  8.0]
		PlayerClass.STORMCALLER:  _class_cd_max = [5.0,  18.0, 40.0, 11.0]
		PlayerClass.BLOODMAGE:    _class_cd_max = [10.0, 22.0, 55.0,  9.0]
		PlayerClass.TIMEWEAVER:   _class_cd_max = [15.0, 35.0, 90.0, 13.0]
		PlayerClass.VOIDWALKER:   _class_cd_max = [8.0,  20.0, 50.0,  7.0]
		PlayerClass.IRONCLAD:     _class_cd_max = [10.0, 25.0, 60.0, 12.0]
		PlayerClass.PLAGUEMASTER: _class_cd_max = [7.0,  18.0, 45.0, 10.0]
		PlayerClass.SOULREAPER:   _class_cd_max = [5.0,  15.0, 40.0,  9.0]
		PlayerClass.WARLOCK:      _class_cd_max = [12.0, 30.0, 70.0, 11.0]
		PlayerClass.PHOENIX:      _class_cd_max = [20.0, 40.0, 120.0, 15.0]
		PlayerClass.GRAVEMIND:    _class_cd_max = [10.0, 25.0, 55.0, 10.0]
		PlayerClass.DOOMSLAYER:   _class_cd_max = [10.0, 20.0, 90.0,  8.0]
		_:                        _class_cd_max = [10.0, 20.0, 40.0, 10.0]
	_show_message("⚔ Class: %s" % CLASS_NAMES[c], Color(1.0, 0.8, 0.1))
	var _rsm_cls := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(_rsm_cls): _rsm_cls.set_player_class(player_id, int(c))
	var _sw : Array = CLASS_SWAY.get(c, CLASS_SWAY[PlayerClass.NONE])
	headbob_amount = _sw[0]
	headbob_speed  = _sw[1]
	sway_amount    = _sw[2]
	tilt_amount    = _sw[3]
	_update_ult_hud()


# ============================================================
# SWORD CHECK
# ============================================================
func _is_sword_equipped() -> bool:
	if not is_instance_valid(weapon_manager): return false
	var wep : Node = weapon_manager.get_current_weapon()
	return is_instance_valid(wep) and wep.has_method("swing")


# ============================================================
# INPUT HOOK — call this from _input()
# Add to the existing KEY match block in _input():
#   KEY_1: _try_class_ability(0)
#   KEY_2: _try_class_ability(1)
#   KEY_3: _try_class_ability(2)
# ============================================================
func _try_class_ability(slot: int) -> void:
	if player_class == PlayerClass.NONE: return
	if slot != 3 and not _is_sword_equipped():
		_show_message("⚔ Equip your sword to use class abilities [4] to move", Color(1.0, 0.4, 0.2))
		return
	if slot >= _class_cooldowns.size(): return
	if _class_cooldowns[slot] > 0.0:
		_show_message("⏳ %.1fs" % _class_cooldowns[slot], Color(0.6, 0.6, 0.6))
		return
	# Check ult charge cost (slot 3 = movement, always 0)
	var _ability_cost : float = ULT_ABILITY_COSTS[slot] if slot < ULT_ABILITY_COSTS.size() else 0.0
	if _ability_cost > 0.0 and ult_charge < _ability_cost:
		_show_message("⚡ Need %.0f%% charge  (%.0f%%)" % [_ability_cost, ult_charge], Color(0.5, 0.4, 0.8))
		return
	# Cancel existing targeting if same slot pressed again
	if _targeting_slot == slot:
		_cancel_targeting(); return
	var ttype := _get_ability_target_type(slot)
	if ttype == 1:   # ground-target: show indicator, wait for click
		_begin_ground_targeting(slot)
	else:            # instant or projectile: fire now
		_ability_target_pos = global_position
		_class_cooldowns[slot] = _class_cd_max[slot]
		_check_synergy(slot)
		_fire_class_ability(slot)


func _check_synergy(slot: int) -> void:
	var now : float = Time.get_ticks_msec() / 1000.0
	# Synergy: slot 0 (CC/stun ability) → slot 1 (damage) within SYNERGY_WINDOW
	if _last_ability_used == 0 and slot == 1 and (now - _last_ability_time) < SYNERGY_WINDOW:
		_synergy_active = true
		_synergy_timer  = SYNERGY_DURATION
		_show_message("💥 COMBO! +50% crit damage!", Color(1.0, 0.8, 0.1))
	_last_ability_used = slot
	_last_ability_time = now


func get_synergy_damage_mult() -> float:
	return 1.5 if _synergy_active else 1.0


func _get_ability_target_type(slot: int) -> int:
	var idx := int(player_class) - 1
	if idx < 0 or idx >= ABILITY_TARGET_TYPE.size(): return 0
	var row : Array = ABILITY_TARGET_TYPE[idx]
	if slot < 0 or slot >= row.size(): return 0
	return int(row[slot])


func _begin_ground_targeting(slot: int) -> void:
	if _targeting_slot >= 0: _cancel_targeting()
	_targeting_slot = slot
	# Clear any leftover mouse delta so the camera can't snap on mode-change
	mouse_input  = Vector2.ZERO
	smooth_mouse = Vector2.ZERO
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.flush_buffered_events()
	# Warp OS cursor to viewport centre so the indicator starts where we're already aiming
	get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	var col  := _get_indicator_color(slot)
	var rad  := _get_indicator_radius(slot)
	_target_indicator = _create_ground_indicator(col, rad)
	_show_message("🎯 Click to place — [RMB] cancel", Color(0.3, 0.95, 1.0))


func _cancel_targeting() -> void:
	_targeting_slot = -1
	if is_instance_valid(_target_indicator):
		_target_indicator.queue_free()
		_target_indicator = null
	if current_mode == CameraMode.FPS and not shop_open and not _deck_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		Input.flush_buffered_events()
		mouse_input  = Vector2.ZERO
		smooth_mouse = Vector2.ZERO


func _confirm_targeting(pos: Vector3) -> void:
	var slot := _targeting_slot
	_cancel_targeting()
	_ability_target_pos = pos
	_class_cooldowns[slot] = _class_cd_max[slot]
	_fire_class_ability(slot)


func _update_target_indicator() -> void:
	if _targeting_slot < 0 or not is_instance_valid(_target_indicator): return
	var pos := _get_mouse_ground_pos()
	# Clamp to max range
	var idx := int(player_class) - 1
	if idx >= 0 and idx < ABILITY_TARGET_RANGE.size():
		var row : Array = ABILITY_TARGET_RANGE[idx]
		var slot := _targeting_slot
		if slot >= 0 and slot < row.size():
			var max_r := float(row[slot])
			if max_r > 0.0:
				var dir := pos - global_position
				dir.y = 0.0
				if dir.length() > max_r:
					pos = global_position + dir.normalized() * max_r
					pos.y = _get_mouse_ground_pos().y  # keep ground height
	_target_pos = pos
	_target_indicator.global_position = pos + Vector3(0.0, 0.05, 0.0)


func _get_mouse_ground_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if not is_instance_valid(cam): return global_position
	var vp_size := get_viewport().get_visible_rect().size
	var mouse   := get_viewport().get_mouse_position()
	# Clamp mouse to viewport
	mouse = mouse.clamp(Vector2.ZERO, vp_size)
	var from := cam.project_ray_origin(mouse)
	var dir  := cam.project_ray_normal(mouse)
	# Physics raycast for accurate ground hit
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 400.0)
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		return hit["position"]
	# Fallback: Y=0 plane intersection
	if abs(dir.y) > 0.001:
		var t := -from.y / dir.y
		if t > 0.0: return from + dir * t
	return global_position


func _create_ground_indicator(col: Color, radius: float) -> MeshInstance3D:
	# Flat disc with pulsing emission
	var cyl        := CylinderMesh.new()
	cyl.top_radius    = radius
	cyl.bottom_radius = radius
	cyl.height        = 0.08
	cyl.radial_segments = 32
	var mat := StandardMaterial3D.new()
	mat.transparency      = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color      = Color(col.r, col.g, col.b, 0.30)
	mat.emission_enabled  = true
	mat.emission          = col
	mat.emission_energy   = 2.0
	mat.shading_mode      = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test     = true
	var mi := MeshInstance3D.new()
	mi.mesh              = cyl
	mi.material_override = mat
	mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mi)
	# Pulsing ring: animate emission
	var tw := mi.create_tween().set_loops()
	tw.tween_property(mat, "emission_energy", 0.6, 0.4)
	tw.tween_property(mat, "emission_energy", 2.0, 0.4)
	return mi


func _get_indicator_color(slot: int) -> Color:
	match player_class:
		PlayerClass.PALADIN:      return Color(1.0, 0.95, 0.3)
		PlayerClass.SHADOWBLADE:  return Color(0.3, 0.0, 0.65)
		PlayerClass.STORMCALLER:  return Color(0.9, 0.95, 0.1)
		PlayerClass.TIMEWEAVER:   return Color(0.3, 0.85, 1.0)
		PlayerClass.VOIDWALKER:   return Color(0.45, 0.0, 0.95)
		PlayerClass.PLAGUEMASTER: return Color(0.1, 0.9, 0.1)
		PlayerClass.PHOENIX:      return Color(1.0, 0.45, 0.0)
		PlayerClass.GRAVEMIND:    return Color(0.0, 0.7, 0.35)
		PlayerClass.DOOMSLAYER:   return Color(1.0, 0.05, 0.0)
		PlayerClass.BERSERKER:    return Color(1.0, 0.15, 0.0)
		PlayerClass.NECROMANCER:  return Color(0.6, 0.0, 0.85)
		_: return Color(0.6, 0.6, 1.0)


func _get_indicator_radius(slot: int) -> float:
	match player_class:
		PlayerClass.PALADIN:
			return 10.0 if slot == 2 else 6.0
		PlayerClass.STORMCALLER:
			return 12.0 if slot == 2 else 8.0
		PlayerClass.PLAGUEMASTER: return 6.0
		PlayerClass.TIMEWEAVER:   return 10.0
		PlayerClass.VOIDWALKER:   return 7.0
		PlayerClass.PHOENIX:      return 14.0
		PlayerClass.GRAVEMIND:    return 15.0
		PlayerClass.DOOMSLAYER:   return 20.0
		PlayerClass.BERSERKER:    return 3.0
		PlayerClass.SHADOWBLADE:  return 1.5
		PlayerClass.NECROMANCER:  return 12.0
		_: return 6.0


func _fire_class_ability(slot: int) -> void:
	# Deduct ult charge cost when the ability actually fires (covers both instant and ground-target paths)
	var _fire_cost : float = ULT_ABILITY_COSTS[slot] if slot < ULT_ABILITY_COSTS.size() else 0.0
	if _fire_cost > 0.0:
		ult_charge = maxf(0.0, ult_charge - _fire_cost)
		_update_ult_hud()
	match player_class:
		PlayerClass.NECROMANCER:  _ability_necromancer(slot)
		PlayerClass.BERSERKER:    _ability_berserker(slot)
		PlayerClass.PALADIN:      _ability_paladin(slot)
		PlayerClass.SHADOWBLADE:  _ability_shadowblade(slot)
		PlayerClass.STORMCALLER:  _ability_stormcaller(slot)
		PlayerClass.BLOODMAGE:    _ability_bloodmage(slot)
		PlayerClass.TIMEWEAVER:   _ability_timeweaver(slot)
		PlayerClass.VOIDWALKER:   _ability_voidwalker(slot)
		PlayerClass.IRONCLAD:     _ability_ironclad(slot)
		PlayerClass.PLAGUEMASTER: _ability_plaguemaster(slot)
		PlayerClass.SOULREAPER:   _ability_soulreaper(slot)
		PlayerClass.WARLOCK:      _ability_warlock(slot)
		PlayerClass.PHOENIX:      _ability_phoenix(slot)
		PlayerClass.GRAVEMIND:    _ability_gravemind(slot)
		PlayerClass.DOOMSLAYER:   _ability_doomslayer(slot)


# ── Shared movement helpers ─────────────────────────────────────
func _look_forward() -> Vector3:
	var cam := fps_camera if current_mode == CameraMode.FPS else td_camera
	if is_instance_valid(cam):
		return -cam.global_transform.basis.z
	return -global_transform.basis.z


func _class_dash(dist: float, up: float = 0.0, hit_radius: float = 0.0, hit_dmg: float = 0.0) -> void:
	var fwd := _look_forward(); fwd.y = 0.0
	if fwd.length_squared() < 0.01: fwd = -global_transform.basis.z
	fwd = fwd.normalized()
	velocity.x = fwd.x * dist * 8.0
	velocity.z = fwd.z * dist * 8.0
	if up > 0.0: velocity.y = up
	_shield_timer = maxf(_shield_timer, 0.15)  # brief invincibility during dash
	if hit_radius > 0.0:
		get_tree().create_timer(0.25).timeout.connect(func():
			for grp in ["zombies", "units", "players", "hive_unit"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) <= hit_radius:
						if z.has_method("take_damage"): z.take_damage(hit_dmg, self)
			, CONNECT_ONE_SHOT)


func _class_teleport(dist: float, hit_radius: float = 0.0, hit_dmg: float = 0.0) -> void:
	var fwd := _look_forward(); fwd.y = 0.0
	if fwd.length_squared() < 0.01: fwd = -global_transform.basis.z
	fwd = fwd.normalized()
	global_position += fwd * dist + Vector3.UP * 0.3
	if hit_radius > 0.0:
		for grp in ["zombies", "units", "players", "hive_unit"]:
			for z in get_tree().get_nodes_in_group(grp):
				if not is_instance_valid(z) or not (z is Node3D): continue
				if "team_id" in z and int(z.get("team_id")) == team_id: continue
				if global_position.distance_to((z as Node3D).global_position) <= hit_radius:
					if z.has_method("take_damage"): z.take_damage(hit_dmg, self)


# ── VFX helpers ──────────────────────────────────────────────────────────────
func _vfx_ring(pos: Vector3, col: Color, radius: float, duration: float = 0.5) -> void:
	var mi   := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.8; mesh.outer_radius = 1.0; mesh.rings = 12; mesh.ring_segments = 24
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col; mat.emission_enabled = true; mat.emission = col * 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; mat.no_depth_test = true
	mi.material_override = mat
	mi.position = pos + Vector3.UP * 0.15; mi.scale = Vector3(0.05, 1.0, 0.05)
	get_tree().current_scene.add_child(mi)
	var tw := mi.create_tween(); tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(radius, 1.0, radius), duration)
	tw.tween_property(mat, "albedo_color:a", 0.0, duration)
	tw.chain().tween_callback(mi.queue_free)


func _vfx_burst(pos: Vector3, col: Color, count: int = 20, duration: float = 0.8) -> void:
	var p := CPUParticles3D.new()
	p.emitting = true; p.one_shot = true; p.amount = count; p.lifetime = duration
	p.explosiveness = 0.95; p.direction = Vector3.UP; p.spread = 180.0
	p.initial_velocity_min = 3.0; p.initial_velocity_max = 9.0
	p.gravity = Vector3(0, -5, 0); p.color = col; p.position = pos
	get_tree().current_scene.add_child(p)
	get_tree().create_timer(duration + 0.2).timeout.connect(p.queue_free, CONNECT_ONE_SHOT)


func _vfx_light_pulse(pos: Vector3, col: Color, duration: float = 0.4) -> void:
	var light := OmniLight3D.new()
	light.position = pos + Vector3.UP * 1.2
	light.light_color = col; light.omni_range = 12.0; light.light_energy = 5.0
	get_tree().current_scene.add_child(light)
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, duration)
	tw.tween_callback(light.queue_free)


func _vfx_beam(from: Vector3, to: Vector3, col: Color, duration: float = 0.3) -> void:
	var dist := from.distance_to(to)
	if dist < 0.1: return
	var mi   := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.height = dist; mesh.top_radius = 0.05; mesh.bottom_radius = 0.05
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col; mat.emission_enabled = true; mat.emission = col * 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; mat.no_depth_test = true
	mi.material_override = mat
	get_tree().current_scene.add_child(mi)
	mi.global_position = (from + to) * 0.5
	var up := Vector3.UP if abs((to - from).normalized().dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	mi.look_at(to, up)
	mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	var tw := mi.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, duration)
	tw.tween_callback(mi.queue_free)


## Single storm bolt at a random point within 8m of tpos — shared by Storm Surge + Thundergod.
func _do_storm_bolt(tpos: Vector3) -> void:
	var scatter := tpos + Vector3(randf_range(-8.0, 8.0), 0.0, randf_range(-8.0, 8.0))
	_vfx_beam(scatter + Vector3(0.0, 18.0, 0.0), scatter, Color(1.0, 1.0, 0.15), 0.22)
	_vfx_light_pulse(scatter, Color(1.0, 1.0, 0.1), 0.15)
	for grp in ["zombies", "units", "players"]:
		for z in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(z) or not (z is Node3D): continue
			if "team_id" in z and int(z.get("team_id")) == team_id: continue
			if scatter.distance_to((z as Node3D).global_position) < 3.5:
				if z.has_method("take_damage"): z.take_damage(90.0, self)


## Returns the camera's forward unit vector (for projectile direction).
func _get_aim_dir() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if is_instance_valid(cam):
		return -cam.global_transform.basis.z
	return -global_transform.basis.z


## Returns the projectile spawn origin (camera position, slightly forward).
func _get_aim_origin() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if is_instance_valid(cam):
		return cam.global_position + (-cam.global_transform.basis.z) * 1.2
	return global_position + Vector3.UP * 1.5


## Sky-fall effect: warning ring at pos, then after `delay` seconds a beam
## slams in from above and the actual effect lambda fires.
func _vfx_sky_strike(pos: Vector3, col: Color, radius: float,
		delay: float, on_impact: Callable) -> void:
	# Warning indicator (expanding ring on ground)
	_vfx_ring(pos, col, radius * 0.6, delay * 0.8)
	# Rising light above target
	var warn_li := OmniLight3D.new()
	warn_li.light_color  = col
	warn_li.omni_range   = radius * 1.5
	warn_li.light_energy = 3.0
	warn_li.global_position = pos + Vector3.UP * 15.0
	get_tree().current_scene.add_child(warn_li)
	var tw_warn := warn_li.create_tween()
	tw_warn.tween_property(warn_li, "global_position:y", pos.y + 1.5, delay)
	tw_warn.tween_callback(warn_li.queue_free)
	# After delay: impact
	get_tree().create_timer(delay).timeout.connect(func():
		# Vertical beam from sky
		_vfx_beam(pos + Vector3.UP * 20.0, pos, col, 0.35)
		# Impact ring
		_vfx_ring(pos, col, radius, 0.5)
		_vfx_burst(pos, col, 40, 0.7)
		_vfx_light_pulse(pos, col, 0.6)
		on_impact.call()
	, CONNECT_ONE_SHOT)


func _vfx_cloud_on_node(node: Node3D, col: Color, duration: float) -> void:
	if not is_instance_valid(node): return
	var p := CPUParticles3D.new()
	p.emitting = true; p.one_shot = false; p.amount = 10; p.lifetime = 0.7
	p.direction = Vector3.UP; p.spread = 60.0
	p.initial_velocity_min = 0.4; p.initial_velocity_max = 1.5
	p.gravity = Vector3(0, 0.2, 0); p.color = col; p.position = Vector3(0.0, 1.0, 0.0)
	node.add_child(p)
	get_tree().create_timer(duration).timeout.connect(func():
		if is_instance_valid(p):
			p.emitting = false
			get_tree().create_timer(0.8).timeout.connect(func():
				if is_instance_valid(p): p.queue_free(), CONNECT_ONE_SHOT)
		, CONNECT_ONE_SHOT)


# ============================================================
# TICK — call from _process(delta)
# Add: _tick_class_abilities(delta)
# ============================================================
func _tick_class_abilities(delta: float) -> void:
	for i in 4:
		if _class_cooldowns[i] > 0.0:
			_class_cooldowns[i] = maxf(0.0, _class_cooldowns[i] - delta)
	if _targeting_slot >= 0:
		_update_target_indicator()
	_tick_projectiles(delta)

	match player_class:
		PlayerClass.NECROMANCER:  _tick_necromancer(delta)
		PlayerClass.BERSERKER:    _tick_berserker(delta)
		PlayerClass.PALADIN:      _tick_paladin(delta)
		PlayerClass.TIMEWEAVER:   _tick_timeweaver(delta)
		PlayerClass.PHOENIX:      _tick_phoenix(delta)
		PlayerClass.PLAGUEMASTER: _tick_plaguemaster(delta)
		PlayerClass.GRAVEMIND:    _tick_gravemind(delta)
		PlayerClass.DOOMSLAYER:   _tick_doomslayer(delta)


# ============================================================
# PROJECTILE ENGINE
# ============================================================
# Each projectile is a Dictionary:
#   mesh      : MeshInstance3D
#   light     : OmniLight3D (optional glow)
#   pos       : Vector3
#   vel       : Vector3
#   dmg       : float
#   radius    : float   (hit detection radius)
#   ttl       : float   (seconds remaining)
#   pierce    : bool
#   hit_set   : Array   (already-hit nodes, for pierce)
#   col       : Color   (hit burst colour)
#   on_hit    : Callable(node, pos)   optional extra on-hit effect
#   on_expire : Callable(pos)         optional on-TTL-expire effect

func _tick_projectiles(delta: float) -> void:
	var to_del : Array = []
	for p in _projectiles:
		var mi : MeshInstance3D = p.get("mesh")
		if not is_instance_valid(mi):
			to_del.append(p); continue

		p["ttl"] -= delta
		if float(p["ttl"]) <= 0.0:
			var on_exp = p.get("on_expire")
			if on_exp is Callable: on_exp.call(p["pos"])
			mi.queue_free()
			var li = p.get("light")
			if is_instance_valid(li): li.queue_free()
			to_del.append(p); continue

		var vel  : Vector3 = p["vel"]
		var pos  : Vector3 = p["pos"]
		pos += vel * delta
		p["pos"] = pos
		mi.global_position = pos
		var li2 = p.get("light")
		if is_instance_valid(li2): li2.global_position = pos

		# ── Hit detection ──
		var hit_set : Array = p.get("hit_set", [])
		var pierce  : bool  = bool(p.get("pierce", false))
		var dmg     : float = float(p.get("dmg", 0.0))
		var rad     : float = float(p.get("radius", 0.8))
		var col     : Color = p.get("col", Color.WHITE)
		var hit_this_frame := false
		for grp in ["zombies", "units", "players", "hive_unit"]:
			if hit_this_frame and not pierce: break
			for z in get_tree().get_nodes_in_group(grp):
				if not is_instance_valid(z) or not (z is Node3D): continue
				if "team_id" in z and int(z.get("team_id")) == team_id: continue
				if hit_set.has(z): continue
				if pos.distance_to((z as Node3D).global_position) < rad:
					if z.has_method("take_damage"): z.take_damage(dmg, self)
					_vfx_burst((z as Node3D).global_position, col, 10, 0.3)
					_vfx_light_pulse((z as Node3D).global_position, col, 0.2)
					var on_hit = p.get("on_hit")
					if on_hit is Callable: on_hit.call(z, pos)
					if pierce:
						hit_set.append(z)
						p["hit_set"] = hit_set
					else:
						mi.queue_free()
						var li3 = p.get("light")
						if is_instance_valid(li3): li3.queue_free()
						to_del.append(p)
						hit_this_frame = true; break

	for p in to_del:
		_projectiles.erase(p)


## Spawn a moving projectile from `from_pos` in direction `dir`.
## config keys: dmg, speed, radius, col, ttl, pierce, mesh_color,
##              mesh_radius(sphere), on_hit(Callable), on_expire(Callable)
func _spawn_projectile(from_pos: Vector3, dir: Vector3, config: Dictionary) -> void:
	var speed  : float = float(config.get("speed", 20.0))
	var mrad   : float = float(config.get("mesh_radius", 0.18))
	var mcol   : Color = config.get("mesh_color", config.get("col", Color.WHITE))

	# Build sphere mesh
	var sph := SphereMesh.new()
	sph.radius = mrad
	sph.height = mrad * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = mcol
	mat.emission_enabled = true
	mat.emission         = mcol
	mat.emission_energy  = 3.0
	mat.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := MeshInstance3D.new()
	mi.mesh              = sph
	mi.material_override = mat
	mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mi)
	mi.global_position = from_pos

	# Optional point light glow
	var li := OmniLight3D.new()
	li.light_color   = mcol
	li.omni_range    = 4.0
	li.light_energy  = 2.0
	li.shadow_enabled = false
	get_tree().current_scene.add_child(li)
	li.global_position = from_pos

	# Particle trail
	var trail := CPUParticles3D.new()
	trail.emitting              = true
	trail.amount                = 12
	trail.lifetime              = 0.25
	trail.one_shot              = false
	trail.emission_shape        = CPUParticles3D.EMISSION_SHAPE_SPHERE
	trail.emission_sphere_radius = 0.05
	trail.direction             = -dir
	trail.spread                = 15.0
	trail.initial_velocity_min  = 1.0
	trail.initial_velocity_max  = 3.0
	trail.color                 = mcol
	trail.gravity               = Vector3.ZERO
	mi.add_child(trail)

	_projectiles.append({
		"mesh":     mi,
		"light":    li,
		"pos":      from_pos,
		"vel":      dir.normalized() * speed,
		"dmg":      float(config.get("dmg", 150.0)),
		"radius":   float(config.get("radius", 0.9)),
		"ttl":      float(config.get("ttl", 2.5)),
		"pierce":   bool(config.get("pierce", false)),
		"hit_set":  [],
		"col":      config.get("col", mcol),
		"on_hit":   config.get("on_hit", null),
		"on_expire":config.get("on_expire", null),
	})


# ============================================================
# 1. NECROMANCER — convert on death / raise thralls / army
# ============================================================
func _ability_necromancer(slot: int) -> void:
	match slot:
		0: # Raise Dead — instantly convert nearest corpse/enemy to thrall
			var best : Node3D = null; var bd : float = INF
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					var d := global_position.distance_to((z as Node3D).global_position)
					if d < bd and d < 20.0: bd = d; best = z as Node3D
			if is_instance_valid(best):
				if best.has_method("convert_team"):
					best.call("convert_team")
					_necro_thralls.append(best)
					_vfx_beam(global_position, best.global_position, Color(0.5, 0.0, 0.9), 0.5)
					_vfx_ring(best.global_position, Color(0.5, 0.0, 0.9), 2.0)
					_vfx_light_pulse(best.global_position, Color(0.4, 0.0, 0.8), 0.5)
					_show_message("💀 Raised thrall!", Color(0.5, 0.0, 0.8))
			else:
				_show_message("No enemies in range", Color(0.6, 0.6, 0.6))

		1: # Death Pulse — radial burst in all 8 directions, heals per hit
			for i in 8:
				var ang := float(i) / 8.0 * TAU
				var rdir := Vector3(cos(ang), 0.0, sin(ang)).normalized()
				_spawn_projectile(global_position + Vector3.UP * 1.0, rdir, {
					"dmg": 120.0, "speed": 14.0, "radius": 1.2, "ttl": 1.5,
					"pierce": true,
					"col": Color(0.5, 0.0, 0.85),
					"mesh_color": Color(0.45, 0.0, 0.75),
					"mesh_radius": 0.22,
					"on_hit": func(_z, _p):
						health = minf(health + 25.0, max_health)
						health_changed.emit(health, max_health),
				})
			_vfx_ring(global_position, Color(0.3, 0.0, 0.6), 4.0, 0.4)
			_vfx_burst(global_position, Color(0.4, 0.0, 0.8), 20)
			_vfx_light_pulse(global_position, Color(0.4, 0.0, 0.7), 0.4)
			_show_message("💀 DEATH PULSE — 8-way death wave, heals per hit!", Color(0.5, 0.0, 0.8))

		2: # Undead Army — raise dead in 15m of targeted position
			var tpos := _ability_target_pos
			var count := 0
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if tpos.distance_to((z as Node3D).global_position) > 15.0: continue
					if "team_id" in z: z.set("team_id", team_id)
					if "target" in z: z.set("target", null)
					_necro_thralls.append(z)
					_vfx_beam(tpos, (z as Node3D).global_position, Color(0.5, 0.0, 0.85), 0.5)
					_vfx_burst((z as Node3D).global_position, Color(0.55, 0.0, 0.8), 8, 0.4)
					count += 1
			_necro_thrall_timer = 45.0
			_vfx_ring(tpos, Color(0.5, 0.0, 1.0), 15.0, 0.8)
			_vfx_burst(tpos, Color(0.4, 0.0, 0.9), 40, 1.0)
			_vfx_light_pulse(tpos, Color(0.5, 0.0, 0.8), 0.8)
			_show_message("💀 UNDEAD ARMY — %d units raised at target!" % count, Color(0.7, 0.0, 1.0))
		3: # Spirit Walk — dash through enemies, draining 40 HP from each passed
			_ghost_timer = maxf(_ghost_timer, 1.0)
			_vfx_ring(global_position, Color(0.4, 0.0, 0.8), 3.0, 0.4)
			_vfx_burst(global_position, Color(0.5, 0.0, 0.9, 0.8), 15)
			_class_dash(14.0, 2.0, 3.0, 40.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_burst(global_position, Color(0.4, 0.0, 0.9), 20), CONNECT_ONE_SHOT)
			_show_message("💀 SPIRIT WALK — phasing through enemies!", Color(0.5, 0.0, 0.8))

func _tick_necromancer(delta: float) -> void:
	# Thralls from army ability expire
	if _necro_thrall_timer > 0.0:
		_necro_thrall_timer -= delta
		if _necro_thrall_timer <= 0.0:
			for t in _necro_thralls:
				if is_instance_valid(t) and t.has_method("_die"):
					t.call("_die")
			_necro_thralls.clear()
			_show_message("💀 Thralls expired", Color(0.5, 0.0, 0.8))

	# Passive: sword kills have 40% chance to auto-raise
	# (hooked in take_damage kill detection via _on_kill_with_sword)


# ============================================================
# 2. BERSERKER — rage stacks, infinite combo, execute
# ============================================================
func _ability_berserker(slot: int) -> void:
	match slot:
		0: # War Cry — next 3 sword hits deal 3x damage + knockback wave
			_berserker_rage = 3.0
			_double_damage_timer = 8.0
			_vfx_ring(global_position, Color(1.0, 0.1, 0.0), 5.0, 0.5)
			_vfx_burst(global_position, Color(1.0, 0.2, 0.0), 25)
			_vfx_light_pulse(global_position, Color(1.0, 0.1, 0.0), 0.5)
			_show_message("⚔ WAR CRY — next 3 hits 3x damage!", Color(1.0, 0.2, 0.0))
		1: # Bloodlust — killing an enemy heals 50hp and resets cooldown[0]
			_berserk_timer = 12.0
			_vfx_burst(global_position, Color(0.9, 0.0, 0.0), 20)
			_vfx_light_pulse(global_position, Color(1.0, 0.0, 0.0), 0.4)
			_show_message("🩸 BLOODLUST — kills heal 50hp!", Color(1.0, 0.0, 0.0))
		2: # RAGNAROK — 8s: infinite stamina, 5x damage, no cooldowns, AOE on every swing
			_berserker_rage = 999.0
			_berserk_timer = 8.0
			_double_damage_timer = 8.0
			_sprint_boost_timer = 8.0
			_shield_timer = 8.0
			_vfx_ring(global_position, Color(1.0, 0.0, 0.0), 12.0, 0.7)
			_vfx_burst(global_position, Color(1.0, 0.1, 0.0), 60, 1.2)
			_vfx_light_pulse(global_position, Color(1.0, 0.0, 0.0), 1.0)
			get_tree().create_timer(8.0).timeout.connect(func():
				_berserker_rage = 0.0
				_show_message("Ragnarok ended", Color(0.5, 0.5, 0.5)), CONNECT_ONE_SHOT)
			_show_message("⚔ RAGNAROK — 8 SECONDS OF DESTRUCTION!", Color(1.0, 0.0, 0.0))
		3: # Savage Leap — leap to clicked location, 5m AOE 180 dmg on landing
			var tpos := _ability_target_pos
			_vfx_ring(global_position, Color(1.0, 0.3, 0.0), 3.0, 0.3)
			_vfx_burst(global_position, Color(1.0, 0.3, 0.0, 0.8), 15)
			global_position = tpos + Vector3.UP * 0.5
			velocity = Vector3.ZERO
			_vfx_ring(tpos, Color(1.0, 0.2, 0.0), 7.0, 0.5)
			_vfx_burst(tpos, Color(1.0, 0.3, 0.0), 40)
			_vfx_light_pulse(tpos, Color(1.0, 0.2, 0.0), 0.5)
			for grp in ["zombies", "units", "players", "hive_unit"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if tpos.distance_to((z as Node3D).global_position) <= 5.0:
						if z.has_method("take_damage"): z.take_damage(180.0, self)
			_show_message("⚔ SAVAGE LEAP — SMASH!", Color(1.0, 0.2, 0.0))

func _tick_berserker(delta: float) -> void:
	if _berserker_kills > 0:
		_berserker_kills = 0


# ============================================================
# 3. PALADIN — holy aura, divine shield, smite
# ============================================================
func _ability_paladin(slot: int) -> void:
	match slot:
		0: # Holy Smite — sky strike at target location: 0.8s warning, 350 dmg in 8m
			var tpos := _ability_target_pos
			_vfx_sky_strike(tpos, Color(1.0, 0.95, 0.3), 8.0, 0.8, func():
				for grp in ["zombies", "units", "players"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if tpos.distance_to((z as Node3D).global_position) <= 8.0:
							if z.has_method("take_damage"): z.take_damage(350.0, self)
			)
			_show_message("✨ HOLY SMITE — divine strike incoming!", Color(1.0, 0.95, 0.3))
		1: # Divine Shield — immune 6s + reflect 50% damage back
			_shield_timer = 6.0
			_vfx_ring(global_position, Color(1.0, 0.95, 0.3), 4.0, 0.6)
			_vfx_light_pulse(global_position, Color(1.0, 1.0, 0.4), 0.8)
			_show_message("✨ DIVINE SHIELD — 6s immunity + reflect", Color(1.0, 0.95, 0.3))
		2: # Consecration — holy zone at target: heal allies + 20s shield, 250 dmg enemies in 10m
			var tpos := _ability_target_pos
			_vfx_ring(tpos, Color(1.0, 1.0, 0.4), 10.0, 1.0)
			_vfx_burst(tpos, Color(1.0, 0.95, 0.3), 50, 1.2)
			_vfx_light_pulse(tpos, Color(1.0, 1.0, 0.5), 1.0)
			for grp in ["player", "units"]:
				for p in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(p) or not (p is Node3D): continue
					if "team_id" in p and int(p.get("team_id")) != team_id: continue
					if tpos.distance_to((p as Node3D).global_position) > 10.0: continue
					if "health" in p and "max_health" in p:
						p.set("health", p.get("max_health"))
						if p.has_signal("health_changed"): p.health_changed.emit(p.health, p.max_health)
					if "_shield_timer" in p: p.set("_shield_timer", 20.0)
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if tpos.distance_to((z as Node3D).global_position) > 10.0: continue
					if z.has_method("take_damage"): z.take_damage(250.0, self)
			_show_message("✨ CONSECRATION — holy zone! Allies healed, enemies scorched!", Color(1.0, 1.0, 0.5))
		3: # Holy Charge — dash forward, knock and stun all enemies on path
			_shield_timer = maxf(_shield_timer, 1.0)
			_vfx_ring(global_position, Color(1.0, 0.95, 0.3), 3.0, 0.3)
			_vfx_burst(global_position, Color(1.0, 1.0, 0.5), 15)
			_class_dash(13.0, 1.5, 3.5, 120.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_ring(global_position, Color(1.0, 0.95, 0.3), 5.0, 0.4)
				_vfx_burst(global_position, Color(1.0, 1.0, 0.4), 25)
				_vfx_light_pulse(global_position, Color(1.0, 1.0, 0.3), 0.4), CONNECT_ONE_SHOT)
			_show_message("✨ HOLY CHARGE — FOR THE LIGHT!", Color(1.0, 0.95, 0.3))

func _tick_paladin(_delta: float) -> void:
	pass


# ============================================================
# 4. SHADOWBLADE — backstab, vanish, shadow clone
# ============================================================
func _ability_shadowblade(slot: int) -> void:
	match slot:
		0: # Shadow Step — blink to clicked location (up to 25m), invisible 1.5s on arrival
			var tpos := _ability_target_pos
			_vfx_burst(global_position, Color(0.2, 0.0, 0.4, 0.8), 15)
			_vfx_ring(global_position, Color(0.3, 0.0, 0.6), 3.0, 0.3)
			global_position = tpos + Vector3.UP * 0.3
			velocity = Vector3.ZERO
			_shadow_stacks += 1
			_ghost_timer = maxf(_ghost_timer, 1.5)
			_vfx_ring(tpos, Color(0.4, 0.0, 0.7), 3.0, 0.4)
			_vfx_burst(tpos, Color(0.3, 0.0, 0.5, 0.9), 20)
			_vfx_light_pulse(tpos, Color(0.3, 0.0, 0.5), 0.3)
			_show_message("🌑 SHADOW STEP — blinked! 1.5s invisible (stacks: %d)" % _shadow_stacks, Color(0.4, 0.0, 0.6))
		1: # Vanish — invisible 5s, next hit = 10x damage
			_ghost_timer = 5.0
			_shadow_stacks += 3
			_vfx_burst(global_position, Color(0.15, 0.0, 0.3, 0.9), 30)
			_vfx_ring(global_position, Color(0.3, 0.0, 0.5), 4.0, 0.4)
			_show_message("🌑 VANISH — 5s invisible, next hit 10x!", Color(0.4, 0.0, 0.6))
		2: # Shadow Realm — ALL enemies take 800dmg, shadowblade teleports between each one
			var enemies : Array = []
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) < 40.0:
						enemies.append(z)
			var delay := 0.0
			for e in enemies:
				var captured_e : Node3D = e as Node3D
				get_tree().create_timer(delay).timeout.connect(func():
					if is_instance_valid(captured_e):
						var ce_pos : Vector3 = (captured_e as Node3D).global_position
						_vfx_beam(global_position, ce_pos, Color(0.4, 0.0, 0.7), 0.25)
						global_position = ce_pos + Vector3(0, 0.5, 0)
						if captured_e.has_method("take_damage"): captured_e.take_damage(800.0, self)
						_vfx_burst(global_position, Color(0.3, 0.0, 0.5, 0.9), 15)
					, CONNECT_ONE_SHOT)
				delay += 0.07
			_vfx_ring(global_position, Color(0.5, 0.0, 0.9), 20.0, 0.8)
			_vfx_light_pulse(global_position, Color(0.4, 0.0, 0.7), 0.5)
			_show_message("🌑 SHADOW REALM — %d targets!" % enemies.size(), Color(0.6, 0.0, 1.0))
		3: # Blur — blink 10m in look direction, instant and silent
			_ghost_timer = maxf(_ghost_timer, 0.4)
			_vfx_burst(global_position, Color(0.2, 0.0, 0.4, 0.8), 15)
			_class_teleport(10.0)
			_vfx_burst(global_position, Color(0.3, 0.0, 0.5, 0.9), 15)
			_show_message("🌑 BLUR — vanished!", Color(0.4, 0.0, 0.6))


# ============================================================
# 5. STORMCALLER — lightning chains, storm surge, thundergod
# ============================================================
func _ability_stormcaller(slot: int) -> void:
	match slot:
		0: # Chain Lightning — electric bolt projectile, chains to 4 nearby enemies on hit
			_storm_charges += 3
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 150.0, "speed": 28.0, "radius": 1.0, "ttl": 2.5,
				"pierce": false,
				"col": Color(1.0, 1.0, 0.1),
				"mesh_color": Color(0.9, 0.95, 0.1),
				"mesh_radius": 0.25,
				"on_hit": func(hit_node, _hp):
					var chained : Array = [hit_node]
					var corigin : Vector3 = (hit_node as Node3D).global_position if hit_node is Node3D else global_position
					for _ci in 4:
						var cbest : Node3D = null; var cbd : float = INF
						for cgrp in ["zombies", "units", "players"]:
							for cz in get_tree().get_nodes_in_group(cgrp):
								if not is_instance_valid(cz) or not (cz is Node3D): continue
								if cz in chained: continue
								if "team_id" in cz and int(cz.get("team_id")) == team_id: continue
								var cd := corigin.distance_to((cz as Node3D).global_position)
								if cd < 8.0 and cd < cbd: cbd = cd; cbest = cz as Node3D
						if not is_instance_valid(cbest): break
						if cbest.has_method("take_damage"): cbest.take_damage(100.0, self)
						_vfx_beam(corigin, cbest.global_position, Color(1.0, 1.0, 0.15), 0.3)
						_vfx_light_pulse(cbest.global_position, Color(1.0, 0.9, 0.1), 0.2)
						chained.append(cbest)
						corigin = cbest.global_position
			})
			_vfx_burst(from, Color(1.0, 0.95, 0.1), 10)
			_vfx_light_pulse(from, Color(1.0, 1.0, 0.0), 0.2)
			_show_message("⚡ CHAIN LIGHTNING — bolt fires, chains to 4!", Color(1.0, 0.95, 0.1))
		1: # Storm Surge — targeted storm zone: 20 lightning bolts over 10s
			var tpos := _ability_target_pos
			_vfx_ring(tpos, Color(1.0, 1.0, 0.1), 10.0, 0.5)
			_vfx_burst(tpos, Color(1.0, 0.95, 0.1), 30)
			_vfx_light_pulse(tpos, Color(1.0, 1.0, 0.0), 0.5)
			var _ss_t := 0.0
			for _ss_i in 20:
				var _ss_cap := _ss_t
				get_tree().create_timer(_ss_cap).timeout.connect(func():
					_do_storm_bolt(tpos), CONNECT_ONE_SHOT)
				_ss_t += 0.5
			_show_message("⚡ STORM SURGE — 20 bolts over 10s at target!", Color(1.0, 0.95, 0.1))
		2: # Thundergod — massive sky strike at target: 600 dmg in 12m + 5 storm bolts
			var tpos := _ability_target_pos
			_vfx_sky_strike(tpos, Color(1.0, 1.0, 0.1), 12.0, 0.8, func():
				for grp in ["zombies", "units", "players"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if tpos.distance_to((z as Node3D).global_position) <= 12.0:
							if z.has_method("take_damage"): z.take_damage(600.0, self)
				for _tg_i in 5:
					_do_storm_bolt(tpos)
			)
			_show_message("⚡ THUNDERGOD — divine lightning strike!", Color(1.0, 1.0, 0.0))
		3: # Skyfall — rocket upward then slam down with AOE shockwave
			velocity.y = 22.0
			velocity.x *= 0.3; velocity.z *= 0.3
			_vfx_ring(global_position, Color(1.0, 0.95, 0.1), 4.0, 0.4)
			get_tree().create_timer(0.9).timeout.connect(func():
				velocity.y = -35.0
				get_tree().create_timer(0.35).timeout.connect(func():
					_class_dash(0.0, 0.0, 7.0, 220.0)
					_vfx_ring(global_position, Color(1.0, 1.0, 0.1), 10.0, 0.7)
					_vfx_burst(global_position, Color(1.0, 0.95, 0.1), 50)
					_vfx_light_pulse(global_position, Color(1.0, 1.0, 0.0), 0.6)
					, CONNECT_ONE_SHOT)
				, CONNECT_ONE_SHOT)
			if is_instance_valid(animation_tree):
				animation_tree.set(ANIM_JUMP, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			_show_message("⚡ SKYFALL — prepare for impact!", Color(1.0, 0.95, 0.1))


# ============================================================
# 6. BLOODMAGE — spend HP for power, lifesteal, hemomancy
# ============================================================
func _ability_bloodmage(slot: int) -> void:
	match slot:
		0: # Blood Bolt — spend 20hp, fire piercing blood orb (250 dmg + 30hp lifesteal per hit)
			if health <= 25.0: _show_message("Not enough HP", Color(1.0, 0.3, 0.3)); return
			health -= 20.0; health_changed.emit(health, max_health)
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 250.0, "speed": 22.0, "radius": 1.0, "ttl": 3.0,
				"pierce": true,
				"col": Color(0.9, 0.0, 0.15),
				"mesh_color": Color(0.85, 0.0, 0.1),
				"mesh_radius": 0.30,
				"on_hit": func(_bz, _bp):
					health = minf(health + 30.0, max_health)
					health_changed.emit(health, max_health),
			})
			_vfx_burst(from, Color(0.9, 0.0, 0.15), 12)
			_vfx_light_pulse(from, Color(0.8, 0.0, 0.1), 0.2)
			_show_message("🩸 BLOOD BOLT — piercing! Heals 30hp per hit", Color(0.8, 0.0, 0.2))
		1: # Crimson Pact — for 15s: sword heals 80% of damage dealt
			_blood_hp_spent = 15.0
			_vfx_ring(global_position, Color(0.8, 0.0, 0.15), 5.0, 0.5)
			_vfx_light_pulse(global_position, Color(0.9, 0.0, 0.1), 0.5)
			_show_message("🩸 CRIMSON PACT — 15s lifesteal 80%!", Color(0.8, 0.0, 0.2))
		2: # Hemorrhage — sacrifice 50% HP, deal that amount × 10 to ALL enemies in 30m
			var sacrifice := health * 0.5
			health -= sacrifice; health_changed.emit(health, max_health)
			var dmg := sacrifice * 10.0
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) > 30.0: continue
					if z.has_method("take_damage"): z.take_damage(dmg, self)
			_vfx_ring(global_position, Color(0.9, 0.0, 0.1), 20.0, 0.8)
			_vfx_burst(global_position, Color(0.9, 0.0, 0.15), 50, 1.0)
			_vfx_light_pulse(global_position, Color(1.0, 0.0, 0.1), 0.7)
			_show_message("🩸 HEMORRHAGE — dealt %.0fdmg!" % dmg, Color(1.0, 0.0, 0.0))
		3: # Blood Surge — dash trailing a blood slick that damages enemies in path
			_blood_hp_spent = maxf(_blood_hp_spent, 3.0)  # brief lifesteal after dash
			_vfx_ring(global_position, Color(0.8, 0.0, 0.15), 3.0, 0.3)
			_vfx_burst(global_position, Color(0.9, 0.0, 0.15), 15)
			_class_dash(11.0, 1.0, 2.5, 80.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_ring(global_position, Color(0.8, 0.0, 0.15), 4.0, 0.4)
				_vfx_burst(global_position, Color(0.9, 0.0, 0.2), 20), CONNECT_ONE_SHOT)
			_show_message("🩸 BLOOD SURGE!", Color(0.8, 0.0, 0.2))


# ============================================================
# 7. TIMEWEAVER — slow, rewind, timestop
# ============================================================
func _ability_timeweaver(slot: int) -> void:
	match slot:
		0: # Time Fracture — freeze zone at clicked target: 10m radius, 5s slow 80%
			var tpos := _ability_target_pos
			_vfx_ring(tpos, Color(0.3, 0.8, 1.0), 10.0, 0.8)
			_vfx_burst(tpos, Color(0.4, 0.85, 1.0, 0.8), 30)
			_vfx_light_pulse(tpos, Color(0.3, 0.8, 1.0), 0.6)
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if tpos.distance_to((z as Node3D).global_position) > 10.0: continue
					if z.has_method("apply_status"): z.apply_status(5, 5.0, 0.8)
			_show_message("⏳ TIME FRACTURE — zone frozen at target!", Color(0.3, 0.8, 1.0))
		1: # Rewind — restore your HP to what it was 10s ago (store snapshot)
			var old_hp := health
			health = minf(max_health, old_hp + 60.0)
			health_changed.emit(health, max_health)
			_vfx_burst(global_position, Color(0.3, 0.8, 1.0), 25)
			_vfx_ring(global_position, Color(0.4, 0.9, 1.0), 4.0, 0.5)
			_vfx_light_pulse(global_position, Color(0.3, 0.8, 1.0), 0.5)
			_show_message("⏳ REWIND — HP restored!", Color(0.3, 0.8, 1.0))
		2: # TIMESTOP — freeze EVERYTHING for 6s (Engine.time_scale trick + exclude self)
			_vfx_ring(global_position, Color(0.8, 0.95, 1.0), 30.0, 0.3)
			_vfx_burst(global_position, Color(0.9, 1.0, 1.0), 60, 0.3)
			_vfx_light_pulse(global_position, Color(0.8, 1.0, 1.0), 0.3)
			Engine.time_scale = 0.0
			_time_slow_timer  = 6.0
			# create_timer 4th arg = ignore_time_scale so it fires even at time_scale 0
			get_tree().create_timer(6.0, true, false, true).timeout.connect(func():
				Engine.time_scale = 1.0
				_time_slow_timer  = 0.0
				_show_message("⏳ Time resumes", Color(0.3, 0.8, 1.0)), CONNECT_ONE_SHOT)
			_show_message("⏳ TIMESTOP — 6 SECONDS FROZEN!", Color(0.5, 0.9, 1.0))
		3: # Chrono Dash — teleport forward 12m, leave a time echo at origin that explodes after 2s
			var echo_pos := global_position
			_vfx_ring(echo_pos, Color(0.3, 0.8, 1.0), 3.0, 0.4)
			_vfx_burst(echo_pos, Color(0.4, 0.8, 1.0, 0.8), 15)
			_class_teleport(12.0)
			_vfx_burst(global_position, Color(0.3, 0.8, 1.0, 0.8), 15)
			get_tree().create_timer(2.0).timeout.connect(func():
				_vfx_ring(echo_pos, Color(0.5, 0.9, 1.0), 8.0, 0.5)
				_vfx_burst(echo_pos, Color(0.3, 0.8, 1.0), 35)
				_vfx_light_pulse(echo_pos, Color(0.3, 0.8, 1.0), 0.5)
				for grp in ["zombies", "units", "players", "hive_unit"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if echo_pos.distance_to((z as Node3D).global_position) <= 6.0:
							if z.has_method("take_damage"): z.take_damage(200.0, self)
				, CONNECT_ONE_SHOT)
			_show_message("⏳ CHRONO DASH — echo in 2s!", Color(0.3, 0.8, 1.0))

func _tick_timeweaver(_delta: float) -> void:
	pass  # Timestop resume handled by create_timer(ignore_time_scale=true) in slot 2


# ============================================================
# 8. VOIDWALKER — phase, rifts, annihilation
# ============================================================
func _ability_voidwalker(slot: int) -> void:
	match slot:
		0: # Phase Shift — 3s untouchable, sword hits from void deal 2x
			_ghost_timer = 3.0
			_double_damage_timer = 3.0
			_vfx_ring(global_position, Color(0.25, 0.0, 0.45), 5.0, 0.5)
			_vfx_burst(global_position, Color(0.2, 0.0, 0.4, 0.9), 25)
			_vfx_light_pulse(global_position, Color(0.3, 0.0, 0.5), 0.5)
			_show_message("🌀 PHASE SHIFT — 3s void form", Color(0.3, 0.0, 0.5))
		1: # Void Rift — void zone at target: pulls + 100 dmg/0.5s for 3s, explodes for 500
			var rift_pos := _ability_target_pos
			_vfx_ring(rift_pos, Color(0.2, 0.0, 0.4), 6.0, 0.5)
			_vfx_burst(rift_pos, Color(0.15, 0.0, 0.35, 0.9), 20)
			_vfx_light_pulse(rift_pos, Color(0.25, 0.0, 0.45), 0.4)
			for _vr_i in 6:
				var _vr_d := float(_vr_i) * 0.5
				get_tree().create_timer(_vr_d).timeout.connect(func():
					_vfx_ring(rift_pos, Color(0.3, 0.0, 0.5, 0.5), 5.0, 0.3)
					for grp in ["zombies", "units", "players"]:
						for z in get_tree().get_nodes_in_group(grp):
							if not is_instance_valid(z) or not (z is Node3D): continue
							if "team_id" in z and int(z.get("team_id")) == team_id: continue
							if rift_pos.distance_to((z as Node3D).global_position) < 8.0:
								if z.has_method("take_damage"): z.take_damage(100.0, self)
								var pull_dir := (rift_pos - (z as Node3D).global_position).normalized()
								(z as Node3D).global_position += pull_dir * 1.5
				, CONNECT_ONE_SHOT)
			get_tree().create_timer(3.0).timeout.connect(func():
				_vfx_ring(rift_pos, Color(0.4, 0.0, 0.8), 12.0, 0.6)
				_vfx_burst(rift_pos, Color(0.3, 0.0, 0.6), 50)
				_vfx_light_pulse(rift_pos, Color(0.4, 0.0, 0.7), 0.6)
				for grp in ["zombies", "units", "players"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if rift_pos.distance_to((z as Node3D).global_position) < 10.0:
							if z.has_method("take_damage"): z.take_damage(500.0, self)
			, CONNECT_ONE_SHOT)
			_show_message("🌀 VOID RIFT — pulls + 100dmg/0.5s, explodes after 3s!", Color(0.3, 0.0, 0.5))
		2: # Annihilation — you become pure void for 5s: every sword swing deletes target instantly
			_ghost_timer = 5.0
			_void_rifts.append(5.0) # flag for instant-kill on swing
			_vfx_ring(global_position, Color(0.3, 0.0, 0.6), 8.0, 0.6)
			_vfx_burst(global_position, Color(0.2, 0.0, 0.5, 0.9), 40)
			_vfx_light_pulse(global_position, Color(0.4, 0.0, 0.7), 0.8)
			get_tree().create_timer(5.0).timeout.connect(func():
				_void_rifts.clear()
				_show_message("Void ended", Color(0.3, 0.0, 0.5)), CONNECT_ONE_SHOT)
			_show_message("🌀 ANNIHILATION — 5s INSTANT KILL SWORD!", Color(0.5, 0.0, 1.0))
		3: # Void Step — phase-teleport 14m, passing through geometry
			_ghost_timer = maxf(_ghost_timer, 0.5)
			_vfx_burst(global_position, Color(0.2, 0.0, 0.4, 0.8), 20)
			_class_teleport(14.0, 2.5, 60.0)
			_vfx_ring(global_position, Color(0.3, 0.0, 0.6), 5.0, 0.4)
			_vfx_burst(global_position, Color(0.25, 0.0, 0.5, 0.9), 20)
			_vfx_light_pulse(global_position, Color(0.3, 0.0, 0.5), 0.4)
			_show_message("🌀 VOID STEP — phased!", Color(0.3, 0.0, 0.5))


# ============================================================
# 9. IRONCLAD — armor, taunt, unstoppable
# ============================================================
func _ability_ironclad(slot: int) -> void:
	match slot:
		0: # Iron Skin — +200 max HP for 10s, absorb next 3 hits
			max_health += 200.0; health += 200.0
			health_changed.emit(health, max_health)
			_iron_stacks = 3
			_vfx_ring(global_position, Color(0.7, 0.75, 0.8), 5.0, 0.5)
			_vfx_burst(global_position, Color(0.75, 0.8, 0.85), 30)
			_vfx_light_pulse(global_position, Color(0.8, 0.85, 0.9), 0.6)
			get_tree().create_timer(10.0).timeout.connect(func():
				max_health -= 200.0; health = minf(health, max_health)
				health_changed.emit(health, max_health); _iron_stacks = 0, CONNECT_ONE_SHOT)
			_show_message("🛡 IRON SKIN — +200HP, 3 hit absorb!", Color(0.7, 0.7, 0.7))
		1: # Taunt — ALL enemies switch target to you for 8s
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if "target" in z: z.set("target", self)
			_shield_timer = 8.0
			_vfx_ring(global_position, Color(0.9, 0.1, 0.0), 25.0, 0.8)
			_vfx_light_pulse(global_position, Color(1.0, 0.15, 0.0), 0.6)
			_show_message("🛡 TAUNT — ALL enemies target you (shielded)!", Color(0.7, 0.7, 0.7))
		2: # UNSTOPPABLE — 10s: immune to all damage, knockback, and stun. Sword deals 1000dmg flat.
			_shield_timer = 10.0
			_iron_stacks = 999
			_double_damage_timer = 10.0
			_vfx_ring(global_position, Color(0.85, 0.9, 1.0), 10.0, 0.7)
			_vfx_burst(global_position, Color(0.8, 0.85, 0.9), 50, 1.0)
			_vfx_light_pulse(global_position, Color(0.9, 0.95, 1.0), 1.0)
			get_tree().create_timer(10.0).timeout.connect(func():
				_iron_stacks = 0, CONNECT_ONE_SHOT)
			_show_message("🛡 UNSTOPPABLE — 10s UNKILLABLE + 1000dmg sword!", Color(0.9, 0.9, 1.0))
		3: # Shield Slam — charge forward, smash through enemies, stun on impact
			_shield_timer = maxf(_shield_timer, 0.5)
			_vfx_ring(global_position, Color(0.7, 0.75, 0.8), 3.0, 0.3)
			_class_dash(15.0, 0.5, 4.0, 150.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_ring(global_position, Color(0.75, 0.8, 0.9), 6.0, 0.5)
				_vfx_burst(global_position, Color(0.8, 0.85, 0.9), 30)
				_vfx_light_pulse(global_position, Color(0.8, 0.85, 0.95), 0.4), CONNECT_ONE_SHOT)
			_show_message("🛡 SHIELD SLAM — HOLD THE LINE!", Color(0.7, 0.7, 0.9))


# ============================================================
# 10. PLAGUEMASTER — disease, infection, pandemic
# ============================================================
func _ability_plaguemaster(slot: int) -> void:
	match slot:
		0: # Infect — plague orb projectile: infects target + spreads to 3 nearby on hit
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 80.0, "speed": 20.0, "radius": 1.0, "ttl": 3.0,
				"pierce": false,
				"col": Color(0.1, 0.9, 0.1),
				"mesh_color": Color(0.05, 0.85, 0.05),
				"mesh_radius": 0.22,
				"on_hit": func(hit_node, hit_pos):
					if hit_node is Node3D: _vfx_cloud_on_node(hit_node as Node3D, Color(0.1, 0.9, 0.1, 0.7), 10.0)
					var spread := 0
					for igrp in ["zombies", "units", "players"]:
						for iz in get_tree().get_nodes_in_group(igrp):
							if spread >= 3: break
							if not is_instance_valid(iz) or not (iz is Node3D): continue
							if iz == hit_node: continue
							if "team_id" in iz and int(iz.get("team_id")) == team_id: continue
							if hit_pos.distance_to((iz as Node3D).global_position) < 6.0:
								if iz.has_method("take_damage"): iz.take_damage(60.0, self)
								_vfx_beam(hit_pos, (iz as Node3D).global_position, Color(0.1, 0.9, 0.1), 0.3)
								_vfx_cloud_on_node(iz as Node3D, Color(0.1, 0.9, 0.1, 0.7), 10.0)
								spread += 1
			})
			_vfx_burst(from, Color(0.1, 0.9, 0.1), 10)
			_vfx_light_pulse(from, Color(0.0, 0.8, 0.0), 0.2)
			_show_message("☠ INFECT — plague bolt, spreads to 3 nearby!", Color(0.2, 0.8, 0.1))
		1: # Plague Cloud — place persistent toxic cloud at clicked location for 8s
			_plague_cloud_pos   = _ability_target_pos
			_plague_cloud_timer = 8.0
			_plague_dps_accum   = 0.0
			_vfx_ring(_plague_cloud_pos, Color(0.1, 0.85, 0.1), 5.0, 0.5)
			_vfx_burst(_plague_cloud_pos, Color(0.1, 0.9, 0.1, 0.8), 25)
			_vfx_light_pulse(_plague_cloud_pos, Color(0.0, 0.8, 0.0), 0.5)
			_show_message("☠ PLAGUE CLOUD — 8s toxic field at target!", Color(0.2, 0.8, 0.1))
		2: # PANDEMIC — every enemy on map takes damage every 1s for 30s
			_pandemic_timer     = 30.0
			_pandemic_dps_accum = 0.0
			var _pandemic_count := 0
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if z.has_method("take_damage"): z.take_damage(80.0, self) # initial hit
					if z is Node3D:
						_vfx_cloud_on_node(z as Node3D, Color(0.05, 0.9, 0.05, 0.8), 15.0)
					_pandemic_count += 1
			_vfx_ring(global_position, Color(0.0, 1.0, 0.0), 50.0, 1.5)
			_vfx_burst(global_position, Color(0.1, 0.9, 0.1), 50, 1.2)
			_vfx_light_pulse(global_position, Color(0.0, 0.9, 0.0), 0.8)
			_show_message("☠ PANDEMIC — %d enemies infected for 30s!" % _pandemic_count, Color(0.0, 1.0, 0.0))
		3: # Spore Burst — dash and release spores that poison all nearby enemies for 15s
			_vfx_ring(global_position, Color(0.1, 0.85, 0.1), 3.0, 0.3)
			_vfx_burst(global_position, Color(0.1, 0.9, 0.1, 0.8), 20)
			_class_dash(10.0, 1.0, 5.0, 30.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_ring(global_position, Color(0.1, 0.85, 0.1), 5.0, 0.5)
				_vfx_burst(global_position, Color(0.1, 0.9, 0.1, 0.8), 30)
				for grp in ["zombies", "units", "players", "hive_unit"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if global_position.distance_to((z as Node3D).global_position) <= 6.0:
							if z.has_method("take_damage"): z.take_damage(80.0, self) # spore hit
							if z.has_method("apply_status"): z.apply_status(6, 15.0, 20.0)
							_vfx_cloud_on_node(z as Node3D, Color(0.1, 0.9, 0.1, 0.7), 8.0)
				, CONNECT_ONE_SHOT)
			_show_message("☠ SPORE BURST — spreading plague!", Color(0.2, 0.8, 0.1))

func _tick_plaguemaster(delta: float) -> void:
	if _plague_cloud_timer > 0.0:
		_plague_cloud_timer -= delta
		_plague_dps_accum   += delta
		if _plague_dps_accum >= 0.5:
			_plague_dps_accum -= 0.5
			_vfx_ring(_plague_cloud_pos, Color(0.1, 0.85, 0.1, 0.55), 4.5, 0.4)
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if _plague_cloud_pos.distance_to((z as Node3D).global_position) < 6.0:
						if z.has_method("take_damage"): z.take_damage(40.0, self)
						_vfx_cloud_on_node(z as Node3D, Color(0.1, 0.9, 0.1, 0.7), 0.6)

	# Pandemic — map-wide infection ticks every 1s for 30s
	if _pandemic_timer > 0.0:
		_pandemic_timer     -= delta
		_pandemic_dps_accum += delta
		if _pandemic_dps_accum >= 1.0:
			_pandemic_dps_accum -= 1.0
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if z.has_method("take_damage"): z.take_damage(40.0, self)
					if z is Node3D:
						_vfx_cloud_on_node(z as Node3D, Color(0.05, 0.9, 0.05, 0.6), 1.2)


# ============================================================
# 11. SOULREAPER — collect souls, execute, soul bomb
# ============================================================
func _ability_soulreaper(slot: int) -> void:
	match slot:
		0: # Soul Harvest — collect souls of dead nearby, each = +15hp
			var gained := 0
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z): continue
					# Use health <= 0 instead of .get("is_dead") -- some nodes expose
					# is_dead() as a method, so Object.get() returns a Callable and
					# Callable == true throws an invalid-operands error.
					if "health" in z and float(z.get("health")) <= 0.0:
						health = minf(health + 15.0, max_health); gained += 1
						_soul_count += 1
						if z is Node3D:
							_vfx_beam((z as Node3D).global_position, global_position,
								Color(0.6, 0.0, 0.85), 0.5)
			health_changed.emit(health, max_health)
			_vfx_burst(global_position, Color(0.6, 0.0, 0.85, 0.9), 20)
			_vfx_light_pulse(global_position, Color(0.5, 0.0, 0.7), 0.5)
			_show_message("💀 SOUL HARVEST — %d souls, +%dhp" % [_soul_count, gained * 15], Color(0.6, 0.0, 0.8))
		1: # Execute — spectral bolt projectile: 300 dmg, +900 bonus vs <30% HP targets
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 300.0, "speed": 25.0, "radius": 1.0, "ttl": 3.0,
				"pierce": false,
				"col": Color(0.7, 0.0, 1.0),
				"mesh_color": Color(0.6, 0.0, 0.9),
				"mesh_radius": 0.28,
				"on_hit": func(ez, ep):
					if "health" in ez and "max_health" in ez:
						if float(ez.get("health")) / float(ez.get("max_health")) < 0.30:
							if ez.has_method("take_damage"): ez.take_damage(900.0, self)
							_vfx_beam(ep, ep + Vector3.UP * 5.0, Color(0.7, 0.0, 1.0), 0.5)
					# Same safe check -- avoid .get("is_dead") returning a Callable.
					if "health" in ez and float(ez.get("health")) <= 0.0:
						_soul_count += 1
						health = minf(health + 15.0, max_health)
						health_changed.emit(health, max_health),
			})
			_vfx_burst(from, Color(0.7, 0.0, 1.0), 12)
			_vfx_light_pulse(from, Color(0.6, 0.0, 0.85), 0.2)
			_show_message("💀 EXECUTE — spectral bolt! +900 dmg vs <30% HP!", Color(0.6, 0.0, 0.8))
		2: # Soul Bomb — detonate all collected souls: 200dmg × soul_count in 25m
			var dmg := _soul_count * 200.0
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) > 25.0: continue
					if z.has_method("take_damage"): z.take_damage(dmg, self)
			_vfx_ring(global_position, Color(0.7, 0.0, 1.0), 18.0, 0.7)
			_vfx_burst(global_position, Color(0.6, 0.0, 0.9), 50, 1.0)
			_vfx_light_pulse(global_position, Color(0.7, 0.0, 1.0), 0.8)
			_show_message("💀 SOUL BOMB — %d souls × 200 = %.0f dmg!" % [_soul_count, dmg], Color(0.8, 0.0, 1.0))
			_soul_count = 0
		3: # Wraith Glide — ghost dash: fast silent teleport 16m, collect souls along path
			_ghost_timer = maxf(_ghost_timer, 0.8)
			_vfx_ring(global_position, Color(0.5, 0.0, 0.8, 0.7), 3.0, 0.35)
			_vfx_burst(global_position, Color(0.55, 0.0, 0.8, 0.8), 15)
			_class_dash(16.0, 2.0)
			_soul_count += 1  # bonus soul for the dash
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_burst(global_position, Color(0.55, 0.0, 0.8, 0.8), 15), CONNECT_ONE_SHOT)
			_show_message("💀 WRAITH GLIDE — claimed a soul!", Color(0.6, 0.0, 0.8))


# ============================================================
# 12. WARLOCK — pact damage, curse, demon form
# ============================================================
func _ability_warlock(slot: int) -> void:
	match slot:
		0: # Hex — curse orb projectile: 200 dmg + chains curse to enemies within 6m on hit
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 200.0, "speed": 20.0, "radius": 1.0, "ttl": 3.0,
				"pierce": false,
				"col": Color(0.55, 0.0, 0.85),
				"mesh_color": Color(0.5, 0.0, 0.8),
				"mesh_radius": 0.25,
				"on_hit": func(hz, hp):
					if hz.has_method("apply_status"): hz.apply_status(7, 8.0, 2.0)
					for hgrp in ["zombies", "units", "players"]:
						for cz in get_tree().get_nodes_in_group(hgrp):
							if not is_instance_valid(cz) or not (cz is Node3D): continue
							if cz == hz: continue
							if "team_id" in cz and int(cz.get("team_id")) == team_id: continue
							if hp.distance_to((cz as Node3D).global_position) < 6.0:
								if cz.has_method("take_damage"): cz.take_damage(100.0, self)
								if cz.has_method("apply_status"): cz.apply_status(7, 4.0, 2.0)
								_vfx_beam(hp, (cz as Node3D).global_position, Color(0.55, 0.0, 0.85), 0.3)
			})
			_vfx_burst(from, Color(0.55, 0.0, 0.85), 10)
			_vfx_light_pulse(from, Color(0.5, 0.0, 0.8), 0.2)
			_show_message("🔮 HEX — curse orb, chains to nearby enemies!", Color(0.6, 0.0, 0.9))
		1: # Dark Pact — sacrifice 30hp per second for 10s, but deal 500% damage
			_warlock_pact_hp = 10.0
			_double_damage_timer = 10.0
			_berserk_timer = 10.0
			_vfx_ring(global_position, Color(0.5, 0.0, 0.8), 5.0, 0.5)
			_vfx_burst(global_position, Color(0.6, 0.0, 0.9, 0.9), 25)
			_vfx_light_pulse(global_position, Color(0.55, 0.0, 0.85), 0.6)
			_show_message("🔮 DARK PACT — 10s 500% damage (costs HP/s)!", Color(0.6, 0.0, 0.9))
		2: # Demon Form — 12s: become a demon. Double size, 10x damage, fear aura kills on contact
			_shield_timer = 12.0
			_berserk_timer = 12.0
			_double_damage_timer = 12.0
			_sprint_boost_timer = 12.0
			# Fear: nearby enemies run away (set target to null, flee)
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) < 15.0:
						if "target" in z: z.set("target", null)
			_vfx_ring(global_position, Color(0.6, 0.0, 1.0), 12.0, 0.7)
			_vfx_burst(global_position, Color(0.55, 0.0, 0.9), 50, 1.0)
			_vfx_light_pulse(global_position, Color(0.65, 0.0, 1.0), 1.0)
			_show_message("🔮 DEMON FORM — 12s 10x DAMAGE + FEAR AURA!", Color(0.8, 0.0, 1.0))
		3: # Hellbolt Jump — fire a blast downward, rocket-jumping forward
			velocity.y = maxf(velocity.y, 0.0) + 16.0
			_vfx_ring(global_position, Color(0.9, 0.3, 0.0), 4.0, 0.3)
			_vfx_burst(global_position + Vector3.DOWN * 0.5, Color(1.0, 0.4, 0.0), 25)
			_vfx_light_pulse(global_position, Color(1.0, 0.3, 0.0), 0.3)
			_class_dash(10.0, 0.0, 4.0, 100.0)
			if is_instance_valid(animation_tree):
				animation_tree.set(ANIM_JUMP, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			get_tree().create_timer(0.35).timeout.connect(func():
				_vfx_burst(global_position, Color(1.0, 0.4, 0.0), 20), CONNECT_ONE_SHOT)
			_show_message("🔮 HELLBOLT JUMP!", Color(0.6, 0.0, 0.9))


# ============================================================
# 13. PHOENIX — rebirth, fire trail, supernova
# ============================================================
func _ability_phoenix(slot: int) -> void:
	match slot:
		0: # Phoenix Bolt — blazing fire orb: 350 dmg + leaves a 5s static fire zone on impact
			var dir := _get_aim_dir()
			var from := _get_aim_origin()
			_spawn_projectile(from, dir, {
				"dmg": 350.0, "speed": 24.0, "radius": 1.0, "ttl": 3.0,
				"pierce": false,
				"col": Color(1.0, 0.5, 0.0),
				"mesh_color": Color(1.0, 0.45, 0.0),
				"mesh_radius": 0.28,
				"on_hit": func(_pz, pp):
					_phoenix_flame_pos   = pp
					_phoenix_flame_timer = 5.0
					_phoenix_dps_accum   = 0.0
					_vfx_ring(pp, Color(1.0, 0.4, 0.0), 6.0, 0.5)
					_vfx_burst(pp, Color(1.0, 0.5, 0.0), 30)
					_vfx_light_pulse(pp, Color(1.0, 0.4, 0.0), 0.5),
				"on_expire": func(ep):
					_phoenix_flame_pos   = ep
					_phoenix_flame_timer = 5.0
					_phoenix_dps_accum   = 0.0
					_vfx_ring(ep, Color(1.0, 0.4, 0.0), 6.0, 0.5)
					_vfx_burst(ep, Color(1.0, 0.5, 0.0), 15),
			})
			_show_message("🔥 PHOENIX BOLT — blazing impact!", Color(1.0, 0.4, 0.0))
		1: # Rebirth — if you die in next 20s, revive at full HP (passive on timer)
			_phoenix_dead = false
			_phoenix_timer = 20.0
			_phoenix_dps_accum = 0.0
			_vfx_ring(global_position, Color(1.0, 0.85, 0.2), 5.0, 0.6)
			_vfx_burst(global_position, Color(1.0, 0.75, 0.1), 30)
			_vfx_light_pulse(global_position, Color(1.0, 0.8, 0.15), 0.7)
			_show_message("🔥 REBIRTH — next death auto-revives!", Color(1.0, 0.4, 0.0))
		2: # SUPERNOVA — sky strike at target: 1500 dmg in 18m, you survive at 1hp
			var tpos := _ability_target_pos
			health = 1.0
			health_changed.emit(health, max_health)
			_vfx_sky_strike(tpos, Color(1.0, 0.55, 0.0), 18.0, 0.8, func():
				for grp in ["zombies", "units", "players"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if tpos.distance_to((z as Node3D).global_position) <= 18.0:
							if z.has_method("take_damage"): z.take_damage(1500.0, self)
			)
			_show_message("🔥 SUPERNOVA — 1500 dmg sky strike! You survive at 1hp!", Color(1.0, 0.6, 0.0))
		3: # Blazing Dash — dash forward in flames, creates a 3s fire zone at landing
			_vfx_ring(global_position, Color(1.0, 0.5, 0.0), 3.0, 0.3)
			_vfx_burst(global_position, Color(1.0, 0.45, 0.0, 0.8), 15)
			_class_dash(13.0, 3.0, 3.5, 90.0)
			# Capture landing position after dash settles
			get_tree().create_timer(0.3).timeout.connect(func():
				_phoenix_flame_pos   = global_position
				_phoenix_flame_timer = maxf(_phoenix_flame_timer, 3.0)
				_phoenix_dps_accum   = 0.0
				_vfx_ring(global_position, Color(1.0, 0.5, 0.0), 5.0, 0.4)
				_vfx_burst(global_position, Color(1.0, 0.45, 0.0), 25), CONNECT_ONE_SHOT)
			_show_message("🔥 BLAZING DASH — fire zone on landing!", Color(1.0, 0.4, 0.0))

func _tick_phoenix(delta: float) -> void:
	# Rebirth buff timer countdown
	if _phoenix_timer > 0.0:
		_phoenix_timer -= delta
	# Static fire zone from Phoenix Bolt impact or Blazing Dash landing
	if _phoenix_flame_timer > 0.0:
		_phoenix_flame_timer -= delta
		_phoenix_dps_accum   += delta
		if _phoenix_dps_accum >= 0.5:
			_phoenix_dps_accum -= 0.5
			_vfx_ring(_phoenix_flame_pos, Color(1.0, 0.5, 0.0, 0.55), 4.0, 0.4)
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if _phoenix_flame_pos.distance_to((z as Node3D).global_position) < 4.0:
						if z.has_method("take_damage"): z.take_damage(40.0, self)
						_vfx_burst((z as Node3D).global_position,
							Color(1.0, 0.4, 0.0, 0.8), 8, 0.4)


# ============================================================
# 14. GRAVEMIND — control ALL undead, hive mind, singularity
# ============================================================
func _ability_gravemind(slot: int) -> void:
	match slot:
		0: # Dominate — take permanent control of target enemy unit
			var best : Node3D = null; var bd : float = INF
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					var d := global_position.distance_to((z as Node3D).global_position)
					if d < 30.0 and d < bd: bd = d; best = z as Node3D
			if is_instance_valid(best) and best.has_method("convert_team"):
				best.call("convert_team")
				_gravemind_puppets.append(best)
				_vfx_beam(global_position, best.global_position, Color(0.5, 0.85, 0.2), 0.6)
				_vfx_ring(best.global_position, Color(0.4, 0.8, 0.15), 2.5)
				_vfx_light_pulse(best.global_position, Color(0.45, 0.8, 0.2), 0.5)
				_show_message("🧠 DOMINATED — permanent puppet!", Color(0.5, 0.8, 0.2))
		1: # Hive Mind — all friendly undead gain +100% damage and speed for 15s
			for grp in ["zombies", "units"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z): continue
					if "team_id" in z and int(z.get("team_id")) != team_id: continue
					if z.has_method("apply_status"): z.apply_status(7, 15.0, 1.0)
					if "move_speed" in z: z.set("move_speed", float(z.get("move_speed")) * 2.0)
					if "damage" in z: z.set("damage", float(z.get("damage")) * 2.0)
					get_tree().create_timer(15.0).timeout.connect(func():
						if is_instance_valid(z):
							if "move_speed" in z: z.set("move_speed", float(z.get("move_speed")) / 2.0)
							if "damage" in z: z.set("damage", float(z.get("damage")) / 2.0)
						, CONNECT_ONE_SHOT)
			_vfx_ring(global_position, Color(0.5, 0.85, 0.2), 20.0, 0.8)
			_vfx_burst(global_position, Color(0.4, 0.8, 0.15), 35)
			_vfx_light_pulse(global_position, Color(0.45, 0.8, 0.2), 0.6)
			_show_message("🧠 HIVE MIND — all allies 2x stats for 15s!", Color(0.5, 0.8, 0.2))
		2: # SINGULARITY — gravity well at target: pulls + 80 dmg/0.5s for 4s, 2000 dmg finale
			var tpos := _ability_target_pos
			_vfx_ring(tpos, Color(0.3, 0.0, 0.5), 5.0, 0.5)
			_vfx_burst(tpos, Color(0.4, 0.8, 0.2, 0.9), 20)
			_vfx_light_pulse(tpos, Color(0.4, 0.75, 0.15), 0.4)
			for _sg_i in 8:
				var _sg_d := float(_sg_i) * 0.5
				get_tree().create_timer(_sg_d).timeout.connect(func():
					_vfx_ring(tpos, Color(0.3, 0.0, 0.5, 0.5), 8.0, 0.3)
					for grp in ["zombies", "units", "players", "hive_unit"]:
						for z in get_tree().get_nodes_in_group(grp):
							if not is_instance_valid(z) or not (z is Node3D): continue
							if "team_id" in z and int(z.get("team_id")) == team_id: continue
							var zdist := tpos.distance_to((z as Node3D).global_position)
							if zdist < 20.0:
								if z.has_method("take_damage"): z.take_damage(80.0, self)
								var pull_dir := (tpos - (z as Node3D).global_position).normalized()
								(z as Node3D).global_position += pull_dir * minf(zdist * 0.3, 2.0)
				, CONNECT_ONE_SHOT)
			get_tree().create_timer(4.0).timeout.connect(func():
				_vfx_ring(tpos, Color(0.5, 0.9, 0.2), 25.0, 0.9)
				_vfx_burst(tpos, Color(0.45, 0.85, 0.15), 70, 1.2)
				_vfx_light_pulse(tpos, Color(0.5, 0.9, 0.2), 0.8)
				for grp in ["zombies", "units", "players", "hive_unit"]:
					for z in get_tree().get_nodes_in_group(grp):
						if not is_instance_valid(z) or not (z is Node3D): continue
						if "team_id" in z and int(z.get("team_id")) == team_id: continue
						if tpos.distance_to((z as Node3D).global_position) <= 20.0:
							if z.has_method("take_damage"): z.take_damage(2000.0, self)
			, CONNECT_ONE_SHOT)
			_show_message("🧠 SINGULARITY — gravity well at target! 4s pull + 2000 finale!", Color(0.7, 1.0, 0.3))
		3: # Undertow — pull ALL nearby enemies to you, then rocket away in look direction
			for grp in ["zombies", "units", "players", "hive_unit"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) <= 15.0:
						(z as Node3D).global_position = global_position + Vector3(randf_range(-1,1),0,randf_range(-1,1))
			_vfx_ring(global_position, Color(0.4, 0.8, 0.15), 12.0, 0.5)
			_vfx_burst(global_position, Color(0.45, 0.8, 0.2, 0.9), 35)
			_vfx_light_pulse(global_position, Color(0.4, 0.75, 0.15), 0.5)
			get_tree().create_timer(0.2).timeout.connect(func():
				_class_dash(14.0, 6.0, 4.0, 120.0)
				get_tree().create_timer(0.3).timeout.connect(func():
					_vfx_burst(global_position, Color(0.45, 0.8, 0.2), 25), CONNECT_ONE_SHOT)
				, CONNECT_ONE_SHOT)
			_show_message("🧠 UNDERTOW — pulled all in, escaping!", Color(0.5, 0.8, 0.2))

func _tick_gravemind(_delta: float) -> void:
	_gravemind_puppets = _gravemind_puppets.filter(func(p): return is_instance_valid(p))


# ============================================================
# 15. DOOMSLAYER — rip and tear, glory kill, DOOM
# ============================================================
func _ability_doomslayer(slot: int) -> void:
	match slot:
		0: # Glory Kill — brutalize weakened enemies (<50% HP) in 8m for 750 dmg, heal 40% max HP per hit
			var hit := 0
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if global_position.distance_to((z as Node3D).global_position) > 8.0: continue
					if "health" in z and "max_health" in z:
						if float(z.get("health")) / float(z.get("max_health")) < 0.5:
							var hit_pos : Vector3 = (z as Node3D).global_position
							if z.has_method("take_damage"): z.take_damage(750.0, self)
							health = minf(health + max_health * 0.4, max_health)
							health_changed.emit(health, max_health)
							_vfx_ring(hit_pos, Color(1.0, 0.35, 0.0), 4.0, 0.4)
							_vfx_burst(hit_pos, Color(1.0, 0.3, 0.0), 25)
							_vfx_light_pulse(hit_pos, Color(1.0, 0.4, 0.0), 0.4)
							hit += 1
			if hit > 0: _show_message("💥 GLORY KILL — %d enemies hit, +%d HP!" % [hit, int(max_health * 0.4 * hit)], Color(1.0, 0.3, 0.0))
			else: _show_message("No weakened enemies in range", Color(0.6, 0.6, 0.6))
		1: # Rip and Tear — 6s berserk: each kill resets sword cooldown + heals 30hp
			_berserk_timer = 6.0
			_double_damage_timer = 6.0
			_doom_mark_target = null
			_vfx_ring(global_position, Color(1.0, 0.2, 0.0), 5.0, 0.4)
			_vfx_burst(global_position, Color(1.0, 0.25, 0.0), 25)
			_vfx_light_pulse(global_position, Color(1.0, 0.2, 0.0), 0.4)
			_show_message("💥 RIP AND TEAR — 6s KILL FRENZY!", Color(1.0, 0.3, 0.0))
		2: # HELLFIRE STORM — inferno at clicked target: 150 dmg/0.5s for 10s (3000 total)
			_doom_storm_pos   = _ability_target_pos
			_doom_storm_timer = 10.0
			_doom_storm_accum = 0.0
			_berserk_timer    = maxf(_berserk_timer, 10.0)
			_double_damage_timer = maxf(_double_damage_timer, 10.0)
			_vfx_ring(_doom_storm_pos, Color(1.0, 0.0, 0.0), 22.0, 1.0)
			_vfx_burst(_doom_storm_pos, Color(1.0, 0.05, 0.0), 60, 1.2)
			_vfx_light_pulse(_doom_storm_pos, Color(1.0, 0.0, 0.0), 1.0)
			_show_message("💥 HELLFIRE STORM — 10s inferno at target! 3000 total dmg!", Color(1.0, 0.0, 0.0))
		3: # Rip Charge — fastest dash in the game, obliterate everything in path
			_double_damage_timer = maxf(_double_damage_timer, 2.0)
			_vfx_ring(global_position, Color(1.0, 0.3, 0.0), 3.0, 0.25)
			_vfx_burst(global_position, Color(1.0, 0.25, 0.0), 20)
			_class_dash(18.0, 0.5, 4.5, 300.0)
			get_tree().create_timer(0.3).timeout.connect(func():
				_vfx_ring(global_position, Color(1.0, 0.15, 0.0), 7.0, 0.5)
				_vfx_burst(global_position, Color(1.0, 0.2, 0.0), 40)
				_vfx_light_pulse(global_position, Color(1.0, 0.1, 0.0), 0.5), CONNECT_ONE_SHOT)
			_show_message("💥 RIP CHARGE — FULL SEND!", Color(1.0, 0.0, 0.0))

func _tick_doomslayer(delta: float) -> void:
	if _doom_storm_timer > 0.0:
		_doom_storm_timer -= delta
		_doom_storm_accum += delta
		if _doom_storm_accum >= 0.5:
			_doom_storm_accum -= 0.5
			_vfx_ring(_doom_storm_pos, Color(1.0, 0.15, 0.0, 0.75), 20.0, 0.4)
			_vfx_burst(_doom_storm_pos, Color(1.0, 0.05, 0.0), 12, 0.3)
			_vfx_light_pulse(_doom_storm_pos, Color(1.0, 0.1, 0.0), 0.25)
			for grp in ["zombies", "units", "players"]:
				for z in get_tree().get_nodes_in_group(grp):
					if not is_instance_valid(z) or not (z is Node3D): continue
					if "team_id" in z and int(z.get("team_id")) == team_id: continue
					if _doom_storm_pos.distance_to((z as Node3D).global_position) < 20.0:
						if z.has_method("take_damage"): z.take_damage(150.0, self)
						_vfx_burst((z as Node3D).global_position, Color(1.0, 0.1, 0.0, 0.9), 5, 0.25)


# ============================================================
# ABILITY NAME / DESCRIPTION LOOKUP  (used by HUD)
# ============================================================
func _get_class_ability_name(slot: int) -> String:
	var tbl : Array[Array] = [
		# slot 0              slot 1              slot 2            slot 3 [4] MOVE
		["Raise Dead",   "Death Pulse",      "Undead Army",   "Spirit Walk"],    # NECROMANCER
		["War Cry",      "Bloodlust",        "Ragnarok",      "Savage Leap"],    # BERSERKER
		["Holy Smite",   "Divine Shield",    "Consecration",  "Holy Charge"],    # PALADIN
		["Shadow Step",  "Vanish",           "Shadow Realm",  "Blur"],           # SHADOWBLADE
		["Chain Lightning","Storm Surge",    "Thundergod",    "Skyfall"],        # STORMCALLER
		["Blood Bolt",   "Crimson Pact",     "Hemorrhage",    "Blood Surge"],    # BLOODMAGE
		["Time Fracture","Rewind",           "Timestop",      "Chrono Dash"],    # TIMEWEAVER
		["Phase Shift",  "Void Rift",        "Annihilation",  "Void Step"],      # VOIDWALKER
		["Iron Skin",    "Taunt",            "Unstoppable",   "Shield Slam"],    # IRONCLAD
		["Infect",       "Plague Cloud",     "Pandemic",      "Spore Burst"],    # PLAGUEMASTER
		["Soul Harvest", "Execute",          "Soul Bomb",     "Wraith Glide"],   # SOULREAPER
		["Hex",          "Dark Pact",        "Demon Form",    "Hellbolt Jump"],  # WARLOCK
		["Phoenix Bolt",  "Rebirth",          "Supernova",     "Blazing Dash"],   # PHOENIX
		["Dominate",     "Hive Mind",        "Singularity",   "Undertow"],       # GRAVEMIND
		["Glory Kill",   "Rip and Tear",     "Hellfire Storm","Rip Charge"],     # DOOMSLAYER
	]
	var idx : int = int(player_class) - 1  # PlayerClass.NONE==0, NECROMANCER==1
	if idx < 0 or idx >= tbl.size(): return "—"
	if slot < 0 or slot >= 4: return "—"
	return tbl[idx][slot]


func _get_class_ability_desc(slot: int) -> String:
	var tbl : Array[Array] = [
		# slot 0                          slot 1                        slot 2                    slot 3 MOVE
		["Convert nearest enemy\nto thrall (range 20)",
		 "120 dmg in 15m, heal\n25hp per enemy hit",
		 "Raise ALL enemies as\nthralls for 45s",
		 "Phase dash 14m,\nheal 40hp per enemy passed"],                             # NECROMANCER
		["Next 3 sword hits\ndeal 3× damage",
		 "Kills heal 50hp\nfor 12s",
		 "8s: infinite stamina,\n5× dmg, AOE on swing",
		 "Leap to target location\n5m AOE 180 dmg landing"],                         # BERSERKER
		["Sky strike at target\n350 dmg in 8m radius",
		 "Immune for 6s,\nreflect 50% damage",
		 "Holy zone at target\nheal allies + 250 dmg foes",
		 "Charge 13m, knock\n+ 120 dmg on impact"],                                  # PALADIN
		["Blink to target (25m)\n1.5s invisible on arrival",
		 "Invisible 5s,\nnext hit 10× dmg",
		 "800 dmg to all enemies\nin 40m range",
		 "Instant blink 10m\nany direction"],                                         # SHADOWBLADE
		["Projectile bolt chains\n4 enemies (150+100 dmg)",
		 "20 storm bolts over\n10s at target zone",
		 "Sky strike at target\n600 dmg in 12m + 5 bolts",
		 "Launch up, slam down\n7m AOE 220 dmg"],                                     # STORMCALLER
		["Spend 20hp: piercing\norb 250 dmg + 30hp/hit",
		 "15s lifesteal:\nheal 80% of dmg dealt",
		 "Sacrifice 50% HP,\ndeal ×10 in 30m",
		 "Dash 11m with\nblood trail damage"],                                        # BLOODMAGE
		["Freeze zone at target\n10m radius, 5s slow 80%",
		 "Restore HP to\nprevious value",
		 "Freeze everything\nfor 6 seconds",
		 "Teleport 12m, echo\nexplodes for 200 dmg"],                                # TIMEWEAVER
		["3s void form:\nuntouchable, 2× dmg",
		 "Pulls + 100dmg/0.5s\n3s then 500 dmg blast",
		 "5s: sword\ninstantly deletes targets",
		 "Phase teleport 14m,\n60 dmg on arrival"],                                  # VOIDWALKER
		["+200 max HP, absorb\nnext 3 hits (10s)",
		 "All enemies target you,\n8s shield",
		 "10s: immune, unstoppable,\n1000 flat sword dmg",
		 "Charge 15m, crush\n4m AOE 150 dmg"],                                       # IRONCLAD
		["Plague orb projectile\nspreads to 3 nearby (80 dmg)",
		 "Place toxic cloud\nat target (8s, 40dmg/0.5s)",
		 "Max-stack poison\non every enemy on map",
		 "Dash 10m, spread\nplague in 6m radius"],                                   # PLAGUEMASTER
		["Collect nearby souls,\n+15hp each",
		 "Spectral bolt 300 dmg\n+900 vs <30% HP targets",
		 "Detonate all souls:\n200 dmg × soul count",
		 "Ghost dash 16m,\ngain bonus soul"],                                        # SOULREAPER
		["Curse orb projectile\n200 dmg + chains 6m",
		 "10s: 500% damage,\ncosts 30hp/s",
		 "12s demon form:\n10× dmg + fear aura",
		 "Blast jump 10m forward\n+ 100 dmg burst"],                                 # WARLOCK
		["Blazing orb projectile:\n350 dmg + 5s fire zone",
		 "Next death\nauto-revives (20s)",
		 "Sky strike at target\n1500 dmg in 18m",
		 "Dash 13m + fire zone\nat landing"],                                        # PHOENIX
		["Permanently control\nnearest enemy (30m)",
		 "All allies gain 2×\ndmg and speed (15s)",
		 "Gravity well at target\npulls + 80dmg/0.5s, 2000 finale",
		 "Pull all in 15m to you,\nthen dash 14m away"],                             # GRAVEMIND
		["750 dmg to enemies\n<50% HP (8m), +40% HP",
		 "6s berserk:\n2× speed + damage",
		 "Inferno at target\n150 dmg/0.5s for 10s",
		 "Fastest dash (18m),\n4.5m AOE 300 dmg"],                                   # DOOMSLAYER
	]
	var idx : int = int(player_class) - 1
	if idx < 0 or idx >= tbl.size(): return ""
	if slot < 0 or slot >= 4: return ""
	return tbl[idx][slot]
