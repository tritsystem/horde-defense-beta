# ============================================================
# hud.gd
# ============================================================
# LAYOUT:
#   TOP CENTER  — phase / timer / gold / zombie count
#   CENTER      — crosshair + ready button
#   BOTTOM LEFT — weapon name
#   BOTTOM RIGHT— ammo
#   BOTTOM CENTER — [divider line] ability bar
#   VERY BOTTOM — squad command strip
#
# ZOMBIE SELECTION (FPS):
#   Hold [Z] to enter selection mode — crosshair turns green,
#   a reticle appears. Aim at a zombie → it highlights yellow.
#   Left-click to select it. Right-click to deselect all.
#   [G] selects all team zombies instantly.
#   Commands: [1]=attack [2]=defend [3]=patrol [4]=stay [5]=follow
#   Attack/defend require a ground click to set target.
#
# HOW SQUAD COMMANDS WORK:
#   1. Select zombies with Z+click or press G for all
#   2. Press a command key (1-5)
#   3. For attack/defend: click ground to set destination
#   4. For patrol: click multiple points, press 3 again to finish
#   5. Stay/Follow execute immediately
# ============================================================
extends Control
class_name HUD

# ── UI NODE REFS ─────────────────────────────────────────────
var hp_bar            : ProgressBar   # hidden - kept for signal compat
var hp_label          : Label
var base_bar          : ProgressBar
var base_label        : Label
var ammo_label        : Label
var gun_name_label    : Label
var zombies_label     : Label
var gold_label        : Label
var timer_label       : Label
var phase_label       : Label
var ready_wrap        : Control
var ready_button      : Button
var gamepad_ready_btn : Button
var crosshair         : Label
var _hurt_flash           : ColorRect
var _flash_tween          : Tween
var _timer_tween          : Tween
var _low_health_vignette  : ColorRect = null
var _vignette_tween       : Tween     = null
var _vignette_pulsing     : bool      = false

# Ability slots (3 panels bottom center)
var _ability_panels   : Array[Control]     = []
var _ability_icons    : Array[Label]       = []
var _ability_names    : Array[Label]       = []
var _ability_cd_bars  : Array[ProgressBar] = []
var _ability_cd_lbls  : Array[Label]       = []
var _ability_key_lbls : Array[Label]       = []
var _class_ab_panels  : Array[Control]     = []
var _class_ab_cdlbls  : Array[Label]       = []
var _class_ab_cdbars  : Array[ProgressBar] = []
var _class_ab_namelbs : Array[Label]       = []
var _class_ab_desclbs : Array[Label]       = []   # cached desc label refs
var _class_ab_overlays     : Array[Control]   = []
var _class_ab_overlay_lbls : Array[Label]     = []
var _class_ab_sweep_rects  : Array[ColorRect] = []
var _last_player_class : int               = -1   # dirty check for name/desc update
var _class_ability_bar : HBoxContainer     = null  # shared bar for class + trinket slots
var _minimap_draw     : Control            = null
const CLASS_AB_KEYS   := ["1", "2", "3", "4"]
const CLASS_AB_COLORS := [Color(1.0,0.65,0.1), Color(0.35,0.75,1.0), Color(0.55,1.0,0.4), Color(1.0,0.4,0.8)]

# Squad panel refs
var _squad_panel      : Control
var _squad_minimized  : bool    = false
var _squad_expanded_h : float   = 110.0
var _squad_count_lbl  : Label
var _squad_status_lbl : Label
var _squad_sel_btn    : Button
var _squad_atk_btn    : Button
var _squad_def_btn    : Button
var _squad_pat_btn    : Button
var _squad_stay_btn   : Button
var _squad_follow_btn : Button
var _box_rect         : ColorRect

# FPS selection tool
var _sel_mode_active  : bool    = false   # true while Z held
var _sel_reticle      : Control           # outer ring shown in sel mode
var _sel_highlight_lbl: Label             # "▶ ZOMBIE NAME" overlay
var _hovered_zombie   : Node    = null    # zombie under crosshair
var _sel_ray_timer    : float   = 0.0
const SEL_RAY_HZ      : float   = 20.0   # raycast Hz in selection mode

# ── PLAYER / GAME REFS ───────────────────────────────────────
var player       : Node = null
var base         : Node = null
var game_manager : Node = null
var current_gun  : Node = null
var team_id      : int  = 1
var _is_kbm      : bool = true
var _horde_mgr           = null
var _player_iid  : int  = -1

# ── STATE ────────────────────────────────────────────────────
var is_ready    : bool = false
var shop_open   : bool = false
var prep_active : bool = true

var _last_enemy_count : int   = -1
var _last_ammo        : int   = -1
var _last_max_ammo    : int   = -1
var _last_hp          : float = -1.0
var _last_max_hp      : float = -1.0
var _last_base_hp     : float = -1.0
var _last_base_max_hp : float = -1.0

# ── SQUAD STATE ──────────────────────────────────────────────
var _pending_cmd   : String = ""
var _box_selecting : bool   = false
var _box_start     : Vector2= Vector2.ZERO
var _patrol_pts    : Array  = []
var _in_patrol_set : bool   = false
var _local_selected: Array   = []

# ── THROTTLE ─────────────────────────────────────────────────
var _enemy_timer   : float = 0.0
var _health_timer  : float = 0.0
var _ammo_timer    : float = 0.0
var _ability_timer  : float   = 0.0
var _minimap_timer  : float   = 0.0
var _death_screen   : Control = null
var _ability_flash  : ColorRect = null
var _hitmarker      : Control    = null
var _crystal_lbl    : Label      = null
var _quest_panel    : Control    = null
var _wave_choice_panel : Control = null
var _round_card        : Control = null
var _card_popup_queue  : Array   = []
var _quest_rows     : Dictionary = {}
var _grapple_ui     : Control    = null
var _turret_hover   : Control    = null   # floating upgrade panel above turret
var _grapple_cd_bar : Control    = null
var _minimap        : Control    = null
var _minimap_dots   : Dictionary = {}
var _crystal_flash  : ColorRect  = null
var _hs_label       : Label      = null
var _death_timer_lbl: Label   = null
var _wave_countdown_overlay : Control = null
var _wave_countdown_lbl     : Label   = null
var _deck_overlay           : Control = null
var _deck_card_labels       : Array   = []

const ENEMY_INTERVAL   := 0.5
const HEALTH_INTERVAL  := 0.1
const AMMO_INTERVAL    := 0.1
const ABILITY_INTERVAL := 0.20   # 5fps ability bar refresh (was 20fps)

const _VIGNETTE_THRESHOLD    : float = 0.30   # HP% where vignette starts
const _VIGNETTE_MAX_STRENGTH : float = 0.72   # shader strength at 0 HP
const _VIGNETTE_PULSE_HP     : float = 0.20   # HP% where vignette begins pulsing

# ── THEME ────────────────────────────────────────────────────
const C_DIM     := Color(0.45, 0.47, 0.50, 1.0)
const C_GREEN   := Color(0.08, 0.69, 0.38, 1.0)
const C_ORANGE  := Color(0.96, 0.48, 0.15, 1.0)
const C_RED     := Color(0.88, 0.12, 0.15, 1.0)
const C_TEXT    := Color(0.90, 0.92, 0.94, 1.0)
const C_SUBTEXT := Color(0.58, 0.60, 0.65, 1.0)
const C_YELLOW  := Color(0.95, 0.85, 0.15, 1.0)

const FS_TINY   := 8
const FS_SMALL  := 10
const FS_MEDIUM := 13
const FS_LARGE  := 20
const FS_XLARGE := 38

const SLOT_COLORS := [Color(1.0, 0.35, 0.1)]
const SLOT_ICONS  := ["⚡"]
const SLOT_KBM    := ["Q"]
const SLOT_PAD    := ["LB"]

const C_ATK    := Color(0.75, 0.20, 0.10)
const C_DEF    := Color(0.15, 0.40, 0.80)
const C_PAT    := Color(0.15, 0.65, 0.40)
const C_STAY   := Color(0.40, 0.40, 0.45)
const C_FOLLOW := Color(0.65, 0.48, 0.15)
const C_SEL    := Color(0.12, 0.50, 0.22)


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	add_to_group("hud")
	var cl := get_parent()
	if cl is CanvasLayer: cl.layer = 10
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 10

	# Try singleton first, fall back to scene group
	if Engine.has_singleton("ZombieHordeManager"):
		_horde_mgr = Engine.get_singleton("ZombieHordeManager")
	else:
		_horde_mgr = get_tree().get_first_node_in_group("zombie_horde_manager")
	if is_instance_valid(_horde_mgr) and _horde_mgr.has_signal("selection_changed"):
		_horde_mgr.selection_changed.connect(_on_selection_changed)

	_build_ui()
	# Block input briefly so buffered clicks from menu don't fire immediately
	call_deferred("_enable_input")

	if is_instance_valid(ready_button):
		ready_button.pressed.connect(_on_ready_pressed)
	if is_instance_valid(gamepad_ready_btn):
		gamepad_ready_btn.pressed.connect(_on_ready_pressed)

	call_deferred("_fix_size")


func _enable_input() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	Input.flush_buffered_events()
	_input_ready = true


func _fix_size() -> void:
	var vp := get_viewport()
	if not vp: return
	var sz := vp.get_visible_rect().size
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 0.0; offset_right = 0.0; offset_top = 0.0; offset_bottom = 0.0
	size = sz; position = Vector2.ZERO


# ============================================================
# BIND PLAYER
# ============================================================
func bind_player(p: Node) -> void:
	player      = p
	team_id     = int(p.get("team_id")   if "team_id"   in p else 1)
	_is_kbm     = int(p.get("device_id") if "device_id" in p else -1) == -1
	_player_iid = p.get_instance_id()
	game_manager = get_tree().get_first_node_in_group("game_manager")
	base = null
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and b.get("team_id") == team_id:
			base = b; break
	_setup_ready_ui()
	_connect_signals()
	_sync_all()
	_refresh_ability_slots()
	_refresh_squad_count()
	# Wire SquadCommandPanel — bind player and apply left-side position
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp):
		scp.bind_player(p)
		_force_squad_panel_position(scp)
	# Connect TalentTree updates to ability refresh
	var tt := get_node_or_null("/root/TalentTree")
	if is_instance_valid(tt) and tt.has_signal("tree_updated"):
		if not tt.tree_updated.is_connected(_on_tree_updated):
			tt.tree_updated.connect(_on_tree_updated)
	_refresh_deck_overlay()
	print("[HUD] P%s bound | team=%d | kbm=%s" % [
		str(p.get("player_id") if "player_id" in p else "?"), team_id, str(_is_kbm)])


func _setup_ready_ui() -> void:
	if _is_kbm:
		if is_instance_valid(ready_button):
			ready_button.visible = true
			ready_button.mouse_filter = Control.MOUSE_FILTER_STOP
		if is_instance_valid(gamepad_ready_btn): gamepad_ready_btn.visible = false
		_set_hint_text("PRESS [ SPACE ] TO DEPLOY")
	else:
		if is_instance_valid(ready_button):
			ready_button.visible = false
			ready_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if is_instance_valid(gamepad_ready_btn): gamepad_ready_btn.visible = true
		_set_hint_text("PRESS [ START ] TO DEPLOY")
	for i in 1:
		if i < _ability_key_lbls.size() and is_instance_valid(_ability_key_lbls[i]):
			_ability_key_lbls[i].text = "[%s]" % (SLOT_KBM[i] if _is_kbm else SLOT_PAD[i])

func _set_hint_text(text: String) -> void:
	if not is_instance_valid(ready_wrap): return
	for child in ready_wrap.get_children():
		if child is VBoxContainer:
			for lbl in child.get_children():
				if lbl is Label: lbl.text = text; return


# ============================================================
# SHOP STATE
# ============================================================
func set_topdown_mode(is_topdown: bool) -> void:
	if is_instance_valid(crosshair):
		crosshair.visible = not is_topdown
	if is_instance_valid(_sel_reticle):
		_sel_reticle.visible = false  # never show in topdown
	if is_instance_valid(_sel_highlight_lbl):
		_sel_highlight_lbl.visible = false
	if is_topdown: _exit_sel_mode()
	# Minimap stays visible regardless of topdown/shop state (see _build_minimap).


func set_shop_open(open: bool) -> void:
	shop_open = open
	z_index = 5 if open else 10
	if is_instance_valid(crosshair): crosshair.visible = not open
	# Fade minimap to background when shop is open
	if is_instance_valid(_minimap):
		if open:
			_minimap.modulate = Color(1, 1, 1, 0.25)
			_minimap.z_index   = 1   # behind shop
		else:
			_minimap.modulate = Color(1, 1, 1, 1.0)
			_minimap.z_index   = 110
	# HUD root stays IGNORE — shop UI manages its own mouse_filter
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Raise shop panel above all 3D content when open
	if is_instance_valid(get_parent()) and get_parent() is CanvasLayer:
		(get_parent() as CanvasLayer).layer = 50 if open else 10
	if is_instance_valid(ready_wrap): ready_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(ready_button): ready_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(gamepad_ready_btn): gamepad_ready_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_squad_panel):
		_squad_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE if open else Control.MOUSE_FILTER_STOP
	# Hide revive counter during gameplay; show only in shop
	if is_instance_valid(_revive_lbl): _revive_lbl.visible = open
	# Exit selection mode when shop opens
	if open: _exit_sel_mode()


# ============================================================
# INPUT
# ============================================================
var _input_ready : bool = false  # blocks input for first frame after scene load

func _input(event: InputEvent) -> void:
	if not _input_ready: return
	# ── READY BUTTON ─────────────────────────────────────────
	if prep_active and not shop_open and not is_ready and _is_kbm:
		if event is InputEventKey and event.pressed and not event.is_echo():
			if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
				_on_ready_pressed()
				get_viewport().set_input_as_handled()
				return

	if shop_open: return

	# ── SELECTION MODE TOGGLE (Z toggles on/off) ────────────
	if _is_kbm and event is InputEventKey and event.pressed and not event.is_echo():
		var kev := event as InputEventKey
		if kev.keycode == KEY_Z:
			if _sel_mode_active: _exit_sel_mode()
			else:                _enter_sel_mode()
			get_viewport().set_input_as_handled()
			return

	# ── SELECTION MODE INPUT ─────────────────────────────────
	if _sel_mode_active and _is_kbm:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					# If pending command (attack/defend) — place it
					if _pending_cmd != "":
						_execute_pending_click(mb.position)
					else:
						# Start drag or click
						_box_selecting = true
						_box_start     = mb.position
						if is_instance_valid(_box_rect):
							_box_rect.visible  = true
							_box_rect.position = mb.position
							_box_rect.size     = Vector2.ZERO
				else:
					if _box_selecting:
						var drag_dist : float = mb.position.distance_to(_box_start)
						if drag_dist < 8.0:
							# Single click — select zombie under cursor
							if is_instance_valid(_hovered_zombie):
								_deselect_all()
								_select_zombie(_hovered_zombie)
						else:
							# Drag finished — box select
							_box_up(mb.position)
					_box_selecting = false
					if is_instance_valid(_box_rect): _box_rect.visible = false
				get_viewport().set_input_as_handled()
			elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				# RMB = deselect all / cancel command
				if _pending_cmd != "": _squad_cancel_pending()
				else: _deselect_all()
				get_viewport().set_input_as_handled()
		if event is InputEventMouseMotion and _box_selecting:
			_box_update(event.position)
		return

	# ── WAVE PANEL HOTKEYS ([Shift+Q] toggle, [1-6] select wave) ──
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).is_echo():
		var _kev0 := event as InputEventKey
		if _kev0.keycode == KEY_Q and _kev0.shift_pressed:
			# Shift+Q always toggles wave panel — build it immediately if needed
			if not is_instance_valid(_wave_choice_panel):
				# Build panel with current values (may be defaults if phase hasn't started)
				_build_wave_choice_panel(
					maxi(_waves_this_round, 3),
					_deploy_wave_num if _deploy_wave_num > 0 else 1,
					0.0)
				_wave_choice_panel.visible = true
			else:
				_wave_choice_panel.visible = not _wave_choice_panel.visible
			_update_wave_tab_icon()
			get_viewport().set_input_as_handled()
			return
	if is_instance_valid(_wave_choice_panel) and event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).is_echo():
		var _wkey := (event as InputEventKey).keycode
		var _kev2 := event as InputEventKey
		# Shift+1-9 = queue creep
		if _kev2.shift_pressed and _wave_choice_panel.visible:
			var _smap := {KEY_1:0,KEY_2:1,KEY_3:2,KEY_4:3,KEY_5:4,KEY_6:5,KEY_7:6,KEY_8:7,KEY_9:8}
			if _wkey in _smap:
				var _ci : int = _smap[_wkey]
				if _ci < _creep_btn_list.size():
					var _ce : Dictionary = _creep_btn_list[_ci]
					_queue_creep_by_id(_ce.get("id",""), _ce.get("cost",100), _wave_choice_panel)
			get_viewport().set_input_as_handled()
			return
		# Bare 1-6 = select deploy wave
		var _wave_map := {KEY_1:1,KEY_2:2,KEY_3:3,KEY_4:4,KEY_5:5,KEY_6:6}
		if _wkey in _wave_map and _wave_choice_panel.visible:
			var _wv : int = _wave_map[_wkey]
			if _wv <= _waves_this_round and _wv not in _completed_waves:
				_select_deploy_wave(_wv, _wave_choice_panel)
				show_message("Wave %d selected  [Shift+1-9=queue creep]" % _wv, Color(0.5, 0.8, 1.0))
			get_viewport().set_input_as_handled()
			return

	# ── TURRET HOVER PANEL KEYS ──────────────────────────────────
	if _is_kbm and event is InputEventKey and event.pressed and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_T:  # toggle turret panel
				if is_instance_valid(_turret_hover) and _turret_hover.visible:
					_turret_hover.visible  = false
					_turret_hover_closed   = true
				elif is_instance_valid(_turret_hover_target):
					_turret_hover_closed   = false
					_turret_hover.visible  = true
					_turret_refresh_ui()
				get_viewport().set_input_as_handled()
				return
			KEY_U:  # upgrade
				if is_instance_valid(_turret_hover) and _turret_hover.visible:
					_turret_do_upgrade()
					get_viewport().set_input_as_handled()
					return
			KEY_R:  # repair
				if is_instance_valid(_turret_hover) and _turret_hover.visible:
					_turret_do_repair()
					get_viewport().set_input_as_handled()
					return

	# ── SQUAD HOTKEYS (only when wave panel not open / visible) ──
	if is_instance_valid(_wave_choice_panel) and _wave_choice_panel.visible: return
	if _is_kbm and event is InputEventKey and event.pressed and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_G, KEY_F:
				_squad_select_all()
				get_viewport().set_input_as_handled()
			KEY_1: _squad_attack(); get_viewport().set_input_as_handled()
			KEY_2: _squad_defend(); get_viewport().set_input_as_handled()
			KEY_3: _squad_patrol(); get_viewport().set_input_as_handled()
			KEY_4: _squad_stay();   get_viewport().set_input_as_handled()
			KEY_5: _squad_follow(); get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if _pending_cmd != "" or _in_patrol_set:
					_squad_cancel_pending()
					get_viewport().set_input_as_handled()


# ============================================================
# FPS ZOMBIE SELECTION TOOL
# ============================================================

func _enter_sel_mode() -> void:
	if _sel_mode_active: return
	_sel_mode_active = true
	if is_instance_valid(crosshair):
		crosshair.text = "◎"
		crosshair.add_theme_color_override("font_color", C_YELLOW)
	if is_instance_valid(_sel_reticle): _sel_reticle.visible = true
	# Disable weapon firing while in selection mode
	if is_instance_valid(player):
		if "can_fire" in player:    player.can_fire    = false
		if "fire_locked" in player: player.fire_locked = true
		if player.has_method("set_fire_locked"): player.set_fire_locked(true)
	_squad_set_status("Z mode ON — click zombie to select, drag to box select, RMB deselect")


func _exit_sel_mode() -> void:
	if not _sel_mode_active: return
	_sel_mode_active = false
	_update_crosshair_for_gun(current_gun)
	if is_instance_valid(_sel_reticle): _sel_reticle.visible = false
	if is_instance_valid(_sel_highlight_lbl): _sel_highlight_lbl.visible = false
	_clear_hover_highlight()
	# Re-enable weapon firing
	if is_instance_valid(player):
		if "can_fire" in player:    player.can_fire    = true
		if "fire_locked" in player: player.fire_locked = false
		if player.has_method("set_fire_locked"): player.set_fire_locked(false)


func _process_sel_ray(delta: float) -> void:
	# Cast a ray from camera center to find hovered zombie
	_sel_ray_timer -= delta
	if _sel_ray_timer > 0.0: return
	_sel_ray_timer = 1.0 / SEL_RAY_HZ

	var cam := _get_cam()
	if not cam: return
	var vp_center := get_viewport().get_visible_rect().size * 0.5
	var from      := cam.project_ray_origin(vp_center)
	var to        := from + cam.project_ray_normal(vp_center) * 40.0
	var query     := PhysicsRayQueryParameters3D.create(from, to)
	if is_instance_valid(player) and player is CollisionObject3D:
		query.exclude = [player.get_rid()]
	var hit := get_viewport().get_world_3d().direct_space_state.intersect_ray(query)

	var found_zombie : Node = null
	if not hit.is_empty():
		var node := hit.get("collider") as Node
		var z    := node
		while is_instance_valid(z) and z != get_tree().current_scene:
			if z.is_in_group("units") and "team_id" in z and int(z.team_id) == team_id:
				found_zombie = z; break
			z = z.get_parent()

	if found_zombie != _hovered_zombie:
		_clear_hover_highlight()
		_hovered_zombie = found_zombie
		if is_instance_valid(found_zombie):
			_apply_hover_highlight(found_zombie)

	# Update label
	if is_instance_valid(_sel_highlight_lbl):
		if is_instance_valid(found_zombie):
			var hp : float = float(found_zombie.get("health") if "health" in found_zombie else 0)
			var mx : float = float(found_zombie.get("max_health") if "max_health" in found_zombie else 1)
			_sel_highlight_lbl.text = "▶ %s  HP: %d/%d\nClick to select" % [
				found_zombie.name, int(hp), int(mx)]
			_sel_highlight_lbl.visible = true
		else:
			_sel_highlight_lbl.visible = false


func _apply_hover_highlight(z: Node) -> void:
	# Tint mesh instances yellow
	for child in z.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).set_instance_shader_parameter("selected", 1.0)
	# Or use modulate as fallback
	if z is CanvasItem: (z as CanvasItem).modulate = Color(1.5, 1.5, 0.5, 1.0)


func _clear_hover_highlight() -> void:
	if not is_instance_valid(_hovered_zombie): return
	for child in _hovered_zombie.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).set_instance_shader_parameter("selected", 0.0)
	if _hovered_zombie is CanvasItem:
		(_hovered_zombie as CanvasItem).modulate = Color.WHITE
	_hovered_zombie = null


func _select_zombie(z: Node) -> void:
	if not is_instance_valid(_horde_mgr): return
	if not (z is Node3D): return
	# Use public API — select_in_radius with tiny radius to pick just this unit
	_horde_mgr.select([z])
	var n : int = _horde_mgr.get_selected().size()
	_squad_set_status("Selected: %s (%d total)" % [z.name, n])
	_refresh_squad_count(n)


func _deselect_all() -> void:
	if is_instance_valid(_horde_mgr): _horde_mgr.clear_selection()
	_squad_set_status("Deselected all.")


# ============================================================
# BUILD UI
# ============================================================
func _build_ui() -> void:
	_build_top_left()
	_build_top_center()
	_build_center()
	_build_sel_reticle()
	_build_bottom_bar()
	_build_squad_panel()
	_build_hurt_flash()
	_build_low_health_vignette()
	_build_wave_countdown()
	_build_deck_overlay()


# ─────────────────────────────────────────────────────────────
# TOP LEFT — player HP + base HP (compact)
# ─────────────────────────────────────────────────────────────
func _build_top_left() -> void:
	# WoW-style unit frame: dark rounded panel, name + HP bar + base bar
	var frame := Control.new()
	frame.anchor_left   = 0.00; frame.anchor_right  = 0.22
	frame.anchor_top    = 0.00; frame.anchor_bottom = 0.00
	frame.offset_left   = 6;    frame.offset_right  = 0
	frame.offset_top    = 6;    frame.offset_bottom = 88
	frame.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	# Dark background panel with WoW-style gold border
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_sty := StyleBoxFlat.new()
	bg_sty.bg_color = Color(0.05, 0.06, 0.09, 0.92)
	bg_sty.set_border_width_all(2)
	bg_sty.border_color = Color(0.50, 0.43, 0.25, 0.85)
	bg_sty.set_corner_radius_all(4)
	bg_sty.content_margin_left   = 8
	bg_sty.content_margin_right  = 8
	bg_sty.content_margin_top    = 6
	bg_sty.content_margin_bottom = 6
	bg.add_theme_stylebox_override("panel", bg_sty)
	frame.add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(col)

	# ── Player name row ───────────────────────────────────────
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_row)

	var portrait_dot := ColorRect.new()   # small class-color square (portrait placeholder)
	portrait_dot.custom_minimum_size = Vector2(10, 10)
	portrait_dot.color = Color(0.3, 0.7, 1.0)
	portrait_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(portrait_dot)

	var name_lbl := Label.new()
	name_lbl.text = "PLAYER"
	name_lbl.add_theme_font_size_override("font_size", FS_TINY)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.75))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(name_lbl)

	# ── HP bar (WoW green) ────────────────────────────────────
	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 4)
	hp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(hp_row)

	var hp_icon := Label.new()
	hp_icon.text = "HP"
	hp_icon.add_theme_font_size_override("font_size", FS_TINY)
	hp_icon.add_theme_color_override("font_color", C_GREEN)
	hp_icon.custom_minimum_size.x = 16
	hp_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_row.add_child(hp_icon)

	hp_bar = ProgressBar.new()
	hp_bar.max_value = 100; hp_bar.value = 100
	hp_bar.show_percentage = false
	hp_bar.custom_minimum_size = Vector2(0, 8)
	hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hp_fill := StyleBoxFlat.new()
	hp_fill.bg_color = Color(0.14, 0.72, 0.25)   # WoW green
	hp_fill.set_corner_radius_all(2)
	var hp_bg := StyleBoxFlat.new()
	hp_bg.bg_color = Color(0.08, 0.10, 0.08, 0.9)
	hp_bg.set_corner_radius_all(2)
	hp_bar.add_theme_stylebox_override("fill", hp_fill)
	hp_bar.add_theme_stylebox_override("background", hp_bg)
	hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_row.add_child(hp_bar)

	hp_label = Label.new()
	hp_label.add_theme_font_size_override("font_size", FS_TINY)
	hp_label.add_theme_color_override("font_color", Color(0.85, 0.90, 0.85))
	hp_label.custom_minimum_size.x = 52
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_row.add_child(hp_label)

	# ── Base HP bar (WoW orange) ──────────────────────────────
	var base_row := HBoxContainer.new()
	base_row.add_theme_constant_override("separation", 4)
	base_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(base_row)

	var base_icon := Label.new()
	base_icon.text = "BASE"
	base_icon.add_theme_font_size_override("font_size", FS_TINY)
	base_icon.add_theme_color_override("font_color", C_ORANGE)
	base_icon.custom_minimum_size.x = 16
	base_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base_row.add_child(base_icon)

	base_bar = ProgressBar.new()
	base_bar.max_value = 100; base_bar.value = 100
	base_bar.show_percentage = false
	base_bar.custom_minimum_size = Vector2(0, 8)
	base_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var base_fill := StyleBoxFlat.new()
	base_fill.bg_color = Color(0.85, 0.42, 0.08)  # WoW orange
	base_fill.set_corner_radius_all(2)
	var base_bg := StyleBoxFlat.new()
	base_bg.bg_color = Color(0.10, 0.08, 0.05, 0.9)
	base_bg.set_corner_radius_all(2)
	base_bar.add_theme_stylebox_override("fill", base_fill)
	base_bar.add_theme_stylebox_override("background", base_bg)
	base_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base_row.add_child(base_bar)

	base_label = Label.new()
	base_label.add_theme_font_size_override("font_size", FS_TINY)
	base_label.add_theme_color_override("font_color", Color(0.90, 0.80, 0.70))
	base_label.custom_minimum_size.x = 52
	base_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	base_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base_row.add_child(base_label)


# ─────────────────────────────────────────────────────────────
# TOP CENTER — phase / timer / gold / zombie count
# ─────────────────────────────────────────────────────────────
func _build_top_center() -> void:
	# Compact pill strip at very top — phase | timer | gold | enemies
	var strip := Control.new()
	strip.anchor_left   = 0.25; strip.anchor_right  = 0.75
	strip.anchor_top    = 0.0;  strip.anchor_bottom = 0.0
	strip.offset_top    = 4;    strip.offset_bottom = 34
	strip.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(strip)

	# Background pill
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_sty := StyleBoxFlat.new()
	bg_sty.bg_color = Color(0.04, 0.05, 0.08, 0.72)
	bg_sty.set_corner_radius_all(12)
	bg_sty.content_margin_left = 12; bg_sty.content_margin_right  = 12
	bg_sty.content_margin_top  = 4;  bg_sty.content_margin_bottom = 4
	bg.add_theme_stylebox_override("panel", bg_sty)
	strip.add_child(bg)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(row)

	phase_label = _section_label("PREP")
	phase_label.add_theme_font_size_override("font_size", 10)
	row.add_child(phase_label)

	var div1 := Label.new(); div1.text = "·"; div1.add_theme_color_override("font_color", C_DIM); row.add_child(div1)

	timer_label = Label.new()
	timer_label.text = "3:00"
	timer_label.add_theme_font_size_override("font_size", 16)
	timer_label.add_theme_color_override("font_color", C_TEXT)
	row.add_child(timer_label)

	var div2 := Label.new(); div2.text = "·"; div2.add_theme_color_override("font_color", C_DIM); row.add_child(div2)

	gold_label = _badge_label("◆ --", C_ORANGE)
	gold_label.add_theme_font_size_override("font_size", 12)
	row.add_child(gold_label)

	var div3 := Label.new(); div3.text = "·"; div3.add_theme_color_override("font_color", C_DIM); row.add_child(div3)

	zombies_label = _badge_label("🧟 0", C_DIM)
	zombies_label.add_theme_font_size_override("font_size", 12)
	row.add_child(zombies_label)


# ─────────────────────────────────────────────────────────────
# CENTER — crosshair + ready button
# ─────────────────────────────────────────────────────────────
func _build_center() -> void:
	crosshair = Label.new()
	crosshair.text = "┼"
	crosshair.add_theme_font_size_override("font_size", 28)
	crosshair.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98, 0.85))
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical   = Control.GROW_DIRECTION_BOTH
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	crosshair.custom_minimum_size  = Vector2(32, 32)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)

	ready_wrap = CenterContainer.new()
	ready_wrap.set_anchors_preset(Control.PRESET_CENTER)
	ready_wrap.anchor_top    = 0.60
	ready_wrap.anchor_bottom = 0.60
	ready_wrap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ready_wrap.grow_vertical   = Control.GROW_DIRECTION_BOTH
	ready_wrap.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	add_child(ready_wrap)

	var col := _vbox(8)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	ready_wrap.add_child(col)

	var hint := Label.new()
	hint.text = "PRESS [ SPACE ] TO DEPLOY"
	hint.add_theme_font_size_override("font_size", FS_TINY)
	hint.add_theme_color_override("font_color", C_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	ready_button = Button.new()
	ready_button.text = "READY"
	ready_button.add_theme_font_size_override("font_size", FS_MEDIUM)
	ready_button.add_theme_color_override("font_color", C_RED)
	ready_button.custom_minimum_size = Vector2(120, 52)
	ready_button.mouse_filter = Control.MOUSE_FILTER_STOP
	col.add_child(ready_button)

	gamepad_ready_btn = Button.new()
	gamepad_ready_btn.text = "READY"
	gamepad_ready_btn.add_theme_font_size_override("font_size", FS_MEDIUM)
	gamepad_ready_btn.add_theme_color_override("font_color", C_RED)
	gamepad_ready_btn.custom_minimum_size = Vector2(120, 52)
	gamepad_ready_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gamepad_ready_btn.focus_mode   = Control.FOCUS_ALL
	gamepad_ready_btn.visible      = false
	col.add_child(gamepad_ready_btn)


# ─────────────────────────────────────────────────────────────
# SELECTION RETICLE + HOVER LABEL
# ─────────────────────────────────────────────────────────────
func _build_sel_reticle() -> void:
	# Outer ring around crosshair shown in selection mode
	_sel_reticle = Control.new()
	_sel_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_sel_reticle.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sel_reticle.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_sel_reticle.custom_minimum_size = Vector2(48, 48)
	_sel_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel_reticle.visible = false
	add_child(_sel_reticle)

	var ring := Label.new()
	ring.text = "○"
	ring.add_theme_font_size_override("font_size", 48)
	ring.add_theme_color_override("font_color", C_YELLOW)
	ring.set_anchors_preset(Control.PRESET_CENTER)
	ring.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ring.grow_vertical   = Control.GROW_DIRECTION_BOTH
	ring.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ring.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel_reticle.add_child(ring)

	# Hover label — shows zombie name + HP when aimed at one
	_sel_highlight_lbl = Label.new()
	_sel_highlight_lbl.anchor_left   = 0.5
	_sel_highlight_lbl.anchor_right  = 0.5
	_sel_highlight_lbl.anchor_top    = 0.42
	_sel_highlight_lbl.anchor_bottom = 0.42
	_sel_highlight_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sel_highlight_lbl.grow_vertical   = Control.GROW_DIRECTION_BEGIN
	_sel_highlight_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sel_highlight_lbl.add_theme_font_size_override("font_size", 12)
	_sel_highlight_lbl.add_theme_color_override("font_color", C_YELLOW)
	_sel_highlight_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel_highlight_lbl.visible = false
	add_child(_sel_highlight_lbl)

	# Z-key hint label at top when in sel mode
	var z_hint := Label.new()
	z_hint.name = "ZHint"
	z_hint.text = "[ Z ] SELECTION MODE"
	z_hint.anchor_left   = 0.5; z_hint.anchor_right  = 0.5
	z_hint.anchor_top    = 0.94; z_hint.anchor_bottom = 0.94
	z_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	z_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	z_hint.add_theme_font_size_override("font_size", 10)
	z_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.7))
	z_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(z_hint)


# ─────────────────────────────────────────────────────────────
# BOTTOM BAR — weapon | divider | abilities | ammo
# ─────────────────────────────────────────────────────────────
func _build_bottom_bar() -> void:
	# Thin divider line above ability bar (now at very bottom)
	var line := ColorRect.new()
	line.color = Color(1.0, 1.0, 1.0, 0.07)
	line.anchor_left   = 0.0; line.anchor_right  = 1.0
	line.anchor_top    = 0.905; line.anchor_bottom = 0.905
	line.custom_minimum_size.y = 1.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)

	# Bottom left — weapon name
	var wp := _panel(0.01, 0.825, 0.26, 0.900)
	var wc := _vbox(2)
	wp.add_child(wc)
	wc.add_child(_section_label("WEAPON"))
	gun_name_label = Label.new()
	gun_name_label.text = "NO WEAPON"
	gun_name_label.add_theme_font_size_override("font_size", FS_SMALL)
	gun_name_label.add_theme_color_override("font_color", C_TEXT)
	wc.add_child(gun_name_label)

	# Bottom right — ammo
	var ap := _panel(0.74, 0.825, 0.99, 0.900)
	var ac := _vbox(2)
	ac.alignment = BoxContainer.ALIGNMENT_END
	ap.add_child(ac)
	var al := _section_label("AMMO")
	al.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ac.add_child(al)
	ammo_label = Label.new()
	ammo_label.text = "--"
	ammo_label.add_theme_font_size_override("font_size", FS_XLARGE)
	ammo_label.add_theme_color_override("font_color", C_ORANGE)
	ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ac.add_child(ammo_label)

	_build_class_ability_hud()
	_build_ability_bar()
	_build_death_screen()
	_build_ability_flash()
	_build_hitmarker()
	_build_crystal_hud()
	_build_combat_hud()
	_build_ult_button()
	_build_grapple_ui()
	_build_minimap()
	_build_kill_feed()
	_build_respawn_screen()
	_build_turret_hover_panel()


# ─────────────────────────────────────────────────────────────
# ABILITY BAR — 3 slots bottom center
# ─────────────────────────────────────────────────────────────
func _build_ability_bar() -> void:
	_ability_panels.clear(); _ability_icons.clear(); _ability_names.clear()
	_ability_cd_bars.clear(); _ability_cd_lbls.clear(); _ability_key_lbls.clear()

	# Append trinket slot to the right end of the class ability bar (compact mode).
	# Fallback: create a standalone container if the class bar isn't built yet.
	var container : HBoxContainer
	if is_instance_valid(_class_ability_bar):
		var vsep := VSeparator.new()
		vsep.modulate = Color(1, 1, 1, 0.22)
		vsep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_class_ability_bar.add_child(vsep)
		container = _class_ability_bar
	else:
		container = HBoxContainer.new()
		container.name = "AbilityBar"
		container.anchor_left   = 0.30; container.anchor_right  = 0.70
		container.anchor_top    = 0.780; container.anchor_bottom = 0.855
		container.grow_horizontal = Control.GROW_DIRECTION_BOTH
		container.grow_vertical   = Control.GROW_DIRECTION_BOTH
		container.add_theme_constant_override("separation", 6)
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(container)

	for i in 1:
		var sc : Color = SLOT_COLORS[i]
		var panel := PanelContainer.new()
		# Compact when attached to class ability bar — fixed width, no expand
		if is_instance_valid(_class_ability_bar):
			panel.custom_minimum_size = Vector2(108, 0)
		else:
			panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.05, 0.06, 0.08, 0.88)
		style.set_border_width_all(2); style.border_color = sc
		style.set_corner_radius_all(4)
		style.content_margin_left = 5; style.content_margin_right  = 5
		style.content_margin_top  = 3; style.content_margin_bottom = 3
		panel.add_theme_stylebox_override("panel", style)
		container.add_child(panel)
		_ability_panels.append(panel)

		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 1)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(col)

		var top_row := HBoxContainer.new()
		top_row.add_theme_constant_override("separation", 3)
		col.add_child(top_row)

		var key_lbl := Label.new()
		key_lbl.text = "[%s]" % (SLOT_KBM[i] if _is_kbm else SLOT_PAD[i])
		key_lbl.add_theme_font_size_override("font_size", FS_TINY)
		key_lbl.add_theme_color_override("font_color", sc)
		key_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top_row.add_child(key_lbl)
		_ability_key_lbls.append(key_lbl)

		var icon := Label.new()
		icon.text = SLOT_ICONS[i]
		icon.add_theme_font_size_override("font_size", 18)
		icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		top_row.add_child(icon)
		_ability_icons.append(icon)

		var name_lbl := Label.new()
		name_lbl.text = "— Empty —"
		name_lbl.add_theme_font_size_override("font_size", FS_TINY)
		name_lbl.add_theme_color_override("font_color", C_DIM)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.clip_contents = true
		col.add_child(name_lbl)
		_ability_names.append(name_lbl)

		var cd_bar := ProgressBar.new()
		cd_bar.custom_minimum_size = Vector2(0, 3)
		cd_bar.max_value = 1.0; cd_bar.value = 1.0
		cd_bar.show_percentage = false
		cd_bar.add_theme_color_override("fill_color", sc)
		cd_bar.add_theme_color_override("background_color", Color(0.1,0.1,0.1,0.6))
		col.add_child(cd_bar)
		_ability_cd_bars.append(cd_bar)

		var cd_lbl := Label.new()
		cd_lbl.text = "EMPTY"
		cd_lbl.add_theme_font_size_override("font_size", FS_TINY)
		cd_lbl.add_theme_color_override("font_color", C_DIM)
		cd_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(cd_lbl)
		_ability_cd_lbls.append(cd_lbl)


# ─────────────────────────────────────────────────────────────
# SQUAD PANEL — instantiates SquadCommandPanel script as child
# ─────────────────────────────────────────────────────────────

func _build_death_screen() -> void:
	_death_screen = Control.new()
	_death_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_screen.visible = false
	_death_screen.z_index = 200
	add_child(_death_screen)

	# Dark overlay
	var overlay := ColorRect.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.0, 0.0, 0.0, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.name = "Overlay"
	_death_screen.add_child(overlay)

	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_screen.add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(col)

	# "YOU DIED LOL" text
	var died_lbl := Label.new()
	died_lbl.name = "DiedLabel"
	died_lbl.text = "YOU DIED LOL"
	died_lbl.add_theme_font_size_override("font_size", 72)
	died_lbl.add_theme_color_override("font_color", Color(0.95, 0.1, 0.1))
	died_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(died_lbl)

	# Respawn countdown
	_death_timer_lbl = Label.new()
	_death_timer_lbl.text = "Respawning in 3..."
	_death_timer_lbl.add_theme_font_size_override("font_size", 22)
	_death_timer_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	_death_timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_death_timer_lbl)


func _build_ability_flash() -> void:
	_ability_flash = ColorRect.new()
	_ability_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ability_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_ability_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ability_flash.z_index = 150
	add_child(_ability_flash)


func flash_ability(slot: int) -> void:
	if not is_instance_valid(_ability_flash): return
	var sc : Color = SLOT_COLORS[slot] if slot < SLOT_COLORS.size() else Color.WHITE
	_ability_flash.color = Color(sc.r, sc.g, sc.b, 0.35)
	var tw := create_tween()
	tw.tween_property(_ability_flash, "color", Color(sc.r, sc.g, sc.b, 0.0), 0.4)


# ─────────────────────────────────────────────────────────────
# DECK OVERLAY — compact strip top-right, always visible mid-wave
# ─────────────────────────────────────────────────────────────
func _build_deck_overlay() -> void:
	var frame := PanelContainer.new()
	frame.name          = "DeckOverlay"
	frame.anchor_left   = 0.55;  frame.anchor_right  = 0.995
	frame.anchor_top    = 0.0;   frame.anchor_bottom = 0.0
	frame.offset_top    = 38;    frame.offset_bottom = 60
	frame.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	frame.z_index       = 15
	var sty := StyleBoxFlat.new()
	sty.bg_color = Color(0.04, 0.05, 0.09, 0.82)
	sty.set_corner_radius_all(4)
	sty.set_border_width_all(1)
	sty.border_color = Color(0.22, 0.26, 0.36, 0.8)
	sty.content_margin_left  = 5; sty.content_margin_right  = 5
	sty.content_margin_top   = 2; sty.content_margin_bottom = 2
	frame.add_theme_stylebox_override("panel", sty)
	add_child(frame)
	_deck_overlay = frame

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.alignment    = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(row)

	var hdr := Label.new()
	hdr.text = "DECK"
	hdr.add_theme_font_size_override("font_size", 8)
	hdr.add_theme_color_override("font_color", Color(0.42, 0.46, 0.56))
	hdr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hdr)

	_deck_card_labels.clear()
	for _i in 5:
		var sep := Label.new()
		sep.text = "·"
		sep.add_theme_font_size_override("font_size", 8)
		sep.add_theme_color_override("font_color", Color(0.26, 0.28, 0.34))
		sep.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(sep)

		var lbl := Label.new()
		lbl.text = "—"
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.add_theme_color_override("font_color", Color(0.50, 0.52, 0.58))
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lbl)
		_deck_card_labels.append(lbl)


func _refresh_deck_overlay() -> void:
	if not is_instance_valid(_deck_overlay): return
	var pid : int = int(player.get("player_id")) if is_instance_valid(player) and "player_id" in player else 1
	var cdm := get_node_or_null("/root/CreepDeckManager")
	if not is_instance_valid(cdm) or not cdm.has_method("get_player_deck"): return
	var deck : Array = cdm.get_player_deck(pid)
	for i in _deck_card_labels.size():
		var lbl : Label = _deck_card_labels[i] as Label
		if not is_instance_valid(lbl): continue
		if i < deck.size():
			var cid : String = deck[i]
			var def : Dictionary = cdm.get_creep_def(cid) if cdm.has_method("get_creep_def") else {}
			var icon : String = def.get("icon", "◈")
			var cost : int = def.get("cost", 0)
			var is_adv : bool = def.get("tier", "base") != "base"
			lbl.text = "%s %dg" % [icon, cost]
			lbl.add_theme_color_override("font_color",
				Color(1.0, 0.75, 0.40) if is_adv else Color(0.72, 0.90, 0.62))
		else:
			lbl.text = "—"
			lbl.add_theme_color_override("font_color", Color(0.38, 0.40, 0.46))


func _build_wave_countdown() -> void:
	_wave_countdown_overlay = Control.new()
	_wave_countdown_overlay.set_anchors_preset(Control.PRESET_CENTER)
	_wave_countdown_overlay.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_wave_countdown_overlay.grow_vertical   = Control.GROW_DIRECTION_BOTH
	# REAL BUG FIX (2026-07-25): "the 321 countdown is too big and covers the
	# whole screen" -- 220x150 box with a 96px font, popping in from 1.6x
	# scale, read as dominating the view during actual gameplay. Shrunk well
	# down and moved off dead-center so it doesn't block the player's view of
	# the action while it counts down.
	_wave_countdown_overlay.custom_minimum_size = Vector2(120, 84)
	_wave_countdown_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_countdown_overlay.z_index = 300
	_wave_countdown_overlay.visible = false
	_wave_countdown_overlay.offset_top -= 160.0   # shift up from dead-center
	add_child(_wave_countdown_overlay)

	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_sty := StyleBoxFlat.new()
	bg_sty.bg_color = Color(0.04, 0.04, 0.06, 0.78)
	bg_sty.set_corner_radius_all(10)
	bg.add_theme_stylebox_override("panel", bg_sty)
	_wave_countdown_overlay.add_child(bg)

	_wave_countdown_lbl = Label.new()
	_wave_countdown_lbl.text = "3"
	_wave_countdown_lbl.add_theme_font_size_override("font_size", 48)
	_wave_countdown_lbl.add_theme_color_override("font_color", Color(1.0, 0.55, 0.10))
	_wave_countdown_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_wave_countdown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_countdown_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_wave_countdown_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_countdown_overlay.add_child(_wave_countdown_lbl)


func _show_wave_countdown(wave_num: int, horde_size: int) -> void:
	if not is_instance_valid(_wave_countdown_lbl): return
	_wave_countdown_overlay.visible  = true
	_wave_countdown_overlay.modulate = Color.WHITE

	var digits : Array[String] = ["3", "2", "1", "GO!"]
	var colors : Array[Color]  = [
		Color(1.0, 0.55, 0.10),
		Color(1.0, 0.55, 0.10),
		Color(0.95, 0.25, 0.10),
		Color(0.20, 1.00, 0.45),
	]
	for i in digits.size():
		_wave_countdown_lbl.text = digits[i]
		_wave_countdown_lbl.add_theme_color_override("font_color", colors[i])
		_wave_countdown_lbl.scale     = Vector2(1.6, 1.6)
		_wave_countdown_lbl.modulate.a = 0.0
		var pop : Tween = create_tween()
		pop.set_parallel(true)
		pop.tween_property(_wave_countdown_lbl, "scale",      Vector2(1.0, 1.0), 0.25)
		pop.tween_property(_wave_countdown_lbl, "modulate:a", 1.0,               0.20)
		if i < digits.size() - 1:
			await get_tree().create_timer(1.0, true, false, true).timeout
		else:
			show_message("⚔ Wave %d — %d enemies incoming!" % [wave_num, horde_size],
				Color(1.0, 0.5, 0.2))
			await get_tree().create_timer(0.6, true, false, true).timeout
			var fade : Tween = _wave_countdown_overlay.create_tween()
			fade.tween_property(_wave_countdown_overlay, "modulate:a", 0.0, 0.4)
			await fade.finished
	_wave_countdown_overlay.visible  = false
	_wave_countdown_overlay.modulate = Color.WHITE


func _build_hitmarker() -> void:
	# Use a CenterContainer anchored to full rect so children sit at screen center
	_hitmarker = Control.new()
	_hitmarker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hitmarker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hitmarker.z_index = 250
	_hitmarker.visible = false
	add_child(_hitmarker)

	# Four tick marks offset from screen center
	var s : float = 8.0   # arm length
	var g : float = 4.0   # gap from center
	var cx : float = 0.5; var cy : float = 0.5  # anchor center
	for i in 4:
		var r := ColorRect.new()
		r.color = Color(1.0, 1.0, 1.0, 0.95)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Anchor to screen center, offset per arm direction
		r.anchor_left = cx; r.anchor_right = cx
		r.anchor_top  = cy; r.anchor_bottom = cy
		if i == 0:
			r.offset_left = -(s+g); r.offset_right = -g
			r.offset_top  = -1;     r.offset_bottom = 1
		elif i == 1:
			r.offset_left = g;      r.offset_right = s+g
			r.offset_top  = -1;     r.offset_bottom = 1
		elif i == 2:
			r.offset_left = -1;     r.offset_right = 1
			r.offset_top  = -(s+g); r.offset_bottom = -g
		else:
			r.offset_left = -1;     r.offset_right = 1
			r.offset_top  = g;      r.offset_bottom = s+g
		_hitmarker.add_child(r)

	# Headshot label above center
	_hs_label = Label.new()
	_hs_label.text = "✦ HEADSHOT ✦"
	_hs_label.add_theme_font_size_override("font_size", 16)
	_hs_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.1))
	_hs_label.anchor_left = cx; _hs_label.anchor_right = cx
	_hs_label.anchor_top  = cy; _hs_label.anchor_bottom = cy
	_hs_label.offset_left = -52; _hs_label.offset_right = 52
	_hs_label.offset_top  = -42; _hs_label.offset_bottom = -22
	_hs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hs_label.visible = false
	_hs_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hitmarker.add_child(_hs_label)


# ── Message queue — stacked feed, newest at bottom ───────────
var _active_msgs : Array = []   # Array of Label nodes currently displayed
const MAX_MSGS   : int   = 5
const MSG_SPACING: float = 32.0

func show_message(text: String, color: Color = Color.WHITE) -> void:
	# Deduplicate — skip if same text is already showing
	for existing in _active_msgs:
		if is_instance_valid(existing) and existing.text == text: return

	# Cap — remove oldest if full
	while _active_msgs.size() >= MAX_MSGS:
		var oldest : Node = _active_msgs.pop_front()
		if is_instance_valid(oldest): oldest.queue_free()

	# Shift existing messages upward to make room
	# REAL BUG FIX (2026-07-25): "narration overlaps, make them glide up" --
	# this shift was already intended to do exactly that, but two real bugs
	# defeated it: (1) tw2 wasn't parallel, so offset_top and offset_bottom
	# animated one after another instead of together, stretching each label
	# and taking 2x as long (0.3s) to actually reach its new slot; (2) every
	# new message created ANOTHER shift tween on the same still-shifting
	# labels with no reference to the previous one, so during any burst of
	# messages faster than ~0.3s apart (very normal in combat -- wave
	# announcements, quest progress, streaks, revives can all fire close
	# together) multiple tweens fought over the same offset properties every
	# frame, which reads as messages jittering/overlapping instead of
	# smoothly gliding. Kill any in-flight shift tween before starting a new
	# one, and make top+bottom move together.
	for i in _active_msgs.size():
		var m : Node = _active_msgs[i]
		if not is_instance_valid(m): continue
		if m.has_meta("_shift_tween"):
			var old_tw : Tween = m.get_meta("_shift_tween")
			if is_instance_valid(old_tw): old_tw.kill()
		var tw2 := m.create_tween().set_parallel(true)
		tw2.tween_property(m, "offset_top",    m.offset_top    - MSG_SPACING, 0.15)
		tw2.tween_property(m, "offset_bottom", m.offset_bottom - MSG_SPACING, 0.15)
		m.set_meta("_shift_tween", tw2)

	# Create new message at the bottom slot
	var slot : int = _active_msgs.size()
	var base_top : float = -80.0 - slot * MSG_SPACING

	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", color)
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.offset_left   = -320; lbl.offset_right  = 320
	lbl.offset_top    = base_top; lbl.offset_bottom = base_top + 26
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.z_index    = 50
	lbl.modulate.a = 0.0
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	_active_msgs.append(lbl)

	# Fade in, hold, fade out
	var tw := lbl.create_tween().set_parallel(true)
	tw.tween_property(lbl, "modulate:a", 1.0, 0.2)
	tw.chain().tween_interval(2.4)
	tw.chain().tween_property(lbl, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(func():
		_active_msgs.erase(lbl)
		if is_instance_valid(lbl): lbl.queue_free())


func _on_card_acquired(pid: int, creep_id: String) -> void:
	var my_pid : int = int(player.get("player_id")) if is_instance_valid(player) and "player_id" in player else 0
	if pid != my_pid: return
	show_card_acquired(creep_id)
	_refresh_deck_overlay()


func show_card_acquired(creep_id: String) -> void:
	var cdm := get_node_or_null("/root/CreepDeckManager")
	var def : Dictionary = {}
	if is_instance_valid(cdm): def = cdm.get_creep_def(creep_id)
	var icon_text : String = def.get("icon", "🃏")
	var card_name : String = def.get("name", creep_id.capitalize())

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sty := StyleBoxFlat.new()
	sty.bg_color = Color(0.04, 0.10, 0.06, 0.92)
	sty.set_border_width_all(2)
	sty.border_color = Color(0.20, 0.85, 0.40)
	sty.set_corner_radius_all(6)
	sty.content_margin_left = 10; sty.content_margin_right  = 10
	sty.content_margin_top  = 8;  sty.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sty)
	panel.z_index = 160

	var stack_offset := float(_card_popup_queue.size()) * -72.0
	panel.anchor_left   = 0.78; panel.anchor_right  = 0.78
	panel.anchor_top    = 0.50; panel.anchor_bottom = 0.50
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	panel.offset_left   = -60.0; panel.offset_right  = 60.0
	panel.offset_top    = -30.0 + stack_offset
	panel.offset_bottom =  30.0 + stack_offset
	panel.modulate.a    = 0.0
	add_child(panel)
	_card_popup_queue.append(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)

	var icon_lbl := Label.new()
	icon_lbl.text = icon_text
	icon_lbl.add_theme_font_size_override("font_size", 28)
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon_lbl)

	var plus_lbl := Label.new()
	plus_lbl.text = "+CARD"
	plus_lbl.add_theme_font_size_override("font_size", 11)
	plus_lbl.add_theme_color_override("font_color", Color(0.30, 1.0, 0.50))
	plus_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plus_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(plus_lbl)

	var name_lbl := Label.new()
	name_lbl.text = card_name
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.88, 0.92, 0.88))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_lbl)

	var float_dist := 64.0
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.2)
	tw.tween_property(panel, "offset_top",    panel.offset_top    - float_dist, 2.0).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(panel, "offset_bottom", panel.offset_bottom - float_dist, 2.0).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func():
		_card_popup_queue.erase(panel)
		if is_instance_valid(panel): panel.queue_free())


func show_hitmarker(headshot: bool = false) -> void:
	if not is_instance_valid(_hitmarker): return
	_hitmarker.visible = true
	# Color: red for headshot, white for normal
	var col : Color = Color(1.0, 0.22, 0.1) if headshot else Color(1.0, 1.0, 1.0)
	for child in _hitmarker.get_children():
		if child is ColorRect: (child as ColorRect).color = col
	if is_instance_valid(_hs_label):
		_hs_label.visible = headshot
	var tw := create_tween()
	tw.tween_interval(0.08)
	tw.tween_callback(func(): if is_instance_valid(_hitmarker): _hitmarker.visible = false)


func _build_crystal_hud() -> void:
	# Small crystal counter top-left
	_crystal_lbl = Label.new()
	_crystal_lbl.text = "✦ 0"
	_crystal_lbl.add_theme_font_size_override("font_size", 15)
	_crystal_lbl.add_theme_color_override("font_color", Color(0.75, 0.4, 1.0))
	_crystal_lbl.anchor_left   = 0.0; _crystal_lbl.anchor_right  = 0.2
	_crystal_lbl.anchor_top    = 0.0; _crystal_lbl.anchor_bottom = 0.0
	_crystal_lbl.offset_left   = 10;  _crystal_lbl.offset_top    = 48
	_crystal_lbl.offset_bottom = 72
	_crystal_lbl.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_crystal_lbl.z_index       = 200
	add_child(_crystal_lbl)
	# Flash overlay on pickup
	_crystal_flash = ColorRect.new()
	_crystal_flash.color = Color(0.6, 0.2, 1.0, 0.0)
	_crystal_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crystal_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crystal_flash.z_index = 180
	add_child(_crystal_flash)

func update_crystal_count(n: int) -> void:
	if is_instance_valid(_crystal_lbl): _crystal_lbl.text = "✦ %d" % n


# ── Sword charge bar ─────────────────────────────────────────
var _sword_bar  : ProgressBar = null
var _ult_bar    : ProgressBar = null
var _revive_lbl : Label       = null

func _build_combat_hud() -> void:
	# Sword durability bar — bottom left above weapon name
	_sword_bar = ProgressBar.new()
	_sword_bar.min_value = 0; _sword_bar.max_value = 100; _sword_bar.value = 100
	_sword_bar.anchor_left = 0.0; _sword_bar.anchor_right = 0.18
	_sword_bar.anchor_top  = 1.0; _sword_bar.anchor_bottom = 1.0
	_sword_bar.offset_top  = -68; _sword_bar.offset_bottom = -52
	_sword_bar.offset_left = 8;   _sword_bar.offset_right  = 0
	_sword_bar.add_theme_color_override("font_color", Color(0.9, 0.75, 0.2))
	_sword_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sword_bar.z_index = 200
	var sword_lbl := Label.new()
	sword_lbl.text = "⚔"; sword_lbl.add_theme_font_size_override("font_size", 9)
	sword_lbl.add_theme_color_override("font_color", Color(0.9, 0.75, 0.2))
	sword_lbl.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	sword_lbl.offset_top = -4; sword_lbl.offset_bottom = 4; sword_lbl.offset_left = 2
	sword_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sword_bar.add_child(sword_lbl)
	add_child(_sword_bar)

	# Revive counter top-right under gold
	_revive_lbl = Label.new()
	_revive_lbl.text = "💀 Revives: 5"
	_revive_lbl.add_theme_font_size_override("font_size", 12)
	_revive_lbl.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
	_revive_lbl.anchor_left = 0.65; _revive_lbl.anchor_right = 1.0
	_revive_lbl.anchor_top  = 0.0;  _revive_lbl.anchor_bottom = 0.0
	_revive_lbl.offset_top  = 50;   _revive_lbl.offset_bottom = 68
	_revive_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_revive_lbl.offset_right = -8
	_revive_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_lbl.z_index = 200
	_revive_lbl.visible = false   # only shown inside shop
	add_child(_revive_lbl)


func update_sword_charge(charge: float, max_charge: float) -> void:
	if not is_instance_valid(_sword_bar): return
	_sword_bar.max_value = max_charge
	_sword_bar.value     = charge
	var pct := charge / maxf(max_charge, 1.0)
	var col := Color(0.9, 0.75, 0.2) if pct > 0.4 else (Color(1.0, 0.55, 0.1) if pct > 0.15 else Color(0.9, 0.1, 0.1))
	_sword_bar.add_theme_color_override("font_color", col)


var _ult_button     : Control = null
var _ult_charge_bar : ProgressBar = null
var _ult_ready_lbl  : Label = null
var _ult_name_lbl   : Label = null
var _ult_was_ready  : bool  = false

func _build_ult_button() -> void:
	# Large standalone ULT button — center-bottom, just above the ability bar
	var root := Control.new()
	root.anchor_left   = 0.5
	root.anchor_right  = 0.5
	root.anchor_top    = 1.0
	root.anchor_bottom = 1.0
	root.offset_left   = -52
	root.offset_right  =  52
	root.offset_top    = -148
	root.offset_bottom = -94
	root.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	root.z_index       = 50   # below shop
	add_child(root)
	_ult_button = root

	# Background panel
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.04, 0.12, 0.92)
	sb.border_color = Color(0.5, 0.2, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(5)
	bg.add_theme_stylebox_override("panel", sb)
	root.add_child(bg)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(vb)

	# Per-class ult name label (updated via update_ult_charge)
	_ult_name_lbl = Label.new()
	_ult_name_lbl.text = "⚡ ULTIMATE  [V]"
	_ult_name_lbl.add_theme_font_size_override("font_size", 10)
	_ult_name_lbl.add_theme_color_override("font_color", Color(0.75, 0.5, 1.0))
	_ult_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ult_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_ult_name_lbl)

	# Charge bar
	_ult_charge_bar = ProgressBar.new()
	_ult_charge_bar.min_value = 0
	_ult_charge_bar.max_value = 100
	_ult_charge_bar.value     = 0
	_ult_charge_bar.show_percentage = false
	_ult_charge_bar.custom_minimum_size = Vector2(0, 7)
	var fill_s := StyleBoxFlat.new()
	fill_s.bg_color = Color(0.6, 0.2, 1.0)
	fill_s.set_corner_radius_all(3)
	var bg_s := StyleBoxFlat.new()
	bg_s.bg_color = Color(0.1, 0.05, 0.18)
	_ult_charge_bar.add_theme_stylebox_override("fill", fill_s)
	_ult_charge_bar.add_theme_stylebox_override("background", bg_s)
	_ult_charge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_ult_charge_bar)

	# "READY" / charge % label
	_ult_ready_lbl = Label.new()
	_ult_ready_lbl.text = "0%"
	_ult_ready_lbl.add_theme_font_size_override("font_size", 10)
	_ult_ready_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_ult_ready_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ult_ready_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_ult_ready_lbl)


func update_ult_charge(charge: float, max_charge: float, ult_name: String = "") -> void:
	if is_instance_valid(_ult_name_lbl) and ult_name != "":
		_ult_name_lbl.text = "⚡ %s  [V]" % ult_name
	# Update dedicated ult button
	var pct := int(clampf(charge / maxf(max_charge, 1.0) * 100.0, 0.0, 100.0))
	if is_instance_valid(_ult_charge_bar):
		_ult_charge_bar.max_value = max_charge
		_ult_charge_bar.value     = charge
		# Pulse border when ready
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(3)
		if charge >= max_charge:
			sb.bg_color = Color(1.0, 0.85, 0.1)
		else:
			sb.bg_color = Color(0.6, 0.2, 1.0)
		_ult_charge_bar.add_theme_stylebox_override("fill", sb)

	if is_instance_valid(_ult_ready_lbl):
		if charge >= max_charge:
			_ult_ready_lbl.text = "READY!"
			_ult_ready_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.1))
		else:
			_ult_ready_lbl.text = "%d%%" % pct
			_ult_ready_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))

	if is_instance_valid(_ult_button):
		if charge >= max_charge:
			# Glow border yellow when ready
			var panel := _ult_button.get_child(0) if _ult_button.get_child_count() > 0 else null
			if is_instance_valid(panel) and panel is PanelContainer:
				var s := StyleBoxFlat.new()
				s.bg_color = Color(0.10, 0.07, 0.04, 0.95)
				s.border_color = Color(1.0, 0.85, 0.1)
				s.set_border_width_all(3)
				s.set_corner_radius_all(5)
				(panel as PanelContainer).add_theme_stylebox_override("panel", s)
			if not _ult_was_ready:
				_ult_was_ready = true
				show_message("⚡ ULTIMATE READY! Press [V]", Color(1.0, 0.8, 0.1))
		else:
			_ult_was_ready = false
			var panel := _ult_button.get_child(0) if _ult_button.get_child_count() > 0 else null
			if is_instance_valid(panel) and panel is PanelContainer:
				var s := StyleBoxFlat.new()
				s.bg_color = Color(0.06, 0.04, 0.12, 0.92)
				s.border_color = Color(0.5, 0.2, 0.9)
				s.set_border_width_all(2)
				s.set_corner_radius_all(5)
				(panel as PanelContainer).add_theme_stylebox_override("panel", s)


func update_revive_count(n: int) -> void:
	if is_instance_valid(_revive_lbl):
		_revive_lbl.text = "💀 Revives: %d" % n
		_revive_lbl.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6) if n > 2 else Color(0.9, 0.3, 0.3))

func show_crystal_pickup() -> void:
	if not is_instance_valid(_crystal_flash): return
	var tw := create_tween()
	tw.tween_property(_crystal_flash, "color:a", 0.35, 0.05)
	tw.tween_property(_crystal_flash, "color:a", 0.0,  0.4)


# Enchant type → color + label
const DMG_TYPES := {
	0: {"col": Color(1.0, 1.0, 1.0),    "label": ""},
	1: {"col": Color(1.0, 0.45, 0.1),   "label": "🔥"},
	2: {"col": Color(0.3, 0.85, 1.0),   "label": "❄"},
	3: {"col": Color(0.3, 1.0, 0.2),    "label": "☠"},
	4: {"col": Color(1.0, 0.95, 0.1),   "label": "⚡"},
	5: {"col": Color(0.7, 0.1, 0.95),   "label": "✦"},
	6: {"col": Color(0.9, 0.1, 0.3),    "label": "🩸"},
	7: {"col": Color(1.0, 0.85, 0.2),   "label": "💥"},  # crit/headshot
}

func show_damage_number(amount: float, world_pos: Vector3, enchant_type: int = 0,
		base_dmg: float = 0.0, upgrade_bonus: float = 0.0, is_crit: bool = false) -> void:
	var cam := get_viewport().get_camera_3d()
	if not is_instance_valid(cam): return
	if cam.is_position_behind(world_pos): return
	var screen_pos : Vector2 = cam.unproject_position(world_pos)
	var type_data  : Dictionary = DMG_TYPES.get(enchant_type, DMG_TYPES[0])
	var col        : Color = type_data["col"]
	var icon       : String = type_data["label"]
	if is_crit: col = DMG_TYPES[7]["col"]
	# Main damage number
	var lbl := Label.new()
	var prefix : String = "💥 " if is_crit else (icon + " " if icon != "" else "")
	lbl.text = "%s%d" % [prefix, int(amount)]
	var font_sz : int = 22 if is_crit else (18 if amount >= 50 else 14)
	lbl.add_theme_font_size_override("font_size", font_sz)
	lbl.add_theme_color_override("font_color", col)
	lbl.position = screen_pos + Vector2(randf_range(-10, 10), 0)
	lbl.z_index = 300; lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	# Upgrade breakdown — show if upgrade bonus > 0
	if upgrade_bonus > 0.0:
		var bonus_lbl := Label.new()
		bonus_lbl.text = "(+%d upgrades)" % int(upgrade_bonus)
		bonus_lbl.add_theme_font_size_override("font_size", 10)
		bonus_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.5, 0.9))
		bonus_lbl.position = screen_pos + Vector2(randf_range(-8,8), -20)
		bonus_lbl.z_index = 299; bonus_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bonus_lbl)
		var btw := create_tween().set_parallel(true)
		btw.tween_property(bonus_lbl, "position:y", bonus_lbl.position.y - 35.0, 0.8)
		btw.tween_property(bonus_lbl, "modulate:a", 0.0, 0.8)
		btw.chain().tween_callback(bonus_lbl.queue_free)
	# Enchant type label
	if enchant_type != 0 and not is_crit and icon != "":
		var type_lbl := Label.new()
		type_lbl.text = _enchant_type_name(enchant_type)
		type_lbl.add_theme_font_size_override("font_size", 9)
		type_lbl.add_theme_color_override("font_color", Color(col.r, col.g, col.b, 0.8))
		type_lbl.position = screen_pos + Vector2(randf_range(-8,8), 14)
		type_lbl.z_index = 299; type_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(type_lbl)
		var ttw := create_tween().set_parallel(true)
		ttw.tween_property(type_lbl, "position:y", type_lbl.position.y - 30.0, 0.7)
		ttw.tween_property(type_lbl, "modulate:a", 0.0, 0.7)
		ttw.chain().tween_callback(type_lbl.queue_free)
	# Main float
	var rise : float = 65.0 if is_crit else 48.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", screen_pos.y - rise, 0.75).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.75)
	tw.chain().tween_callback(lbl.queue_free)

func _enchant_type_name(t: int) -> String:
	match t:
		1: return "FIRE"
		2: return "ICE"
		3: return "POISON"
		4: return "ELECTRIC"
		5: return "SHADOW"
		6: return "VAMPIRIC"
		_: return ""


func update_ability_timers(slots: Array, cooldowns: Array) -> void:
	# Update existing ability bar timers if present
	var ab_bar := find_child("AbilityBar", true, false)
	if not is_instance_valid(ab_bar): return
	for slot in 1:
		if slot >= slots.size(): break
		var panel := ab_bar.find_child("Slot%d" % slot, true, false)
		if not is_instance_valid(panel): continue
		var timer_lbl := panel.find_child("TimerLbl", true, false) as Label
		if not is_instance_valid(timer_lbl): continue
		var cd : float = cooldowns[slot] if slot < cooldowns.size() else 0.0
		var data = slots[slot] if slot < slots.size() else null
		if data != null and data.get("duration", 0.0) > 0.0 and cd > 0.0:
			timer_lbl.text = "%.1fs" % cd
			timer_lbl.visible = true
		else:
			timer_lbl.visible = false


func _build_minimap_OLD() -> void:
	_minimap = Control.new()
	_minimap.name = "Minimap"
	_minimap.anchor_left   = 0.78; _minimap.anchor_right  = 1.0
	_minimap.anchor_top    = 0.0;  _minimap.anchor_bottom = 0.22
	_minimap.offset_right  = -8.0; _minimap.offset_top    = 8.0
	_minimap.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_minimap.z_index       = 110
	add_child(_minimap)

	# Background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.07, 0.10, 0.82)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.add_child(bg)

	# Border
	var border := Panel.new()
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0,0,0,0)
	sbox.set_border_width_all(1); sbox.border_color = Color(0.3, 0.6, 0.4, 0.7)
	border.add_theme_stylebox_override("panel", sbox)
	_minimap.add_child(border)

	# Label
	var lbl := Label.new()
	lbl.text = "MAP"
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.6, 0.5))
	lbl.anchor_left = 0.0; lbl.anchor_top = 0.0
	lbl.offset_left = 4; lbl.offset_top = 2
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.add_child(lbl)

	set_process(true)


func _update_minimap() -> void:
	# ── NEW: fill the _MinimapNode cache so _draw() doesn't need get_nodes_in_group ──
	if is_instance_valid(_minimap_draw):
		var mn := _minimap_draw as _MinimapNode

		# Use the HUD's own bound player — never global pl[0] which breaks P2 minimap.
		# If no player is bound yet, fall back to first in group.
		var lp : Node3D = player as Node3D if (is_instance_valid(player) and player is Node3D) else null
		if lp == null:
			var pl := get_tree().get_nodes_in_group("players")
			if pl.size() > 0: lp = pl[0] as Node3D

		var my_tid : int = 1
		if is_instance_valid(lp):
			mn.mm_player_pos = lp.global_position
			my_tid = int(lp.get("team_id") if "team_id" in lp else 1)
			mn.mm_player_tid = my_tid
			# Use player body rotation.y — always correct in FPS and top-down modes.
			if "rotation" in lp:
				mn.mm_player_yaw = (lp as Node3D).rotation.y
			# Fill bases
			mn.mm_bases.clear()
			for b in get_tree().get_nodes_in_group("bases"):
				if not (b is Node3D) or not is_instance_valid(b): continue
				var bt : int = int(b.get("team_id") if "team_id" in b else 0)
				mn.mm_bases.append({"pos": (b as Node3D).global_position, "friendly": bt == my_tid})

			# Fill units — scan players and non-zombie units separately from zombies.
			# The old single scan with an 80-cap would fill up with bases/turrets/allies
			# before reaching zombie entries, making enemies invisible on the map.
			mn.mm_units.clear()

			# Players (always shown regardless of cap)
			for p in get_tree().get_nodes_in_group("players"):
				if not is_instance_valid(p) or p == lp: continue
				var ut : int = int(p.get("team_id") if "team_id" in p else 0)
				mn.mm_units.append({"pos": (p as Node3D).global_position,
					"friendly": ut == my_tid, "is_player": true})

			# Non-zombie units (turrets, minions, etc.) — capped at 40
			var unit_count := 0
			for u in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(u) or u == lp: continue
				if u.is_in_group("zombies") or u.is_in_group("players"): continue
				if unit_count >= 40: break
				var ut : int = int(u.get("team_id") if "team_id" in u else 0)
				mn.mm_units.append({"pos": (u as Node3D).global_position,
					"friendly": ut == my_tid, "is_player": false})
				unit_count += 1

			# Active Z1 zombies — scan "zombies" group directly, capped at 150
			var zcount := 0
			for z in get_tree().get_nodes_in_group("zombies"):
				if not is_instance_valid(z): continue
				if zcount >= 150: break
				var zt : int = int(z.get("team_id") if "team_id" in z else 2)
				mn.mm_units.append({"pos": (z as Node3D).global_position,
					"friendly": zt == my_tid, "is_player": false})
				zcount += 1

			# Fill hive units (egg-spawned enemies — always red)
			mn.mm_hive_units.clear()
			var hu_count := 0
			for hu in get_tree().get_nodes_in_group("hive_unit"):
				if not is_instance_valid(hu) or not (hu is Node3D): continue
				if hu_count >= 60: break
				mn.mm_hive_units.append({"pos": (hu as Node3D).global_position})
				hu_count += 1

			# Fill hive clusters
			mn.mm_hives.clear()
			for hc in get_tree().get_nodes_in_group("hive_clusters"):
				if not is_instance_valid(hc) or not (hc is Node3D): continue
				mn.mm_hives.append({
					"pos":     (hc as Node3D).global_position,
					"tier":    int(hc.get("tier") if "tier" in hc else 1),
					"cleared": bool(hc.get("_cleared") if "_cleared" in hc else false)
				})

			# Fill eggs
			mn.mm_eggs.clear()
			for eg in get_tree().get_nodes_in_group("eggs"):
				if not is_instance_valid(eg) or not (eg is Node3D): continue
				mn.mm_eggs.append({"pos": (eg as Node3D).global_position})

			# Fill crowd zombie dots (Z2+Z3 — unloaded but shown on minimap)
			mn.mm_crowd_zombies.clear()
			if Engine.has_singleton("ZombieHordeManager"):
				var _zhm = Engine.get_singleton("ZombieHordeManager")
				if _zhm.has_method("get_crowd_positions"):
					for _zp in _zhm.get_crowd_positions(200):
						mn.mm_crowd_zombies.append(_zp)

			# Density cluster map — 15-unit grid cells, built every 0.5s for heat-dot overlay
			mn.mm_clusters.clear()
			if Engine.has_singleton("ZombieHordeManager"):
				var _zhm_c = Engine.get_singleton("ZombieHordeManager")
				var cg : Dictionary = {}
				var csz : float = 15.0
				var enemy_tid : int = 2 if my_tid == 1 else 1
				for ze in _zhm_c.get_z1_active_by_team(enemy_tid):
					if not is_instance_valid(ze): continue
					var zp3 : Vector3 = (ze as Node3D).global_position
					var ck := Vector2i(int(zp3.x / csz), int(zp3.z / csz))
					cg[ck] = int(cg.get(ck, 0)) + 1
				if _zhm_c.has_method("get_crowd_positions"):
					for zp3 in _zhm_c.get_crowd_positions(500):
						var ck := Vector2i(int(zp3.x / csz), int(zp3.z / csz))
						cg[ck] = int(cg.get(ck, 0)) + 1
				for ck in cg.keys():
					var cnt : int = int(cg.get(ck, 0))
					if cnt < 1: continue
					var wx : float = (float(ck.x) + 0.5) * csz
					var wz : float = (float(ck.y) + 0.5) * csz
					mn.mm_clusters.append({"pos": Vector3(wx, 0.0, wz), "count": cnt})

			mn.mm_valid = true
		else:
			mn.mm_valid = false

	# ── OLD minimap (dot-based) — superseded by _MinimapNode._draw() ───────────
	# _minimap now points to the real container; _MinimapNode handles all rendering.


func reveal_minimap_area(world_pos: Vector3, radius: float) -> void:
	if not is_instance_valid(_minimap_draw): return
	var mn := _minimap_draw as _MinimapNode
	# Avoid duplicate reveals at same position
	for rev in mn.mm_revealed:
		if (rev.pos as Vector3).distance_to(world_pos) < radius * 0.5: return
	mn.mm_revealed.append({"pos": world_pos, "radius": radius})
	mn.queue_redraw()


func _set_map_label(id: String, pos: Vector2, text: String, col: Color) -> void:
	if not is_instance_valid(_minimap): return
	var lbl : Label
	if id in _minimap_dots and is_instance_valid(_minimap_dots[id]):
		lbl = _minimap_dots[id] as Label
	else:
		lbl = Label.new(); lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_font_size_override("font_size", 8)
		_minimap.add_child(lbl); _minimap_dots[id] = lbl
	lbl.text = text; lbl.position = pos
	lbl.add_theme_color_override("font_color", col)


func _set_map_arrow(id: String, center: Vector2, angle: float, col: Color) -> void:
	# Draws a small arrow (thin rect) pointing in the given 2D angle
	if not is_instance_valid(_minimap): return
	var dot : ColorRect
	if id in _minimap_dots and is_instance_valid(_minimap_dots[id]):
		dot = _minimap_dots[id] as ColorRect
	else:
		dot = ColorRect.new()
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Arrow: tall thin rect, pivot at center-bottom so it points outward
		dot.size          = Vector2(3, 10)
		dot.pivot_offset  = Vector2(1.5, 8)  # rotate from near-bottom center
		_minimap.add_child(dot)
		_minimap_dots[id] = dot
	dot.color    = col
	dot.rotation = angle
	dot.position = center - dot.pivot_offset  # center the pivot on the player dot
	dot.position = dot.position.clamp(Vector2.ZERO, _minimap.size - dot.size)

func _set_map_dot(id: String, pos: Vector2, col: Color, sz: int) -> void:
	if not is_instance_valid(_minimap): return
	var dot : ColorRect
	if id in _minimap_dots and is_instance_valid(_minimap_dots[id]):
		dot = _minimap_dots[id] as ColorRect
	else:
		dot = ColorRect.new()
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_minimap.add_child(dot)
		_minimap_dots[id] = dot
	dot.color = col
	dot.size  = Vector2(sz, sz)
	dot.position = pos - Vector2(sz * 0.5, sz * 0.5)
	dot.position = dot.position.clamp(Vector2.ZERO, _minimap.size - dot.size)


func _build_grapple_ui() -> void:
	_grapple_ui = Control.new()
	_grapple_ui.name = "GrappleUI"
	_grapple_ui.anchor_left   = 0.0; _grapple_ui.anchor_right  = 0.15
	_grapple_ui.anchor_top    = 0.55; _grapple_ui.anchor_bottom = 0.65
	_grapple_ui.offset_left   = 8.0; _grapple_ui.offset_right  = 0.0
	_grapple_ui.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_grapple_ui.z_index       = 90
	_grapple_ui.visible       = false
	add_child(_grapple_ui)

	# Background
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.05, 0.07, 0.1, 0.88)
	sbox.set_border_width_all(1); sbox.border_color = Color(0.3, 0.85, 0.5, 0.7)
	sbox.set_corner_radius_all(4)
	bg.add_theme_stylebox_override("panel", sbox)
	_grapple_ui.add_child(bg)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 3)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(vb)

	var icon_lbl := Label.new()
	icon_lbl.text = "🪝 GRAPPLE"
	icon_lbl.add_theme_font_size_override("font_size", 11)
	icon_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	icon_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(icon_lbl)

	var hint := Label.new()
	hint.text = "LMB: Fire  RMB: Release"
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(hint)

	# Cooldown bar
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.1, 0.1, 0.12)
	bar_bg.custom_minimum_size = Vector2(0, 6)
	bar_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(bar_bg)

	_grapple_cd_bar = ColorRect.new()
	_grapple_cd_bar.name = "CdBar"
	_grapple_cd_bar.color = Color(0.3, 0.9, 0.5)
	_grapple_cd_bar.custom_minimum_size = Vector2(0, 6)
	_grapple_cd_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grapple_cd_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.add_child(_grapple_cd_bar)

	var cd_lbl := Label.new()
	cd_lbl.name = "CdLbl"
	cd_lbl.text = "READY"
	cd_lbl.add_theme_font_size_override("font_size", 10)
	cd_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	cd_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cd_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cd_lbl)


func show_grapple_ui(visible_flag: bool) -> void:
	if is_instance_valid(_grapple_ui): _grapple_ui.visible = visible_flag


func update_grapple_cooldown(remaining: float, total: float) -> void:
	if not is_instance_valid(_grapple_ui): return
	# total = active_window (10s green) or cooldown_time (45s orange)
	var is_window : bool = total <= 12.0  # window is 10s, cooldown is 45s
	var ratio : float = clampf(remaining / maxf(total, 0.01), 0.0, 1.0)
	if is_instance_valid(_grapple_cd_bar):
		_grapple_cd_bar.anchor_right = ratio
		_grapple_cd_bar.color = Color(0.2, 0.9, 0.4) if is_window else \
			(Color(0.3, 1.0, 0.5) if remaining <= 0.0 else Color(0.9, 0.5, 0.15))
	var lbl := _grapple_ui.find_child("CdLbl", true, false) as Label
	if is_instance_valid(lbl):
		if is_window:
			lbl.text = "ACTIVE %.0fs" % remaining
			lbl.add_theme_color_override("font_color", Color(0.2, 1.0, 0.5))
		elif remaining <= 0.0:
			lbl.text = "READY"
			lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
		else:
			lbl.text = "%.0fs" % remaining
			lbl.add_theme_color_override("font_color", Color(1.0, 0.55, 0.2))


func _build_kill_feed() -> void:
	var scr : Script = null
	for path in ["res://scripts/KillFeed.gd", "res://KillFeed.gd"]:
		if ResourceLoader.exists(path): scr = load(path) as Script; break
	if not is_instance_valid(scr): return
	var kf := Control.new()
	kf.set_script(scr)
	kf.name = "KillFeed"
	add_child(kf)

func _build_respawn_screen() -> void:
	var scr := load("res://scripts/RespawnScreen.gd") if ResourceLoader.exists("res://scripts/RespawnScreen.gd") else null
	if not is_instance_valid(scr): scr = load("res://RespawnScreen.gd") if ResourceLoader.exists("res://RespawnScreen.gd") else null
	if is_instance_valid(scr):
		var rs := CanvasLayer.new(); rs.set_script(scr); get_tree().root.add_child(rs)


func _build_quest_panel() -> void:
	_quest_panel = Control.new()
	_quest_panel.name = "ActiveQuests"
	# Anchor to top-right corner; grow left from the right edge
	_quest_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_quest_panel.offset_left   = -248.0
	_quest_panel.offset_top    = 8.0
	_quest_panel.offset_right  = -8.0
	_quest_panel.offset_bottom = 408.0
	_quest_panel.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_quest_panel.z_index       = 90
	add_child(_quest_panel)
	var vbox := VBoxContainer.new()
	vbox.name = "QVBox"
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quest_panel.add_child(vbox)
	var hdr := Label.new()
	hdr.name = "Header"
	hdr.text = "▸ ACTIVE QUESTS"
	hdr.add_theme_font_size_override("font_size", 10)
	hdr.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3, 0.9))
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hdr)


func _refresh_quests(pid: int) -> void:
	if not is_instance_valid(_quest_panel): return
	var vbox := _quest_panel.find_child("QVBox", true, false) as VBoxContainer
	if not is_instance_valid(vbox): return
	for key in _quest_rows.keys():
		if is_instance_valid(_quest_rows[key]):
			(_quest_rows[key] as Node).queue_free()
	_quest_rows.clear()
	var qm : Node = get_tree().get_first_node_in_group("quest_manager")
	if not is_instance_valid(qm): return
	var quests : Array = []
	if qm.has_method("get_active_quests"): quests = qm.get_active_quests(pid)
	for q in quests.slice(0, 5):
		if q is Dictionary and q.has("id") and q.has("label"):
			_add_quest_row(vbox, q, pid)


func _add_quest_row(vbox: VBoxContainer, q: Dictionary, pid: int) -> void:
	var qm := get_tree().get_first_node_in_group("quest_manager")
	var qid : String = str(q.get("id", ""))
	if qid.is_empty(): return
	# Container
	var panel := PanelContainer.new()
	panel.name = "QRow_" + qid
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.04, 0.05, 0.08, 0.82)
	sbox.set_border_width_all(1)
	sbox.border_color = Color(0.28, 0.38, 0.55, 0.7)
	sbox.set_corner_radius_all(4)
	sbox.content_margin_left = 7; sbox.content_margin_right  = 7
	sbox.content_margin_top  = 4; sbox.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", sbox)
	vbox.add_child(panel)
	_quest_rows[qid] = panel
	# Inner layout
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(col)
	# Title
	var title := Label.new()
	var icon : String = str(q.get("icon", "◈"))
	var label_text : String = str(q.get("label", qid))
	title.text = icon + "  " + label_text
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.95, 0.90, 0.80))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.clip_text = true
	col.add_child(title)
	# Progress bar (visual)
	var prog_row := HBoxContainer.new()
	prog_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(prog_row)
	var cur : int = 0
	var tgt : int = int(q.get("target", 1))
	if is_instance_valid(qm) and qm.has_method("get_progress"):
		cur = int(qm.get_progress(pid, qid))
	var ratio : float = clampf(float(cur) / float(maxi(tgt, 1)), 0.0, 1.0)
	# Mini progress bar
	var bar_bg := Panel.new()
	bar_bg.custom_minimum_size = Vector2(0, 5)
	bar_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_sty := StyleBoxFlat.new()
	bar_sty.bg_color = Color(0.15, 0.15, 0.18)
	bar_sty.set_corner_radius_all(2)
	bar_bg.add_theme_stylebox_override("panel", bar_sty)
	prog_row.add_child(bar_bg)
	var bar_fill := Panel.new(); bar_fill.name = "ProgBar"
	bar_fill.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill_sty := StyleBoxFlat.new()
	fill_sty.bg_color = Color(0.2, 0.7, 0.35) if ratio < 1.0 else Color(0.9, 0.75, 0.2)
	fill_sty.set_corner_radius_all(2)
	bar_fill.add_theme_stylebox_override("panel", fill_sty)
	bar_fill.anchor_left = 0.0; bar_fill.anchor_right = ratio
	bar_fill.anchor_top  = 0.0; bar_fill.anchor_bottom = 1.0
	bar_fill.offset_left = 0; bar_fill.offset_right  = 0
	bar_fill.offset_top  = 0; bar_fill.offset_bottom = 0
	bar_bg.add_child(bar_fill)
	# Count + rewards text
	var prog := Label.new(); prog.name = "Prog"
	var gold : int = int(q.get("reward_gold", 0))
	var crys : int = int(q.get("reward_crystals", 0))
	prog.text = "%d/%d" % [cur, tgt]
	if gold > 0 or crys > 0:
		prog.text += "  +" + (str(gold)+"🪙 " if gold>0 else "") + (str(crys)+"✦" if crys>0 else "")
	prog.add_theme_font_size_override("font_size", 10)
	prog.add_theme_color_override("font_color",
		Color(0.9, 0.8, 0.2) if ratio >= 1.0 else Color(0.5, 0.78, 0.55))
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(prog)


func _on_quest_progress(q: Dictionary, pid: int, current: int) -> void:
	var my_pid : int = int(player.get("player_id") if is_instance_valid(player) and "player_id" in player else 0)
	if pid != my_pid: return
	var row := _quest_panel.find_child("QRow_" + q["id"], true, false) if is_instance_valid(_quest_panel) else null
	if not is_instance_valid(row): return
	var prog := row.find_child("Prog", true, false) as Label
	if is_instance_valid(prog):
		prog.text = "%d / %d  •  +%d🪙  +%d✦" % [current, q["target"], q.get("reward_gold",0), q.get("reward_crystals",0)]


func _on_quest_completed(q: Dictionary, pid: int) -> void:
	var my_pid : int = int(player.get("player_id") if is_instance_valid(player) and "player_id" in player else 0)
	if pid != my_pid: return
	_show_quest_complete(q)
	get_tree().create_timer(2.0).timeout.connect(func(): _refresh_quests(pid))


func _on_new_quests(_quests: Array) -> void:
	var pid : int = int(player.get("player_id") if is_instance_valid(player) and "player_id" in player else 0)
	_refresh_quests(pid)


func _show_quest_complete(q: Dictionary) -> void:
	var lbl := Label.new()
	lbl.text = "✦ QUEST: %s\n+%d🪙  +%d✦" % [q["label"], q.get("reward_gold",0), q.get("reward_crystals",0)]
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	lbl.set_anchors_preset(Control.PRESET_CENTER)
	lbl.offset_left = -280; lbl.offset_right = 280
	lbl.offset_top  = -50;  lbl.offset_bottom = 10
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.z_index = 500; lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lbl)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - 50, 2.0).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 2.0).set_delay(1.2)
	tw.chain().tween_callback(lbl.queue_free)


func _show_death_screen() -> void:
	if not is_instance_valid(_death_screen): return
	_death_screen.visible = true
	var overlay := _death_screen.get_node_or_null("Overlay") as ColorRect
	if overlay:
		var tw := create_tween()
		tw.tween_property(overlay, "color", Color(0.0, 0.0, 0.0, 0.65), 0.6)
	# Animate died label scale
	var lbl := _death_screen.find_child("DiedLabel", true, false) as Label
	if lbl:
		lbl.scale = Vector2(0.5, 0.5); lbl.pivot_offset = lbl.size * 0.5
		var tw2 := create_tween()
		tw2.tween_property(lbl, "scale", Vector2(1.0, 1.0), 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	# Start countdown
	_tick_death_countdown(3.0)


func _tick_death_countdown(remaining: float) -> void:
	if not is_instance_valid(_death_timer_lbl): return
	_death_timer_lbl.text = "Respawning in %.0f..." % ceilf(remaining)
	if remaining > 0.1:
		get_tree().create_timer(0.1).timeout.connect(
			func(): _tick_death_countdown(remaining - 0.1), CONNECT_ONE_SHOT)


func play_respawn_glow() -> void:
	# Green pulsing overlay on respawn
	var glow := ColorRect.new()
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.color = Color(0.0, 1.0, 0.2, 0.0)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.z_index = 180
	add_child(glow)
	var tw := create_tween()
	tw.tween_property(glow, "color", Color(0.0, 1.0, 0.2, 0.45), 0.25)
	tw.tween_property(glow, "color", Color(0.0, 1.0, 0.2, 0.0),  0.25)
	tw.tween_property(glow, "color", Color(0.0, 1.0, 0.2, 0.35), 0.2)
	tw.tween_property(glow, "color", Color(0.0, 1.0, 0.2, 0.0),  0.5)
	tw.tween_callback(glow.queue_free)


func _hide_death_screen() -> void:
	if not is_instance_valid(_death_screen): return
	var overlay := _death_screen.get_node_or_null("Overlay") as ColorRect
	if overlay:
		var tw := create_tween()
		tw.tween_property(overlay, "color", Color(0.0, 0.0, 0.0, 0.0), 0.4)
		tw.tween_callback(func(): _death_screen.visible = false)
	else:
		_death_screen.visible = false


# ── Scope visibility helpers — called by SniperScope ────────
var _scope_hidden_nodes : Array = []   # nodes hidden when scoped

func hide_for_scope() -> void:
	_scope_hidden_nodes.clear()
	for ch in get_children():
		if not (ch is CanvasItem): continue
		# Never touch squad panel — it has its own visibility rules
		if is_instance_valid(_squad_panel) and ch == _squad_panel: continue
		if (ch as CanvasItem).visible:
			(ch as CanvasItem).visible = false
			_scope_hidden_nodes.append(ch)
	if is_instance_valid(crosshair): crosshair.visible = false

func show_for_scope() -> void:
	for ch in _scope_hidden_nodes:
		if is_instance_valid(ch): (ch as CanvasItem).visible = true
	_scope_hidden_nodes.clear()
	# Squad panel remains hidden — only shown in topdown mode


func _build_squad_panel() -> void:
	var scp_script := load("res://scenes/SquadCommandPanel.gd")
	if not is_instance_valid(scp_script):
		scp_script = load("res://scripts/SquadCommandPanel.gd")
	var scp := Control.new()
	scp.set_script(scp_script)
	scp.name = "SquadCommandPanel"
	# Add as child of self so find_child() can locate it throughout this script.
	# Position is driven manually every frame by _process() so anchors don't matter.
	add_child(scp)
	_squad_panel = scp
	scp.visible = false
	# Re-hide after deferred _ready/_build_ui runs
	call_deferred("_force_squad_panel_position", scp)
	get_tree().create_timer(0.0).timeout.connect(func(): if is_instance_valid(scp): scp.visible = false)
	get_tree().create_timer(0.1).timeout.connect(func():
		if is_instance_valid(scp): _force_squad_panel_position(scp))
	# Store refs for legacy code that calls _squad_set_status / _refresh_squad_count
	call_deferred("_link_squad_refs")



func _force_squad_panel_position(scp: Node) -> void:
	if not is_instance_valid(scp) or not (scp is Control): return
	var sc := scp as Control
	var vp  : Vector2 = get_viewport_rect().size
	# Left-side vertical panel: narrow fixed width, tall enough for all buttons
	var pw  : float = 160.0
	var ph  : float = 290.0
	sc.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	sc.anchor_left   = 0.0; sc.anchor_right  = 0.0
	sc.anchor_top    = 0.0; sc.anchor_bottom = 0.0
	sc.offset_left   = 0.0; sc.offset_right  = 0.0
	sc.offset_top    = 0.0; sc.offset_bottom = 0.0
	sc.size          = Vector2(pw, ph)
	sc.position      = Vector2(8.0, vp.y * 0.25)
	sc.z_index       = 50
	sc.mouse_filter  = Control.MOUSE_FILTER_IGNORE


func _link_squad_refs() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if not is_instance_valid(scp): return
	_squad_count_lbl  = scp._count_label
	_squad_status_lbl = scp._status_label
	if is_instance_valid(player): scp.bind_player(player)
func _build_hurt_flash() -> void:
	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(0.75, 0.05, 0.08, 0.0)
	_hurt_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hurt_flash.z_index = 200
	add_child(_hurt_flash)


func _build_low_health_vignette() -> void:
	_low_health_vignette = ColorRect.new()
	_low_health_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_low_health_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_low_health_vignette.z_index = 190   # below hurt flash (200)
	_low_health_vignette.visible = false
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nuniform float strength : hint_range(0.0,1.0) = 0.0;\nvoid fragment() {\n\tvec2 uv = UV - vec2(0.5);\n\tfloat v = clamp(pow(length(uv) * 1.8, 2.2), 0.0, 1.0);\n\tCOLOR = vec4(0.35, 0.0, 0.0, v * strength);\n}"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_low_health_vignette.material = mat
	add_child(_low_health_vignette)


# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	# Squad panel — left side, vertical layout
	if is_instance_valid(_squad_panel) and _squad_panel is Control:
		var _sc  := _squad_panel as Control
		var _vps := get_viewport().get_visible_rect().size
		var _pw  := 160.0
		var _ph  := (290.0 if not _squad_minimized else 22.0)
		_sc.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_sc.position = Vector2(8.0, _vps.y * 0.25)
		_sc.size     = Vector2(_pw, _ph)
		_sc.z_index  = 60

	_enemy_timer   -= delta
	_health_timer  -= delta
	_ammo_timer    -= delta
	_ability_timer -= delta

	if _enemy_timer <= 0.0:
		_enemy_timer = ENEMY_INTERVAL
		var ec := _count_enemies()
		if ec != _last_enemy_count:
			_last_enemy_count = ec
			if is_instance_valid(zombies_label):
				zombies_label.text = "🧟 %d" % ec
				zombies_label.add_theme_color_override("font_color", C_RED if ec > 0 else C_DIM)

	if _health_timer <= 0.0:
		_health_timer = HEALTH_INTERVAL
		if is_instance_valid(player):
			var hp  := _f(player,"health"); var mhp := _f(player,"max_health")
			if hp != _last_hp or mhp != _last_max_hp: _on_player_health_changed(hp, mhp)
		if is_instance_valid(base):
			var bhp  := _f(base,"health_value"); var bmhp := _f(base,"max_health")
			if bhp != _last_base_hp or bmhp != _last_base_max_hp: _on_base_health_changed(bhp, bmhp)

	if _ammo_timer <= 0.0:
		_ammo_timer = AMMO_INTERVAL
		_poll_ammo()

	if _ability_timer <= 0.0:
		_ability_timer = ABILITY_INTERVAL
		_tick_ability_bars()
		_tick_class_ability_hud()

	if _sel_mode_active:
		_process_sel_ray(delta)
	_minimap_timer -= delta
	if _minimap_timer <= 0.0:
		_minimap_timer = 0.5   # 2fps minimap refresh — matches 0.5s heat-dot spec
		_update_minimap()
		if is_instance_valid(_minimap_draw): _minimap_draw.queue_redraw()
	_turret_tick(delta)
	# Poll squad count periodically as backup if signal missed
	if _enemy_timer <= 0.0 and is_instance_valid(_horde_mgr):
		var sel_count : int = _horde_mgr.get_selected().size()
		if is_instance_valid(_squad_count_lbl):
			_squad_count_lbl.text = "🧟 %d sel" % sel_count
		# Also sync to SquadCommandPanel count label
		var scp := find_child("SquadCommandPanel", true, false)
		if not is_instance_valid(scp) and is_instance_valid(get_parent()):
			for ch in get_parent().get_children():
				if "SquadCommandPanel" in ch.name: scp = ch; break
		if is_instance_valid(scp) and scp.has_method("_refresh_count"):
			scp._refresh_count(sel_count)


# ============================================================
# SQUAD COMMANDS — each calls ZombieHordeManager
# ============================================================

func _squad_select_all() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp):
		scp._on_select_all()
	elif is_instance_valid(_horde_mgr):
		var my_units : Array = _horde_mgr.get_z1_active_by_team(team_id)
		_horde_mgr.select(my_units)
func _squad_attack() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp): scp._on_attack()

func _squad_defend() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp): scp._on_defend()

func _squad_patrol() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp): scp._on_patrol()

func _squad_stay() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp): scp._on_stay()

func _squad_follow() -> void:
	var scp := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(scp): scp._on_follow()

func _squad_cancel_pending() -> void:
	# Finalise patrol via SquadCommandPanel if collecting points
	if _in_patrol_set:
		var _scp3 := find_child("SquadCommandPanel", true, false) as Node
		if is_instance_valid(_scp3) and _scp3.has_method("_cancel_pending"):
			_scp3._cancel_pending()
		_squad_set_status("↺ Patrol cancelled.")
		_patrol_pts.clear()
	_pending_cmd = ""; _in_patrol_set = false
	_squad_unhighlight_all()

func _get_current_selection() -> Array:
	if is_instance_valid(_horde_mgr):
		var sel : Array = _horde_mgr.get_selected()
		if not sel.is_empty(): return sel
	return _local_selected

func _has_selected() -> bool:
	var sel : Array = _get_current_selection()
	if sel.is_empty():
		# Auto-select all team zombies rather than failing silently
		_squad_select_all()
		sel = _get_current_selection()
		if sel.is_empty():
			_squad_set_status("No zombies found! Buy some first.")
			return false
	return true

func _on_selection_changed(selected: Array) -> void:
	_refresh_squad_count(selected.size())

func _refresh_squad_count(n: int = -1) -> void:
	if n < 0 and is_instance_valid(_horde_mgr): n = _horde_mgr.get_selected().size()
	if is_instance_valid(_squad_count_lbl):
		_squad_count_lbl.text = "🧟 %d sel" % maxi(n, 0)

func _squad_set_status(text: String) -> void:
	if is_instance_valid(_squad_status_lbl): _squad_status_lbl.text = text


# ── Pending command execution (ground click) ─────────────────
func _execute_pending_click(screen_pos: Vector2) -> void:
	var world_pos := _screen_to_ground(screen_pos)
	if world_pos == Vector3.ZERO:
		_squad_cancel_pending(); return
	var scp2 := find_child("SquadCommandPanel", true, false) as Node
	match _pending_cmd:
		"attack":
			if is_instance_valid(scp2): scp2._execute_pending_at_screen(_world_to_screen(world_pos))
			_squad_set_status("⚔ Attacking!")
			_pending_cmd = ""; _squad_unhighlight_all()
		"defend":
			if is_instance_valid(scp2): scp2._execute_pending_at_screen(_world_to_screen(world_pos))
			_squad_set_status("🛡 Defending!")
			_pending_cmd = ""; _squad_unhighlight_all()
		"patrol_add":
			_patrol_pts.append(world_pos)
			_squad_set_status("↺ Pt %d added. [3]/ESC to finish." % _patrol_pts.size())


# ── Box select helpers ────────────────────────────────────────
func _box_down(pos: Vector2) -> void:
	if _pending_cmd != "": _execute_pending_click(pos); return
	_box_selecting = true; _box_start = pos
	if is_instance_valid(_box_rect):
		_box_rect.visible = true; _box_rect.position = pos; _box_rect.size = Vector2.ZERO

func _box_up(pos: Vector2) -> void:
	if not _box_selecting: return
	_box_selecting = false
	if is_instance_valid(_box_rect): _box_rect.visible = false
	var sz := pos - _box_start
	if sz.length() < 8.0: return  # too small — ignore
	if not is_instance_valid(_horde_mgr): return
	var cam := _get_cam(); if not cam: return
	var vp_sz := get_viewport().get_visible_rect().size
	var nmin := Vector2(minf(_box_start.x,pos.x)/vp_sz.x, minf(_box_start.y,pos.y)/vp_sz.y)
	var nmax := Vector2(maxf(_box_start.x,pos.x)/vp_sz.x, maxf(_box_start.y,pos.y)/vp_sz.y)
	var _scp4 := find_child("SquadCommandPanel", true, false) as Node
	if is_instance_valid(_scp4) and _scp4.has_method("_on_lmb_up"): pass  # SCP owns box select

func _box_update(pos: Vector2) -> void:
	if not is_instance_valid(_box_rect): return
	var tl := Vector2(minf(_box_start.x,pos.x), minf(_box_start.y,pos.y))
	var br  := Vector2(maxf(_box_start.x,pos.x), maxf(_box_start.y,pos.y))
	if is_instance_valid(_box_rect): _box_rect.position = tl; _box_rect.size = br - tl

func _screen_to_ground(sp: Vector2) -> Vector3:
	var cam := _get_cam(); if not cam: return Vector3.ZERO
	var space := get_viewport().get_world_3d().direct_space_state
	if not space: return Vector3.ZERO
	var from  := cam.project_ray_origin(sp)
	var to    := from + cam.project_ray_normal(sp) * 300.0
	var hit   := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	return hit.get("position", Vector3.ZERO)

func _world_to_screen(world_pos: Vector3) -> Vector2:
	var cam := _get_cam()
	if not is_instance_valid(cam): return Vector2.ZERO
	if cam.is_position_behind(world_pos): return Vector2.ZERO
	return cam.unproject_position(world_pos)

func _get_cam() -> Camera3D:
	if is_instance_valid(player):
		var c := player.get_node_or_null("Head/Camera3D") as Camera3D
		if c: return c
	return get_viewport().get_camera_3d()


# ── Direct unit command fallback (no HordeManager needed) ────
func _cmd_units_direct(units: Array, mode: String, dest: Vector3) -> void:
	for u in units:
		if not is_instance_valid(u): continue
		if dest != Vector3.ZERO:
			if "move_target"     in u: u.move_target     = dest
			if "has_move_target" in u: u.has_move_target = true
		if u.has_method("set_ai_mode"):
			match mode:
				"attack": u.call("set_ai_mode", 1)
				"defend": u.call("set_ai_mode", 2)
				"patrol": u.call("set_ai_mode", 3)
				"stay":   u.call("set_ai_mode", 4)
				"follow": u.call("set_ai_mode", 0)
		elif mode == "stay" and "velocity" in u:
			u.velocity = Vector3.ZERO
		# Trigger run anim
		var at := u.get_node_or_null("AnimationTree") as AnimationTree
		if is_instance_valid(at) and at.active:
			for p in ["parameters/move_blend/blend_position","parameters/Locomotion/blend_position"]:
				var v = at.get(p)
				if v != null:
					at.set(p, Vector2(0.0,1.0) if v is Vector2 else 1.0)
					break

func _find_nearest_enemy_pos() -> Vector3:
	if not is_instance_valid(player): return Vector3.ZERO
	var origin : Vector3 = (player as Node3D).global_position
	var best   : Node3D  = null
	var best_d : float   = 9999.0
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.team_id) == team_id: continue
		var d : float = origin.distance_to((u as Node3D).global_position)
		if d < best_d: best_d = d; best = u as Node3D
	return best.global_position if is_instance_valid(best) else Vector3.ZERO

func _find_friendly_base_pos() -> Vector3:
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and "team_id" in b and int(b.team_id) == team_id:
			return (b as Node3D).global_position
	return Vector3.ZERO


# ── Squad button helpers ──────────────────────────────────────
func _squad_btn(text: String, color: Color, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_color_override("font_color", Color(0.92,0.88,0.82))
	btn.focus_mode = Control.FOCUS_NONE
	var s := StyleBoxFlat.new(); s.bg_color = color * Color(1,1,1,0.65); s.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", s); btn.add_theme_stylebox_override("pressed", s)
	var h := StyleBoxFlat.new(); h.bg_color = color; h.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("hover", h)
	btn.pressed.connect(cb); return btn

func _squad_highlight(btn: Button) -> void:
	_squad_unhighlight_all()
	if not is_instance_valid(btn): return
	var s := StyleBoxFlat.new(); s.bg_color = Color(0.9,0.9,0.2,0.9); s.set_corner_radius_all(3)
	s.set_border_width_all(2); s.border_color = Color.WHITE
	btn.add_theme_stylebox_override("normal", s)

func _squad_unhighlight_all() -> void:
	for pair in [[_squad_atk_btn,C_ATK],[_squad_def_btn,C_DEF],[_squad_pat_btn,C_PAT],
				 [_squad_stay_btn,C_STAY],[_squad_follow_btn,C_FOLLOW]]:
		var btn : Button = pair[0]; var col : Color = pair[1]
		if not is_instance_valid(btn): continue
		var s := StyleBoxFlat.new(); s.bg_color = col*Color(1,1,1,0.65); s.set_corner_radius_all(3)
		btn.add_theme_stylebox_override("normal", s)


# ============================================================
# ABILITY SLOTS
# ============================================================
func _refresh_ability_slots() -> void:
	if not is_instance_valid(player) or _ability_panels.is_empty(): return
	for i in 1:
		if i >= _ability_panels.size(): break
		var data = player.ability_slots[i]
		var icon_lbl : Label       = _ability_icons[i]   if i < _ability_icons.size()   else null
		var name_lbl : Label       = _ability_names[i]   if i < _ability_names.size()   else null
		var cd_lbl   : Label       = _ability_cd_lbls[i] if i < _ability_cd_lbls.size() else null
		var cd_bar   : ProgressBar = _ability_cd_bars[i] if i < _ability_cd_bars.size() else null
		var panel    : Control     = _ability_panels[i]
		if not is_instance_valid(icon_lbl): continue
		if data == null:
			icon_lbl.text = SLOT_ICONS[i]; icon_lbl.add_theme_color_override("font_color", C_DIM)
			if name_lbl: name_lbl.text = "— Empty —\nFind trinkets near base!"; name_lbl.add_theme_color_override("font_color", C_DIM)
			if cd_lbl:   cd_lbl.text = "EMPTY";       cd_lbl.add_theme_color_override("font_color", C_DIM)
			if cd_bar:   cd_bar.value = 0.0
			var s := panel.get_theme_stylebox("panel") as StyleBoxFlat
			if s: s.border_color = SLOT_COLORS[i] * Color(1,1,1,0.3)
		else:
			icon_lbl.text = SLOT_ICONS[i]
			icon_lbl.add_theme_color_override("font_color", SLOT_COLORS[i])
			var ability_name : String = data.get("name", "?")
			var ability_desc : String = data.get("desc", "")
			if name_lbl:
				name_lbl.text = ability_name if ability_desc.is_empty() 					else ability_name + "\n" + ability_desc
				name_lbl.add_theme_color_override("font_color", C_TEXT)
			if cd_lbl: cd_lbl.text = "READY"; cd_lbl.add_theme_color_override("font_color", C_GREEN)
			if cd_bar: cd_bar.value = 1.0
			var s := panel.get_theme_stylebox("panel") as StyleBoxFlat
			if s: s.border_color = SLOT_COLORS[i]

func _tick_ability_bars() -> void:
	if not is_instance_valid(player): return
	var t : float = Time.get_ticks_msec() / 1000.0
	for i in 1:
		if i >= _ability_cd_bars.size(): break
		var cd_bar : ProgressBar = _ability_cd_bars[i]
		var cd_lbl : Label   = _ability_cd_lbls[i]  if i < _ability_cd_lbls.size()  else null
		var panel  : Control = _ability_panels[i]    if i < _ability_panels.size()   else null
		if not is_instance_valid(cd_bar): continue
		var data = player.ability_slots[i]
		if data == null: continue
		var cd     : float = player.ability_cooldowns[i]
		var cd_max : float = data.get("cooldown", 1.0)

		# Check if this ability is currently active (effect timer > 0)
		var is_active : bool = false
		match i:
			0: is_active = player.is_rapid_fire() or player.is_double_damage() or 						   player._berserk_timer > 0.0
			1: is_active = player.is_shielded() or player._ghost_timer > 0.0 or 						   player._sprint_boost_timer > 0.0
			2: is_active = player._sprint_boost_timer > 0.0 or player._ghost_timer > 0.0

		if cd <= 0.0:
			cd_bar.value = 1.0
			if cd_lbl:
				cd_lbl.text = "READY"
				cd_lbl.add_theme_color_override("font_color", C_GREEN)
			# Flash panel border when active
			if is_instance_valid(panel):
				var s := panel.get_theme_stylebox("panel") as StyleBoxFlat
				if is_instance_valid(s):
					if is_active:
						# Pulsing glow: oscillate border width and brightness
						var pulse : float = (sin(t * 6.0) * 0.5 + 0.5)
						s.border_width_left   = int(lerp(2.0, 5.0, pulse))
						s.border_width_right  = int(lerp(2.0, 5.0, pulse))
						s.border_width_top    = int(lerp(2.0, 5.0, pulse))
						s.border_width_bottom = int(lerp(2.0, 5.0, pulse))
						s.border_color = SLOT_COLORS[i].lerp(Color.WHITE, pulse * 0.5)
						s.bg_color = SLOT_COLORS[i] * Color(1,1,1, lerp(0.15, 0.35, pulse))
					else:
						s.set_border_width_all(2)
						s.border_color = SLOT_COLORS[i]
						s.bg_color = Color(0.06, 0.07, 0.10, 0.95)
		else:
			cd_bar.value = clampf(1.0 - (cd / cd_max), 0.0, 1.0)
			if cd_lbl:
				cd_lbl.text = "%.0fs" % cd
				cd_lbl.add_theme_color_override("font_color", C_ORANGE)
			if is_instance_valid(panel):
				var s := panel.get_theme_stylebox("panel") as StyleBoxFlat
				if is_instance_valid(s):
					s.set_border_width_all(2)
					s.border_color = SLOT_COLORS[i] * Color(1,1,1,0.4)
					s.bg_color = Color(0.06, 0.07, 0.10, 0.95)


# ============================================================
# HEALTH / BASE
# ============================================================
func _on_player_health_changed(cur: float, max_val: float) -> void:
	if _last_hp > 0.0 and cur < _last_hp: _hurt_flash_trigger()
	_update_low_health_vignette(cur, max_val)
	_last_hp = cur; _last_max_hp = max_val
	if is_instance_valid(hp_bar):
		hp_bar.max_value = max_val; hp_bar.value = cur
		var r := cur/max_val if max_val > 0.0 else 1.0
		hp_bar.add_theme_color_override("fill_color", C_RED if r <= 0.25 else C_ORANGE if r <= 0.5 else C_GREEN)
	if is_instance_valid(hp_label):
		hp_label.text = "%d/%d" % [int(cur), int(max_val)]

func _on_base_health_changed(cur: float, max_val: float) -> void:
	_last_base_hp = cur; _last_base_max_hp = max_val
	if is_instance_valid(base_bar) and max_val > 0.0:
		base_bar.max_value = max_val; base_bar.value = cur
	if is_instance_valid(base_label):
		base_label.text = "%d/%d" % [int(cur), int(max_val)]

func _hurt_flash_trigger() -> void:
	if not is_instance_valid(_hurt_flash): return
	if _flash_tween and _flash_tween.is_running(): _flash_tween.kill()
	_hurt_flash.color = Color(0.75, 0.05, 0.08, 0.45)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_hurt_flash, "color:a", 0.0, 0.35)


func _update_low_health_vignette(cur: float, max_val: float) -> void:
	if not is_instance_valid(_low_health_vignette): return
	var mat := _low_health_vignette.material as ShaderMaterial
	if not is_instance_valid(mat): return
	var pct : float = cur / maxf(max_val, 1.0)
	if pct >= _VIGNETTE_THRESHOLD:
		_low_health_vignette.visible = false
		if _vignette_tween and _vignette_tween.is_valid(): _vignette_tween.kill()
		_vignette_tween = null
		_vignette_pulsing = false
		mat.set_shader_parameter("strength", 0.0)
		return
	_low_health_vignette.visible = true
	var base_s : float = (1.0 - pct / _VIGNETTE_THRESHOLD) * _VIGNETTE_MAX_STRENGTH
	if pct <= _VIGNETTE_PULSE_HP:
		if not _vignette_pulsing:
			_vignette_pulsing = true
			if _vignette_tween and _vignette_tween.is_valid(): _vignette_tween.kill()
			var lo : float = maxf(base_s - 0.18, 0.0)
			var hi : float = minf(base_s + 0.18, 1.0)
			_vignette_tween = create_tween().set_loops()
			_vignette_tween.tween_method(func(s: float): mat.set_shader_parameter("strength", s), lo, hi, 0.9)
			_vignette_tween.tween_method(func(s: float): mat.set_shader_parameter("strength", s), hi, lo, 0.9)
	else:
		if _vignette_pulsing:
			_vignette_pulsing = false
			if _vignette_tween and _vignette_tween.is_valid(): _vignette_tween.kill()
			_vignette_tween = null
		mat.set_shader_parameter("strength", base_s)


# ============================================================
# WEAPON / AMMO
# ============================================================
func _on_weapon_changed(gun: Node) -> void: _apply_gun(gun)

func _apply_gun(gun: Node) -> void:
	current_gun = gun; _last_ammo = -1; _last_max_ammo = -1
	if not is_instance_valid(gun):
		if gun_name_label: gun_name_label.text = "NO WEAPON"
		if ammo_label:     ammo_label.text = "--"
		_update_crosshair_for_gun(null)
		return
	if gun_name_label: gun_name_label.text = gun.name.replace("_"," ").to_upper()
	if gun.has_signal("ammo_changed") and not gun.ammo_changed.is_connected(_on_ammo_changed):
		gun.ammo_changed.connect(_on_ammo_changed)
	_update_crosshair_for_gun(gun)
	_poll_ammo()


func _update_crosshair_for_gun(gun: Node) -> void:
	if not is_instance_valid(crosshair): return
	var name_lower := gun.name.to_lower() if is_instance_valid(gun) else ""
	if "sniper" in name_lower:
		crosshair.text = "◎"
		crosshair.add_theme_font_size_override("font_size", 22)
		crosshair.add_theme_color_override("font_color", Color(0.9, 0.9, 0.1, 0.95))
	elif "shotgun" in name_lower or "shot" in name_lower:
		crosshair.text = "⊕"
		crosshair.add_theme_font_size_override("font_size", 32)
		crosshair.add_theme_color_override("font_color", Color(1.0, 0.5, 0.1, 0.9))
	elif "pistol" in name_lower or "handgun" in name_lower:
		crosshair.text = "⊞"
		crosshair.add_theme_font_size_override("font_size", 26)
		crosshair.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 0.85))
	elif "rocket" in name_lower or "launcher" in name_lower or "rpg" in name_lower:
		crosshair.text = "⊗"
		crosshair.add_theme_font_size_override("font_size", 30)
		crosshair.add_theme_color_override("font_color", Color(1.0, 0.3, 0.1, 0.9))
	elif "sword" in name_lower or "blade" in name_lower or "melee" in name_lower:
		crosshair.text = "⬦"
		crosshair.add_theme_font_size_override("font_size", 28)
		crosshair.add_theme_color_override("font_color", Color(0.7, 0.75, 1.0, 0.85))
	elif "grapple" in name_lower or "hook" in name_lower:
		crosshair.text = "✛"
		crosshair.add_theme_font_size_override("font_size", 32)
		crosshair.add_theme_color_override("font_color", Color(0.4, 1.0, 0.65, 0.9))
	elif "flame" in name_lower or "thrower" in name_lower or "fire" in name_lower:
		crosshair.text = "🔥"
		crosshair.add_theme_font_size_override("font_size", 28)
		crosshair.add_theme_color_override("font_color", Color(1.0, 0.45, 0.1, 0.95))
	elif "basegun" in name_lower or "base_gun" in name_lower or name_lower == "gun":
		crosshair.text = "+"
		crosshair.add_theme_font_size_override("font_size", 30)
		crosshair.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0, 0.9))
	elif "smg" in name_lower or "machine" in name_lower or "uzi" in name_lower:
		crosshair.text = "┼"
		crosshair.add_theme_font_size_override("font_size", 24)
		crosshair.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7, 0.85))
	elif "rifle" in name_lower or "ar" == name_lower or "assault" in name_lower:
		crosshair.text = "┼"
		crosshair.add_theme_font_size_override("font_size", 26)
		crosshair.add_theme_color_override("font_color", Color(0.6, 1.0, 0.9, 0.85))
	else:
		crosshair.text = "┼"
		crosshair.add_theme_font_size_override("font_size", 28)
		crosshair.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98, 0.85))

func _poll_ammo() -> void:
	if not is_instance_valid(current_gun): return
	var a  := _i(current_gun,"current_ammo") if "current_ammo" in current_gun else _i(current_gun,"ammo")
	var ma := _i(current_gun,"max_ammo")
	if a != _last_ammo or ma != _last_max_ammo: _on_ammo_changed(a, ma)

func _on_ammo_changed(cur: int, max_val: int) -> void:
	_last_ammo = cur; _last_max_ammo = max_val
	if not is_instance_valid(ammo_label): return
	var ratio := float(cur)/float(max_val) if max_val > 0 else 1.0
	ammo_label.add_theme_color_override("font_color", C_RED if ratio <= 0.25 else C_ORANGE)
	ammo_label.text = "%d/%d" % [cur,max_val] if max_val > 0 else "%d" % cur


# ============================================================
# SIGNALS / SYNC
# ============================================================
func _connect_signals() -> void:
	if is_instance_valid(player):
		_sig(player, "health_changed",    _on_player_health_changed)
		_sig(player, "crystals_changed",  update_crystal_count)
		_sig(player, "abilities_changed", _refresh_ability_slots)
		_sig(player, "died",              func(): _show_death_screen())
		if player.has_signal("respawned"):
			_sig(player, "respawned", func(): _hide_death_screen())

	if is_instance_valid(base): _sig(base, "health_changed", _on_base_health_changed)
	if is_instance_valid(game_manager):
		_sig(game_manager, "money_changed",        _on_money_changed)
		_sig(game_manager, "gold_awarded",         _on_gold_awarded)
		_sig(game_manager, "prep_time_updated",    _on_prep_time_updated)
		_sig(game_manager, "ready_updated",        _on_ready_updated)
		_sig(game_manager, "match_started_signal", _on_match_started)
		_sig(game_manager, "show_phase_label",     _on_show_phase_label)
		_sig(game_manager, "round_announced",      _on_round_announced)
		_sig(game_manager, "wave_choice_open",     _on_wave_choice_open)
		_sig(game_manager, "wave_choice_closed",   _on_wave_choice_closed)
		_sig(game_manager, "round_started",        _on_round_started)
		_sig(game_manager, "wave_launched",        _on_wave_launched)
		_sig(game_manager, "round_ended",          _on_round_ended)
		_sig(game_manager, "game_over",            _on_game_over)
		_sig(game_manager, "phase_timer_updated",  _on_phase_timer_updated)
	var _cdm := get_node_or_null("/root/CreepDeckManager")
	if is_instance_valid(_cdm):
		_sig(_cdm, "card_acquired", _on_card_acquired)
		_sig(_cdm, "deck_chosen", func(_pid: int, _deck: Array): _refresh_deck_overlay())

# ── Round / Wave handlers ─────────────────────────────────────
var _completed_waves  : Array      = []
var _wave_buttons     : Dictionary = {}
var _deploy_wave_num  : int        = 1
var _waves_this_round : int        = 0   # updated by _on_wave_choice_open
var _creep_btn_list   : Array      = []   # [{scene, cost}] for keybind access



# ── Wave panel edge icon ─────────────────────────────────────────
var _wave_tab_icon : Button = null

func _build_wave_tab_icon() -> void:
	# Remove old icon if it exists
	if is_instance_valid(_wave_tab_icon): _wave_tab_icon.queue_free()
	var btn := Button.new()
	btn.name = "WaveTabIcon"
	# Anchor to right edge, vertically centered
	btn.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	btn.offset_left  = -90
	btn.offset_right = 0
	btn.offset_top   = -28
	btn.offset_bottom = 28
	btn.z_index = 160
	btn.focus_mode = Control.FOCUS_NONE
	# Style
	var sty := StyleBoxFlat.new()
	sty.bg_color = Color(0.06, 0.08, 0.16, 0.92)
	sty.set_corner_radius_all(6)
	sty.set_border_width_all(1)
	sty.border_color = Color(0.3, 0.6, 1.0)
	sty.corner_radius_top_left    = 6
	sty.corner_radius_bottom_left = 6
	sty.corner_radius_top_right   = 0
	sty.corner_radius_bottom_right = 0
	btn.add_theme_stylebox_override("normal", sty)
	btn.add_theme_stylebox_override("hover",  sty)
	btn.add_theme_stylebox_override("pressed", sty)
	btn.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	btn.add_theme_font_size_override("font_size", 10)
	_update_icon_text(btn)
	btn.pressed.connect(func():
		if is_instance_valid(_wave_choice_panel):
			_wave_choice_panel.visible = not _wave_choice_panel.visible
			_update_wave_tab_icon())
	add_child(btn)
	_wave_tab_icon = btn

func _update_wave_tab_icon() -> void:
	if is_instance_valid(_wave_tab_icon):
		_update_icon_text(_wave_tab_icon)

func _update_icon_text(btn: Button) -> void:
	var open : bool = is_instance_valid(_wave_choice_panel) and _wave_choice_panel.visible
	btn.text = "⚔\n%s\nShift+Q" % ("CLOSE" if open else "WAVES")
	var sty := btn.get_theme_stylebox("normal") as StyleBoxFlat
	if is_instance_valid(sty):
		sty.border_color = Color(0.9, 0.6, 0.2) if open else Color(0.3, 0.6, 1.0)

func _on_round_announced(round_num: int, hordes: int, waves: int, label: String) -> void:
	_completed_waves.clear()
	_wave_buttons.clear()
	_show_round_card(round_num, hordes, waves, label)

func _on_wave_choice_open(waves: int, default_wave: int, time_left: float) -> void:
	# Wave spawning interface is versus-mode only
	var gs := get_node_or_null("/root/GameSettings")
	var mode : String = gs.get("game_mode") if is_instance_valid(gs) and "game_mode" in gs else "original"
	if mode != "versus": return
	_deploy_wave_num  = default_wave
	_waves_this_round = waves
	var _was_visible : bool = is_instance_valid(_wave_choice_panel) and _wave_choice_panel.visible
	_build_wave_choice_panel(waves, default_wave, time_left)
	if is_instance_valid(_wave_choice_panel):
		_wave_choice_panel.visible = _was_visible
		_update_wave_tab_icon()
	# NOTE: deck is chosen once at game start — not reopened each wave

func _on_wave_choice_closed() -> void:
	pass  # panel stays — buttons grey out as waves complete

func _on_round_started(_round_num: int) -> void:
	pass  # panel stays visible during combat

func _on_wave_launched(_round: int, wave_num: int, horde_size: int) -> void:
	_show_wave_countdown(wave_num, horde_size)   # 3-2-1-GO overlay; "incoming!" fires at GO
	_completed_waves.append(wave_num)
	if wave_num in _wave_buttons:
		var btn : Button = _wave_buttons[wave_num]
		if is_instance_valid(btn):
			var s := StyleBoxFlat.new()
			s.bg_color = Color(0.08,0.08,0.08,0.5); s.set_corner_radius_all(4)
			btn.add_theme_stylebox_override("normal", s)
			btn.add_theme_color_override("font_color", Color(0.3,0.3,0.3))
			btn.text = "✓ %d" % wave_num
			btn.disabled = true

func _on_round_ended(round_num: int, gold_reward: int) -> void:
	show_message("Round %d complete  +%d gold" % [round_num, gold_reward], Color(0.9, 0.85, 0.2))

func _on_game_over(winner_team: int) -> void:
	_play_victory_music(winner_team == team_id)
	GameOverScreen.show_result(winner_team, team_id)

func _play_victory_music(is_winner: bool) -> void:
	# Stop all existing music
	for ap in get_tree().get_nodes_in_group("music"):
		if ap is AudioStreamPlayer: (ap as AudioStreamPlayer).stop()
	# Create a new music player
	var mus := AudioStreamPlayer.new()
	mus.bus = "Music"
	mus.volume_db = -6.0
	add_child(mus)
	# Try to load victory/defeat music from common paths
	var paths : Array = []
	if is_winner:
		paths = ["res://audio/victory.ogg","res://audio/victory.mp3",
				"res://sounds/victory.ogg","res://music/victory.ogg",
				"res://audio/win.ogg","res://audio/win.mp3"]
	else:
		paths = ["res://audio/defeat.ogg","res://audio/defeat.mp3",
				"res://sounds/defeat.ogg","res://music/defeat.ogg",
				"res://audio/lose.ogg","res://audio/lose.mp3"]
	for p in paths:
		if ResourceLoader.exists(p):
			mus.stream = load(p); mus.play(); return
	# Fallback: procedural fanfare via programmatic tone (skip if no audio)
	print("[HUD] Victory/defeat music not found — searched: %s" % str(paths))

func _go_to_main_menu() -> void:
	# CRITICAL: unpause and free mouse before any scene change
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Engine.time_scale = 1.0  # reset hit-stop if active
	for path in ["res://scenes/MainMenu.tscn","res://MainMenu.tscn","res://main_menu.tscn",
				"res://scenes/main_menu.tscn","res://ui/MainMenu.tscn"]:
		if ResourceLoader.exists(path):
			get_tree().change_scene_to_file(path); return
	print("[HUD] Main menu not found — reload current scene")
	get_tree().reload_current_scene()



func _show_round_card(round_num: int, hordes: int, waves: int, label: String) -> void:
	if is_instance_valid(_round_card): _round_card.queue_free()

	# Full-width banner at the TOP — out of the way, slides down then fades
	var card := PanelContainer.new()
	card.name = "RoundCard"
	card.anchor_left   = 0.0;  card.anchor_right  = 1.0
	card.anchor_top    = 0.0;  card.anchor_bottom = 0.0
	card.offset_top    = -120; card.offset_bottom = 0    # start offscreen above
	card.z_index = 180
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.12, 0.94)
	style.border_color = Color(1.0, 0.65, 0.1, 0.9)
	style.border_width_bottom = 2
	style.content_margin_left = 24; style.content_margin_right  = 24
	style.content_margin_top  = 10; style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", style)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)
	_round_card = card

	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 32)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(hb)

	# Round number badge
	var round_lbl := Label.new()
	round_lbl.text = "ROUND %d" % round_num
	round_lbl.add_theme_font_size_override("font_size", 11)
	round_lbl.add_theme_color_override("font_color", Color(1.0, 0.65, 0.1))
	hb.add_child(round_lbl)

	var sep1 := Label.new(); sep1.text = "—"
	sep1.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	hb.add_child(sep1)

	# Round name (biggest element)
	var name_lbl := Label.new()
	name_lbl.text = label
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.82))
	hb.add_child(name_lbl)

	var sep2 := Label.new(); sep2.text = "—"
	sep2.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	hb.add_child(sep2)

	# Stats
	var info_lbl := Label.new()
	info_lbl.text = "⚔ %d enemies  ·  🌊 %d waves" % [hordes, waves]
	info_lbl.add_theme_font_size_override("font_size", 12)
	info_lbl.add_theme_color_override("font_color", Color(0.65, 0.70, 0.90))
	hb.add_child(info_lbl)

	# Slide down into view then fade out
	var tw := card.create_tween()
	tw.tween_property(card, "offset_top", 40.0, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(3.5)
	tw.tween_property(card, "modulate:a", 0.0, 0.6)
	tw.tween_callback(func():
		if is_instance_valid(_round_card): _round_card.queue_free())


func _build_wave_choice_panel(waves: int, default_wave: int, time_left: float) -> void:
	if is_instance_valid(_wave_choice_panel): _wave_choice_panel.queue_free()
	_wave_buttons.clear()
	var panel := PanelContainer.new()
	panel.name = "WaveChoicePanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_left = -370; panel.offset_right  = -8
	panel.offset_top  = -340; panel.offset_bottom = -8
	panel.z_index = 150
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.12, 0.96)
	style.set_border_width_all(2); style.border_color = Color(0.3, 0.6, 1.0)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false  # hidden by default — open with Shift+Q
	add_child(panel)
	_wave_choice_panel = panel
	_build_wave_tab_icon()
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 8)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(vb)

	# Title
	var title := Label.new()
	title.text = "⚔  DEPLOY WAVE"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var sub := Label.new()
	sub.text = "Choose which wave your creeps launch on"
	sub.add_theme_font_size_override("font_size", 10)
	sub.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)

	# Wave selector buttons row
	var wave_row := HBoxContainer.new()
	wave_row.alignment = BoxContainer.ALIGNMENT_CENTER
	wave_row.add_theme_constant_override("separation", 6)
	vb.add_child(wave_row)

	for i in waves:
		var w   : int    = i + 1
		var btn := Button.new()
		btn.text = "Wave %d" % w
		btn.custom_minimum_size = Vector2(70, 36)
		btn.add_theme_font_size_override("font_size", 12)
		btn.focus_mode = Control.FOCUS_NONE
		if w in _completed_waves:
			btn.disabled = true
			var s := StyleBoxFlat.new()
			s.bg_color = Color(0.08,0.08,0.08,0.5); s.set_corner_radius_all(4)
			btn.add_theme_stylebox_override("normal", s)
			btn.add_theme_color_override("font_color", Color(0.3,0.3,0.3))
			btn.text = "✓ %d" % w
		elif w == default_wave:
			_style_wave_btn_selected(btn)
		else:
			_style_wave_btn_normal(btn)
		_wave_buttons[w] = btn
		var _w := w
		btn.pressed.connect(func(): _select_deploy_wave(_w, panel))
		wave_row.add_child(btn)

	# Separator
	var sep := HSeparator.new()
	sep.modulate = Color(0.25, 0.35, 0.55)
	vb.add_child(sep)

	# Creep deploy buttons — from shop
	var creep_title := Label.new()
	creep_title.text = "QUEUE CREEPS  (deploy on Wave %d)" % _deploy_wave_num
	creep_title.name = "CreepTitle"
	creep_title.add_theme_font_size_override("font_size", 11)
	creep_title.add_theme_color_override("font_color", Color(0.8, 0.85, 0.5))
	creep_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(creep_title)

	var creep_scroll := ScrollContainer.new()
	creep_scroll.custom_minimum_size = Vector2(0, 120)
	creep_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	creep_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(creep_scroll)

	var creep_grid := GridContainer.new()
	creep_grid.columns = 3
	creep_grid.add_theme_constant_override("h_separation", 6)
	creep_grid.add_theme_constant_override("v_separation", 6)
	creep_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	creep_scroll.add_child(creep_grid)

	_populate_creep_buttons(creep_grid)

	# Keybind hint
	var hint := Label.new()
	hint.text = "[1-%d] Wave  •  [Shift+1-9] Queue creep  •  [Shift+Q] Close" % waves
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.4, 0.45, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

	# Queue count label
	var queue_lbl := Label.new()
	queue_lbl.name = "QueueLabel"
	queue_lbl.text = "Queued: 0 creeps"
	queue_lbl.add_theme_font_size_override("font_size", 10)
	queue_lbl.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	queue_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(queue_lbl)


# Fallback creep catalogue — shown if CreepDeckManager not found in group
const _CREEP_FALLBACK : Array = [
	{"id":"zombie",     "name":"Zombie",     "tier":"base",     "cost":50,  "icon":"🧟"},
	{"id":"tank",       "name":"Tank",       "tier":"base",     "cost":150, "icon":"🛡"},
	{"id":"berserker",  "name":"Berserker",  "tier":"base",     "cost":120, "icon":"⚡"},
	{"id":"shaman",     "name":"Shaman",     "tier":"base",     "cost":130, "icon":"💚"},
	{"id":"leaper",     "name":"Leaper",     "tier":"base",     "cost":100, "icon":"🦘"},
	{"id":"bomber",     "name":"Bomber",     "tier":"advanced", "cost":200, "icon":"💣"},
	{"id":"ghost",      "name":"Ghost",      "tier":"advanced", "cost":180, "icon":"👻"},
	{"id":"goliath",    "name":"Goliath",    "tier":"advanced", "cost":350, "icon":"🗿"},
	{"id":"assassin",   "name":"Assassin",   "tier":"advanced", "cost":220, "icon":"🗡"},
	{"id":"hunter",     "name":"Hunter",     "tier":"advanced", "cost":160, "icon":"🏹"},
	{"id":"necromancer","name":"Necromancer","tier":"advanced", "cost":300, "icon":"💀"},
	{"id":"titan",      "name":"Titan",      "tier":"advanced", "cost":500, "icon":"🔥"},
]

func _populate_creep_buttons(grid: GridContainer) -> void:
	_creep_btn_list.clear()
	# Try CreepDeckManager first, fall back to inline catalogue
	var creep_dicts : Array = []
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("get_all_creeps"):
		creep_dicts = dm.get_all_creeps()
	if creep_dicts.is_empty():
		creep_dicts = _CREEP_FALLBACK

	for i in creep_dicts.size():
		var cd : Dictionary = creep_dicts[i]
		var kbind : String = "[%d]" % (i + 1) if i < 9 else "[%s]" % char(65 + (i - 9))
		var btn := Button.new()
		var tier_mark : String = "" if cd.get("tier","base") == "base" else "★"
		btn.text = "%s%s %s\n%dg" % [tier_mark, kbind, cd.get("name","?"), cd.get("cost", 100)]
		btn.custom_minimum_size = Vector2(108, 48)
		btn.add_theme_font_size_override("font_size", 10)
		btn.focus_mode = Control.FOCUS_NONE
		var bs := StyleBoxFlat.new()
		var is_adv : bool = cd.get("tier","base") != "base"
		bs.bg_color = Color(0.12, 0.08, 0.08, 0.9) if is_adv else Color(0.08, 0.12, 0.08, 0.9)
		bs.set_corner_radius_all(4); bs.set_border_width_all(1)
		bs.border_color = Color(0.7, 0.4, 0.2) if is_adv else Color(0.3, 0.6, 0.3)
		btn.add_theme_stylebox_override("normal", bs)
		btn.add_theme_color_override("font_color",
			Color(1.0, 0.8, 0.5) if is_adv else Color(0.8, 1.0, 0.7))
		var _id  : String = cd.get("id","")
		var _co2 : int    = cd.get("cost", 100)
		_creep_btn_list.append({"id": _id, "cost": _co2})
		btn.pressed.connect(func(): _queue_creep_by_id(_id, _co2, _wave_choice_panel))
		grid.add_child(btn)

func _queue_creep_by_id(creep_id: String, cost: int, panel: Control) -> void:
	# Queue by ID — LaneSpawner resolves the scene/script at spawn time.
	# This avoids needing a .tscn for every creep type.
	_queue_creep_for_wave(null, cost, panel, creep_id)

func _queue_creep_for_wave(scene: PackedScene, cost: int, panel: Control, creep_id: String = "") -> void:
	if not is_instance_valid(game_manager): return
	if not game_manager.spend_gold(team_id, cost):
		show_message("Not enough gold!", Color(1.0, 0.3, 0.3)); return
	var ls := get_tree().get_first_node_in_group("lane_spawner")
	if is_instance_valid(ls) and ls.has_method("queue_player_creep"):
		ls.queue_player_creep(team_id, scene, _deploy_wave_num, creep_id)
	var _cnt : int = ls.get_player_queue_count(team_id) if is_instance_valid(ls) and ls.has_method("get_player_queue_count") else 0
	if is_instance_valid(panel):
		var ql := panel.find_child("QueueLabel", true, false)
		if is_instance_valid(ql): (ql as Label).text = "Queued: %d creep%s for Wave %d" % [_cnt, "s" if _cnt != 1 else "", _deploy_wave_num]
	show_message("Queued %d creep%s for Wave %d!" % [_cnt, "s" if _cnt != 1 else "", _deploy_wave_num], Color(0.5, 1.0, 0.5))

func _style_wave_btn_selected(btn: Button) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.2, 0.5, 1.0, 0.9); s.set_corner_radius_all(4)
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_color_override("font_color", Color.WHITE)

func _style_wave_btn_normal(btn: Button) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.1, 0.12, 0.2, 0.8); s.set_corner_radius_all(4)
	s.set_border_width_all(1); s.border_color = Color(0.3, 0.4, 0.6)
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))

func _select_deploy_wave(wave: int, panel: Control) -> void:
	_deploy_wave_num = wave
	if is_instance_valid(game_manager) and game_manager.has_method("player_choose_wave"):
		game_manager.player_choose_wave(wave)
	# Update wave button visuals
	for w in _wave_buttons:
		var btn : Button = _wave_buttons[w]
		if not is_instance_valid(btn) or btn.disabled: continue
		if w == wave: _style_wave_btn_selected(btn)
		else:         _style_wave_btn_normal(btn)
	# Update creep title
	if is_instance_valid(panel):
		var ct := panel.get_node_or_null("VBoxContainer/CreepTitle")
		if is_instance_valid(ct): (ct as Label).text = "QUEUE CREEPS  (deploy on Wave %d)" % wave
		var ql := panel.get_node_or_null("VBoxContainer/QueueLabel")
		if is_instance_valid(ql):
			var ls := get_tree().get_first_node_in_group("lane_spawner")
			var cnt : int = ls.get_player_queue_count(team_id) if is_instance_valid(ls) and ls.has_method("get_player_queue_count") else 0
			(ql as Label).text = "Queued: %d creep%s for Wave %d" % [cnt, "s" if cnt != 1 else "", wave]

func _open_deck_for_wave() -> void:
	# Reopen the creep deck picker so player can choose what to deploy
	if is_instance_valid(player) and player.has_method("_show_deck_ui"):
		player._show_deck_ui()
	else:
		# Find deck UI directly
		var du : Node = null
		for n in get_tree().get_nodes_in_group("creep_deck_ui"):
			du = n; break
		if not is_instance_valid(du):
			var scr := load("res://scripts/CreepDeckUI.gd") if ResourceLoader.exists("res://scripts/CreepDeckUI.gd") else null
			if not is_instance_valid(scr): return
			du = Control.new(); du.set_script(scr)
			du.add_to_group("creep_deck_ui"); get_viewport().add_child(du)
		if du.has_method("show_for_player"):
			du.show_for_player(int(player.get("player_id")) if is_instance_valid(player) and "player_id" in player else 0)


func _sig(node: Node, sig: String, fn: Callable) -> void:
	if not is_instance_valid(node) or not node.has_signal(sig): return
	if not node.is_connected(sig, fn): node.connect(sig, fn)


func _on_tree_updated(_player_id: int) -> void:
	_refresh_ability_slots()

func _sync_all() -> void:
	if is_instance_valid(player):
		var hp  := _f(player, "health");     var mhp := _f(player, "max_health")
		if mhp > 0.0: _on_player_health_changed(hp, mhp)
	if is_instance_valid(base):
		var bhp  := _f(base, "health_value"); var bmhp := _f(base, "max_health")
		if bmhp > 0.0: _on_base_health_changed(bhp, bmhp)
	if is_instance_valid(game_manager) and game_manager.has_method("get_gold"):
		_on_money_changed(team_id, game_manager.get_gold(team_id))
	# Ult charge bar — sync current value and per-class name so bar is correct on rebind
	if is_instance_valid(player):
		# Trigger the player's own updater so it resolves the class name internally
		if player.has_method("_update_ult_hud"):
			player.call("_update_ult_hud")
		else:
			var uc  : float = float(player.get("ult_charge")     if "ult_charge"     in player else 0.0)
			var ucm : float = float(player.get("ult_charge_max") if "ult_charge_max" in player else 100.0)
			update_ult_charge(uc, ucm)
	# Weapon — connect signal then force-sync current weapon after one frame
	# so WeaponManager has finished _ready() and _equip(0) before we read it.
	call_deferred("_sync_weapon_manager")


# ============================================================
# GOLD / TIMER / READY / MATCH
# ============================================================
func _on_money_changed(t: int, amount: int) -> void:
	if t != team_id or not is_instance_valid(gold_label): return
	gold_label.text = "◆ %d" % amount

func _on_gold_awarded(t: int, amount: int) -> void:
	if t != team_id: return
	show_gold_popup(amount)

func show_gold_popup(amount: int) -> void:
	var lbl := Label.new()
	lbl.text = "+%dg" % amount
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", C_YELLOW)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	lbl.add_theme_constant_override("outline_size", 3)
	# Anchor just below the top-center gold strip and float upward
	lbl.anchor_left   = 0.5;  lbl.anchor_right  = 0.5
	lbl.anchor_top    = 0.0;  lbl.anchor_bottom = 0.0
	lbl.offset_left   = -40.0; lbl.offset_right = 40.0
	lbl.offset_top    = 40.0;  lbl.offset_bottom = 66.0
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.modulate.a = 0.0
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.z_index = 60
	add_child(lbl)
	var tw := lbl.create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, 0.12)
	tw.parallel().tween_property(lbl, "offset_top",    lbl.offset_top    - 48.0, 1.2).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(lbl, "offset_bottom", lbl.offset_bottom - 48.0, 1.2).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.35)
	tw.tween_callback(func(): if is_instance_valid(lbl): lbl.queue_free())

func _on_prep_time_updated(t: float) -> void:
	if t < 0.0 or not is_instance_valid(timer_label): return
	var total := int(t)
	timer_label.text = "%d:%02d" % [total/60, total%60]

func _on_phase_timer_updated(phase: String, t: float) -> void:
	if not is_instance_valid(timer_label): return
	match phase:
		"announce": timer_label.text = "Round in %ds" % int(t)
		"choice":
			timer_label.text = "Deploy: %ds" % int(t)
			# Also update wave panel sub label if visible
			if is_instance_valid(_wave_choice_panel):
				var sub := _wave_choice_panel.find_child("sub", true, false) if is_instance_valid(_wave_choice_panel) else null
				if is_instance_valid(sub): (sub as Label).text = "Choose wave  (%ds)" % int(t)
		"combat":
			if int(t) > 0:
				timer_label.text = "Next wave: %ds" % int(t)
			else:
				timer_label.text = "⚔ COMBAT"
		"results": timer_label.text = "Next round: %ds" % int(t)

func _on_ready_updated(t: int, _r: bool) -> void:
	if t != team_id: return
	is_ready = true; _mark_ready_ui()

func _mark_ready_ui() -> void:
	for btn in [ready_button, gamepad_ready_btn]:
		if is_instance_valid(btn):
			btn.text = "READY ✓"; btn.disabled = true
			btn.add_theme_color_override("font_color", C_DIM)

func _on_match_started() -> void:
	prep_active = false
	if _timer_tween and _timer_tween.is_valid(): _timer_tween.kill()
	_timer_tween = create_tween()
	if is_instance_valid(timer_label):   _timer_tween.tween_property(timer_label,  "modulate:a", 0.0, 0.6)
	if is_instance_valid(ready_wrap):    _timer_tween.tween_property(ready_wrap,   "modulate:a", 0.0, 0.6)
	_timer_tween.tween_callback(_show_engage)
	if is_instance_valid(timer_label):
		_timer_tween.tween_property(timer_label, "modulate:a", 1.0, 0.45)
		_timer_tween.tween_interval(2.0)
		_timer_tween.tween_property(timer_label, "modulate:a", 0.0, 0.9)
		_timer_tween.tween_callback(timer_label.hide)
	if is_instance_valid(ready_wrap):
		var t2 := create_tween(); t2.tween_interval(0.7); t2.tween_callback(_free_ready_wrap)

func _show_engage() -> void:
	if is_instance_valid(timer_label):
		timer_label.text = "ENGAGE"
		timer_label.add_theme_color_override("font_color", C_RED)

func _free_ready_wrap() -> void:
	if is_instance_valid(ready_wrap): ready_wrap.queue_free(); ready_wrap = null

func _on_ready_pressed() -> void:
	if is_ready: return
	is_ready = true; _mark_ready_ui()
	if is_instance_valid(game_manager) and game_manager.has_method("set_team_ready"):
		game_manager.set_team_ready(team_id, true)

func _on_show_phase_label(text: String, _fade: bool) -> void:
	if not is_instance_valid(phase_label): return
	phase_label.text = text + " PHASE"
	phase_label.add_theme_color_override("font_color", C_RED if text == "NIGHT" else C_DIM)


# ============================================================
# PUBLIC
# ============================================================
func refresh_after_upgrade() -> void:
	_last_hp = -1.0; _last_max_hp = -1.0
	_last_base_hp = -1.0; _last_base_max_hp = -1.0
	_last_ammo = -1; _last_max_ammo = -1

func show_status(text: String) -> void:
	if not is_instance_valid(gun_name_label): return
	var orig := gun_name_label.text
	gun_name_label.text = text
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(gun_name_label): gun_name_label.text = orig


# ============================================================
# HELPERS
# ============================================================
func _panel(al:float,at:float,ar:float,ab:float)->Control:
	var p:=Control.new()
	p.anchor_left=al;p.anchor_top=at;p.anchor_right=ar;p.anchor_bottom=ab
	p.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(p);return p

func _vbox(sep:int)->VBoxContainer:
	var v:=VBoxContainer.new();v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation",sep);return v

func _bar_thin(color:Color)->ProgressBar:
	var b:=ProgressBar.new();b.custom_minimum_size=Vector2(0,5)
	b.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	b.show_percentage=false;b.max_value=100;b.value=100
	b.add_theme_color_override("fill_color",color);return b

func _section_label(text:String)->Label:
	var l:=Label.new();l.text=text
	l.add_theme_font_size_override("font_size",FS_TINY)
	l.add_theme_color_override("font_color",C_DIM);return l

func _badge_label(text:String,color:Color)->Label:
	var l:=Label.new();l.text=text
	l.add_theme_font_size_override("font_size",FS_SMALL)
	l.add_theme_color_override("font_color",color);return l

func _spacer(h:int)->Control:
	var s:=Control.new();s.custom_minimum_size=Vector2(0,h);return s

func _count_enemies()->int:
	var n:=0
	for u in get_tree().get_nodes_in_group("units"):
		if is_instance_valid(u) and u.get("team_id")!=team_id: n+=1
	return n

func _f(node:Node,prop:String)->float:
	if not is_instance_valid(node) or not(prop in node):return 0.0
	var v=node.get(prop);return float(v) if v!=null else 0.0

func _i(node:Node,prop:String)->int:
	if not is_instance_valid(node) or not(prop in node): return 0
	var v = node.get(prop)
	return int(v) if v != null else 0
func _sync_weapon_manager() -> void:
	if not is_instance_valid(player): return
	var wm : Node = player.get("weapon_manager") if "weapon_manager" in player else null
	if not is_instance_valid(wm): return
	_sig(wm, "weapon_equipped", _on_weapon_changed)
	await get_tree().process_frame
	if not is_instance_valid(wm): return
	var gun : Node3D = wm.get_current_weapon() if wm.has_method("get_current_weapon") else null
	if is_instance_valid(gun):
		_apply_gun(gun)
	# ── Wire WeaponHUD if present ────────────────────────────
	var weapon_hud : Node = null
	var canvas := get_parent()
	if is_instance_valid(canvas):
		for child in canvas.get_children():
			if child.get_script() and "WeaponHUD" in child.get_script().resource_path:
				weapon_hud = child
				break
	if is_instance_valid(weapon_hud) and weapon_hud.has_method("bind_weapon_manager"):
		weapon_hud.bind_weapon_manager(wm)
		print("[HUD] WeaponHUD bound to WeaponManager")


# ─────────────────────────────────────────────────────────────
# CLASS ABILITY HUD — keys 1 / 2 / 3
# ─────────────────────────────────────────────────────────────
func _build_class_ability_hud() -> void:
	# WoW-style ability buttons row — trinket slot will be appended at the right end
	var bar := HBoxContainer.new()
	bar.name          = "AbilityBar"   # SniperScope hides by this name
	bar.anchor_left   = 0.18
	bar.anchor_right  = 0.82
	bar.anchor_top    = 0.910
	bar.anchor_bottom = 0.985
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical   = Control.GROW_DIRECTION_BOTH
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 4)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	_class_ability_bar = bar

	for i in 4:
		var col : Color = CLASS_AB_COLORS[i]

		# ── Outer container (mimics WoW action button border) ──────────
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ps := StyleBoxFlat.new()
		ps.bg_color        = Color(0.07, 0.07, 0.09, 0.96)
		ps.border_color    = col
		ps.set_border_width_all(2)
		ps.set_corner_radius_all(3)
		ps.content_margin_left   = 5
		ps.content_margin_right  = 5
		ps.content_margin_top    = 4
		ps.content_margin_bottom = 4
		panel.add_theme_stylebox_override("panel", ps)
		bar.add_child(panel)
		_class_ab_panels.append(panel)

		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 1)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(vb)

		# ── Key badge ──────────────────────────────────────────────────
		var top_row := HBoxContainer.new()
		top_row.add_theme_constant_override("separation", 4)
		top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(top_row)

		var key_lbl := Label.new()
		key_lbl.text = "[%s]" % CLASS_AB_KEYS[i]
		key_lbl.add_theme_font_size_override("font_size", FS_TINY)
		key_lbl.add_theme_color_override("font_color", col)
		top_row.add_child(key_lbl)

		# ── Ability name (prominent, like WoW tooltip header) ─────────
		var name_lbl := Label.new()
		name_lbl.text = "Ability %d" % (i + 1)
		name_lbl.add_theme_font_size_override("font_size", FS_SMALL)
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.95, 0.75))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.clip_text = true
		top_row.add_child(name_lbl)
		_class_ab_namelbs.append(name_lbl)

		# ── Description line (small, WoW tooltip body style) ──────────
		var desc_lbl := Label.new()
		desc_lbl.text = ""
		desc_lbl.add_theme_font_size_override("font_size", FS_TINY)
		desc_lbl.add_theme_color_override("font_color", Color(0.68, 0.72, 0.80))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_lbl.custom_minimum_size = Vector2(0, 0)
		desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		desc_lbl.visible = false   # hidden until text is set
		vb.add_child(desc_lbl)
		_class_ab_desclbs.append(desc_lbl)   # cache for tick

		# ── Thin separator ─────────────────────────────────────────────
		var sep := HSeparator.new()
		sep.modulate = Color(col.r, col.g, col.b, 0.35)
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(sep)

		# ── Cooldown bar (thin, WoW-style sweep indicator) ────────────
		var cd_bar := ProgressBar.new()
		cd_bar.max_value = 1.0
		cd_bar.value     = 1.0
		cd_bar.show_percentage = false
		cd_bar.custom_minimum_size = Vector2(0, 4)
		var fill_s := StyleBoxFlat.new()
		fill_s.bg_color = col
		fill_s.set_corner_radius_all(2)
		var bg_s := StyleBoxFlat.new()
		bg_s.bg_color = Color(0.08, 0.08, 0.10, 0.85)
		cd_bar.add_theme_stylebox_override("fill", fill_s)
		cd_bar.add_theme_stylebox_override("background", bg_s)
		cd_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(cd_bar)
		_class_ab_cdbars.append(cd_bar)

		# ── CD label ("READY" / "3.2s") ───────────────────────────────
		var cd_lbl := Label.new()
		cd_lbl.text = "READY"
		cd_lbl.add_theme_font_size_override("font_size", FS_TINY)
		cd_lbl.add_theme_color_override("font_color", Color(0.35, 1.0, 0.45))
		cd_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cd_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(cd_lbl)
		_class_ab_cdlbls.append(cd_lbl)

		# ── CD overlay — dark fill + large centered timer ─────────────
		var ov_ctrl := Control.new()
		ov_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
		ov_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov_ctrl.visible = false
		panel.add_child(ov_ctrl)

		# Sweep rect: top-anchored, height scaled in _update_ability_cooldown_overlays()
		var ov_rect := ColorRect.new()
		ov_rect.anchor_left   = 0.0
		ov_rect.anchor_right  = 1.0
		ov_rect.anchor_top    = 0.0
		ov_rect.anchor_bottom = 0.0
		ov_rect.offset_bottom = 0.0
		ov_rect.color = Color(0.0, 0.0, 0.0, 0.62)
		ov_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov_ctrl.add_child(ov_rect)
		_class_ab_sweep_rects.append(ov_rect)

		var ov_lbl := Label.new()
		ov_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		ov_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ov_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ov_lbl.add_theme_font_size_override("font_size", 16)
		ov_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
		ov_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov_ctrl.add_child(ov_lbl)
		_class_ab_overlays.append(ov_ctrl)
		_class_ab_overlay_lbls.append(ov_lbl)
func _tick_class_ability_hud() -> void:
	if not is_instance_valid(player): return
	if _class_ab_panels.size() < 4: return

	var cds  : Array = player.get("_class_cooldowns") if "_class_cooldowns" in player else []
	var maxs : Array = player.get("_class_cd_max")    if "_class_cd_max"    in player else []

	# ── Name / Desc: only refresh when player class changes (dirty check) ──
	var cur_class : int = int(player.get("player_class") if "player_class" in player else 0)
	if cur_class != _last_player_class:
		_last_player_class = cur_class
		for i in 4:
			if i < _class_ab_namelbs.size() and is_instance_valid(_class_ab_namelbs[i]):
				if player.has_method("_get_class_ability_name"):
					_class_ab_namelbs[i].text = player._get_class_ability_name(i)
			if i < _class_ab_desclbs.size() and is_instance_valid(_class_ab_desclbs[i]):
				if player.has_method("_get_class_ability_desc"):
					var d : String = player._get_class_ability_desc(i)
					_class_ab_desclbs[i].text    = d
					_class_ab_desclbs[i].visible = (d != "")

	# ── Cooldown (updated every tick) ─────────────────────────────────────
	_update_ability_cooldown_overlays(cds, maxs)


# Updates the 4 class-ability slot overlays: linear sweep height and timer label.
# Separated from _tick_class_ability_hud so the indicator logic is testable in isolation.
func _update_ability_cooldown_overlays(cds: Array, maxs: Array) -> void:
	for i in 4:
		if i >= _class_ab_panels.size(): break
		var cd_bar : ProgressBar = _class_ab_cdbars[i]        if i < _class_ab_cdbars.size()       else null
		var cd_lbl : Label       = _class_ab_cdlbls[i]        if i < _class_ab_cdlbls.size()       else null
		var panel  : Control     = _class_ab_panels[i]
		var ov     : Control     = _class_ab_overlays[i]      if i < _class_ab_overlays.size()     else null
		var ov_lbl : Label       = _class_ab_overlay_lbls[i]  if i < _class_ab_overlay_lbls.size() else null
		var sweep  : ColorRect   = _class_ab_sweep_rects[i]   if i < _class_ab_sweep_rects.size()  else null

		var cd : float = cds[i]  if i < cds.size()  else 0.0
		var mx : float = maxs[i] if i < maxs.size() else 1.0
		if mx <= 0.0: mx = 1.0

		if cd <= 0.0:
			if is_instance_valid(cd_bar) and cd_bar.value != 1.0: cd_bar.value = 1.0
			if is_instance_valid(cd_lbl) and cd_lbl.text != "READY": cd_lbl.text = "READY"
			if panel.modulate != Color.WHITE: panel.modulate = Color.WHITE
			if is_instance_valid(ov) and ov.visible: ov.visible = false
		else:
			var frac     : float  = cd / mx            # 1.0 = full cooldown, 0.0 = ready
			var new_val  : float  = 1.0 - frac
			var new_text : String = "%.1fs" % cd
			if is_instance_valid(cd_bar) and absf(cd_bar.value - new_val) > 0.005:
				cd_bar.value = new_val
			if is_instance_valid(cd_lbl) and cd_lbl.text != new_text:
				cd_lbl.text = new_text
			var dark := Color(0.45, 0.45, 0.45, 1.0)
			if panel.modulate != dark: panel.modulate = dark
			if is_instance_valid(ov):
				if not ov.visible: ov.visible = true
				# Scale sweep rect from top downward — height shrinks as cooldown depletes
				if is_instance_valid(sweep):
					sweep.offset_bottom = panel.size.y * frac
				if is_instance_valid(ov_lbl) and ov_lbl.text != new_text:
					ov_lbl.text = new_text


# ─────────────────────────────────────────────────────────────
# MINIMAP — Halo 3 style, player-centred circle
# ─────────────────────────────────────────────────────────────
func _build_minimap() -> void:
	# Smaller in split-screen (viewport is already half the window)
	var gs := get_node_or_null("/root/GameSettings")
	var _pc : int = int(gs.get("player_count") if is_instance_valid(gs) and "player_count" in gs else 1)
	var mm_sz   : float = 118.0 if _pc > 1 else 174.0
	var mm_pad  : float = 8.0

	# WoW-style: fixed-size round minimap anchored to top-right corner
	var container := Control.new()
	container.anchor_left   = 1.00
	container.anchor_right  = 1.00
	container.anchor_top    = 0.00
	container.anchor_bottom = 0.00
	container.offset_left   = -(mm_sz + mm_pad)
	container.offset_right  = -mm_pad
	container.offset_top    = mm_pad
	container.offset_bottom = mm_sz + mm_pad
	container.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	container.z_index       = 110
	add_child(container)
	_minimap = container
	container.visible = true   # always visible, regardless of shop/topdown state

	# Outer ring decoration (WoW compass-style border)
	var ring_bg := Panel.new()
	ring_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ring_sty := StyleBoxFlat.new()
	ring_sty.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	ring_sty.set_border_width_all(3)
	ring_sty.border_color = Color(0.55, 0.48, 0.30, 0.90)   # WoW gold border
	ring_sty.set_corner_radius_all(90)                        # fully round
	ring_bg.add_theme_stylebox_override("panel", ring_sty)
	container.add_child(ring_bg)

	# The actual draw node (clips to circle via corner radius)
	var node := _MinimapNode.new()
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left   = 3;  node.offset_right  = -3
	node.offset_top    = 3;  node.offset_bottom = -3
	node.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	container.add_child(node)
	_minimap_draw = node

	# "MAP" label at top (WoW zone-name style)
	var zone_lbl := Label.new()
	zone_lbl.text = "MAP"
	zone_lbl.add_theme_font_size_override("font_size", 9)
	zone_lbl.add_theme_color_override("font_color", Color(0.85, 0.78, 0.50))
	zone_lbl.anchor_left   = 0.0; zone_lbl.anchor_right  = 1.0
	zone_lbl.anchor_top    = 0.0; zone_lbl.anchor_bottom = 0.0
	zone_lbl.offset_top    = 6;   zone_lbl.offset_bottom = 18
	zone_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zone_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone_lbl.z_index = 5
	container.add_child(zone_lbl)


class _MinimapNode extends Control:
	const WORLD_R : float = 200.0  # world-units radius shown on map

	# ── Cached data filled by HUD._update_minimap() every 0.5s ──────────────
	# Using cached data avoids calling get_nodes_in_group() inside _draw()
	# which would run at 60fps and kill performance.
	var mm_player_pos  : Vector3 = Vector3.ZERO
	var mm_player_yaw  : float   = 0.0
	var mm_player_tid  : int     = 1
	var mm_bases       : Array   = []   # {pos:Vector3, friendly:bool}
	var mm_units       : Array   = []   # {pos:Vector3, friendly:bool, is_player:bool}
	var mm_hive_units  : Array   = []   # {pos:Vector3} — enemy units from eggs
	var mm_hives         : Array   = []   # {pos:Vector3, tier:int, cleared:bool}
	var mm_eggs          : Array   = []   # {pos:Vector3}
	var mm_crowd_zombies : Array   = []   # Vector3 — Z2/Z3 unloaded zombie positions
	var mm_clusters      : Array   = []   # {pos:Vector3, count:int} — density heat-dots
	var mm_revealed      : Array   = []   # {pos:Vector3, radius:float} — permanent fog reveals
	var mm_valid         : bool    = false

	func _draw() -> void:
		var sz := size
		var cx := sz.x * 0.5
		var cy := sz.y * 0.5
		var r  : float = min(cx, cy) - 4.0

		draw_circle(Vector2(cx, cy), r, Color(0.0, 0.0, 0.0, 0.55))

		if not mm_valid:
			_draw_border(cx, cy, r)
			return

		var lp_pos := mm_player_pos
		var yaw    := mm_player_yaw

		# Draw bases
		for bd in mm_bases:
			var diff := (bd.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			var col  : Color = Color(0.25, 0.9, 0.25) if bd.friendly else Color(1.0, 0.25, 0.25)
			if frac.length() <= 1.0:
				var mp := Vector2(cx + frac.x * r, cy + frac.y * r)
				draw_circle(mp, 6.0, col)
				draw_circle(mp, 2.5, Color.WHITE)
			else:
				var edge := frac.normalized()
				var ep   := Vector2(cx + edge.x * (r - 8.0), cy + edge.y * (r - 8.0))
				_arrow(ep, edge, col, 7.0)

		# Draw units (capped, pre-filtered)
		for ud in mm_units:
			var diff := (ud.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.0: continue
			var mp    := Vector2(cx + frac.x * r, cy + frac.y * r)
			var col   : Color
			if ud.friendly:
				col = Color(0.25, 0.75, 1.0) if ud.is_player else Color(0.25, 0.9, 0.25)
			else:
				col = Color(1.0, 0.2, 0.2) if ud.is_player else Color(1.0, 0.55, 0.1)
			draw_circle(mp, 3.5 if ud.is_player else 2.5, col)

		# Draw hive units (egg-spawned enemies) — always visible in range, no fog check
		for hud_data in mm_hive_units:
			var diff := (hud_data.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.0: continue
			var mp := Vector2(cx + frac.x * r, cy + frac.y * r)
			draw_circle(mp, 2.0, Color(1.0, 0.15, 0.05))

		# Draw hive cluster icons (hexagon ⬡, only when revealed)
		for hive_d in mm_hives:
			var diff := (hive_d.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if not _is_revealed(hive_d.pos) and not hive_d.cleared: continue
			var clipped := frac if frac.length() <= 1.0 else frac.normalized() * 0.96
			var mp  := Vector2(cx + clipped.x * r, cy + clipped.y * r)
			var col : Color = Color(0.45, 0.45, 0.45, 0.7) if hive_d.cleared \
				else Color(0.65, 0.0, 0.85)
			# Flat-top hexagon
			var hr : float = 5.5
			var hex_pts := PackedVector2Array()
			for i in 6:
				var ang := TAU * i / 6.0 + PI / 6.0
				hex_pts.append(mp + Vector2(cos(ang), sin(ang)) * hr)
			draw_colored_polygon(hex_pts, col)
			if not hive_d.cleared:
				for i in 6:
					draw_line(hex_pts[i], hex_pts[(i + 1) % 6],
						Color(1.0, 0.35, 1.0, 0.8), 1.2)
				# Tier indicator dot inside hexagon
				draw_circle(mp, float(hive_d.tier) * 0.7 + 1.2, Color(1.0, 0.85, 0.0))

		# Draw egg icons (diamond ◆, only when revealed)
		for egg_d in mm_eggs:
			var diff := (egg_d.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.0: continue
			if not _is_revealed(egg_d.pos): continue
			var mp := Vector2(cx + frac.x * r, cy + frac.y * r)
			var hs : float = 3.5
			draw_colored_polygon(PackedVector2Array([
				mp + Vector2(0, -hs), mp + Vector2(hs, 0),
				mp + Vector2(0,  hs), mp + Vector2(-hs, 0)
			]), Color(1.0, 0.85, 0.1))

		# Draw unloaded crowd zombie dots (Z2/Z3 — small, dimmer than Z1 units)
		for zpos in mm_crowd_zombies:
			var diff := (zpos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.0: continue
			draw_circle(Vector2(cx + frac.x * r, cy + frac.y * r),
				1.5, Color(1.0, 0.4, 0.1, 0.55))

		# Density heat-dots — radius and opacity scale with cluster enemy count
		for cl in mm_clusters:
			var diff := (cl.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.05: continue
			var clipped := frac if frac.length() <= 1.0 else frac.normalized() * 0.98
			var mp := Vector2(cx + clipped.x * r, cy + clipped.y * r)
			var cnt : int = int(cl.count)
			var dot_r : float = clampf(3.0 + sqrt(float(cnt)) * 0.9, 3.0, 10.0)
			var alpha : float = clampf(0.35 + float(cnt) * 0.025, 0.35, 0.85)
			draw_circle(mp, dot_r, Color(1.0, 0.2, 0.05, alpha))

		# Draw revealed area rings (subtle grey glow showing explored zones)
		for rev in mm_revealed:
			var diff := (rev.pos as Vector3) - lp_pos
			var rot  := _world_to_mm(diff.x, diff.z, yaw)
			var frac := rot / WORLD_R
			if frac.length() > 1.8: continue
			var mp     := Vector2(cx + frac.x * r, cy + frac.y * r)
			var map_r  : float = (float(rev.radius) / WORLD_R) * r
			draw_arc(mp, map_r, 0, TAU, 32, Color(0.7, 0.7, 0.7, 0.25), 1.5)

		# Player dot + forward triangle
		draw_circle(Vector2(cx, cy), 4.0, Color(1.0, 1.0, 1.0))
		var tip := Vector2(cx,       cy - 9.0)
		var bl  := Vector2(cx - 4.5, cy + 3.0)
		var br  := Vector2(cx + 4.5, cy + 3.0)
		draw_colored_polygon(PackedVector2Array([tip, bl, br]), Color(1.0, 1.0, 1.0))

		_draw_border(cx, cy, r)

	func _draw_border(cx: float, cy: float, r: float) -> void:
		# Outer arc border
		draw_arc(Vector2(cx, cy), r, 0, TAU, 64, Color(0.6, 0.6, 0.6, 0.7), 1.5)

	# Convert world (dx, dz) to minimap (mx, my) so player-forward = minimap-up.
	#
	# Godot 4 basis for rotation.y = yaw:
	#   basis.x (right)    = ( cos(yaw), 0, -sin(yaw))
	#   basis.z (back)     = ( sin(yaw), 0,  cos(yaw))
	#   forward = -basis.z = (-sin(yaw), 0, -cos(yaw))
	#
	# Project world offset onto player axes, then flip forward onto screen -Y
	# (screen Y increases downward; minimap up = smaller Y):
	#   mm_x = dot(diff, right)        =  dx*cos - dz*sin
	#   mm_y = -dot(diff, forward)     = -(-dx*sin - dz*cos) = dx*sin + dz*cos
	func _world_to_mm(dx: float, dz: float, yaw: float) -> Vector2:
		var s := sin(yaw); var c := cos(yaw)
		var mm_x := dx * c - dz * s   # dot with right  = (cos, 0, -sin)
		var mm_y := dx * s + dz * c   # -dot with fwd   = -(-sin, 0, -cos), forward→up
		return Vector2(mm_x, mm_y)

	func _rot2d(v: Vector2, angle: float) -> Vector2:
		var s := sin(angle); var c := cos(angle)
		return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)

	func _arrow(pos: Vector2, dir: Vector2, col: Color, sz: float) -> void:
		var perp := Vector2(-dir.y, dir.x)
		var tip  := pos + dir * sz
		var bl   := pos - dir * (sz * 0.5) + perp * (sz * 0.6)
		var br   := pos - dir * (sz * 0.5) - perp * (sz * 0.6)
		draw_colored_polygon(PackedVector2Array([tip, bl, br]), col)

	func _is_revealed(world_pos: Vector3) -> bool:
		for rev in mm_revealed:
			if (world_pos - rev.pos as Vector3).length() <= rev.radius:
				return true
		return false

	func _unit_col(u: Node, local_tid) -> Color:
		if not ("team_id" in u): return Color(0.9, 0.9, 0.9)
		var ut = u.get("team_id")
		if ut == local_tid:
			return Color(0.25, 0.75, 1.0) if u.is_in_group("players") else Color(0.25, 0.9, 0.25)
		else:
			return Color(1.0, 0.2, 0.2) if u.is_in_group("players") else Color(1.0, 0.55, 0.1)


# ============================================================
# TURRET HOVER PANEL — floats above turret in screen-space
# Auto-shows when player is within 6m of a friendly turret.
# ============================================================
const _TURRET_HOVER_RANGE  : float = 6.0
const _TURRET_HOVER_CHECK  : float = 0.20   # proximity check interval
var   _turret_hover_timer  : float = 0.0
var   _turret_hover_target : Node3D = null
var   _turret_title_lbl    : Label  = null
var   _turret_stats_lbl    : Label  = null
var   _turret_upgrade_btn  : Button = null
var   _turret_repair_btn   : Button = null
var   _turret_hover_closed : bool   = false


func _build_turret_hover_panel() -> void:
	# Remove any pre-existing panels to avoid duplicates.
	# Check both the group AND the legacy "UpgradePanel" node from ui.tscn.
	for existing in get_tree().get_nodes_in_group("turret_upgrade_panel"):
		if is_instance_valid(existing) and existing != self:
			existing.queue_free()
	# ui.tscn places an "UpgradePanel" at (0,0) — remove it before building ours.
	for root_node in [get_parent(), self]:
		if not is_instance_valid(root_node): continue
		var old_up : Node = root_node.find_child("UpgradePanel", true, false)
		if is_instance_valid(old_up) and old_up != self:
			old_up.queue_free()
			break

	_turret_hover = Panel.new()
	_turret_hover.name          = "TurretHoverPanel"
	_turret_hover.visible       = false
	_turret_hover.z_index       = 100
	_turret_hover.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_turret_hover.custom_minimum_size = Vector2(220.0, 0.0)

	var sty := StyleBoxFlat.new()
	sty.bg_color        = Color(0.06, 0.07, 0.13, 0.92)
	sty.border_color    = Color(0.85, 0.65, 0.15)
	sty.set_border_width_all(2)
	sty.set_corner_radius_all(6)
	sty.content_margin_left   = 10
	sty.content_margin_right  = 10
	sty.content_margin_top    = 8
	sty.content_margin_bottom = 8
	_turret_hover.add_theme_stylebox_override("panel", sty)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 4)
	_turret_hover.add_child(vb)

	_turret_title_lbl = Label.new()
	_turret_title_lbl.add_theme_font_size_override("font_size", 13)
	_turret_title_lbl.add_theme_color_override("font_color", Color(0.85, 0.65, 0.15))
	_turret_title_lbl.text = "⚙ TURRET"
	vb.add_child(_turret_title_lbl)

	vb.add_child(HSeparator.new())

	_turret_stats_lbl = Label.new()
	_turret_stats_lbl.add_theme_font_size_override("font_size", 11)
	_turret_stats_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_turret_stats_lbl.text = "Level: —\nHP: —"
	vb.add_child(_turret_stats_lbl)

	vb.add_child(HSeparator.new())

	_turret_upgrade_btn = _turret_btn("⬆ Upgrade [U]", Color(0.1, 0.42, 0.1),
		func(): _turret_do_upgrade())
	vb.add_child(_turret_upgrade_btn)

	_turret_repair_btn = _turret_btn("🔧 Repair [R]", Color(0.4, 0.24, 0.06),
		func(): _turret_do_repair())
	vb.add_child(_turret_repair_btn)

	var hint := Label.new()
	hint.text = "[T] close  •  walk away to hide"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
	vb.add_child(hint)

	add_child(_turret_hover)
	_turret_hover.add_to_group("turret_upgrade_panel")

	# Hook T key in _input (handled in canvas_layer _input)
	if not InputMap.has_action("turret_panel"):
		InputMap.add_action("turret_panel")
		var k := InputEventKey.new()
		k.keycode = KEY_T
		InputMap.action_add_event("turret_panel", k)


func _turret_btn(txt: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size    = Vector2(0.0, 28.0)
	b.add_theme_font_size_override("font_size", 11)
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(4)
	b.add_theme_stylebox_override("normal", s)
	b.pressed.connect(cb)
	return b


func _turret_tick(delta: float) -> void:
	_turret_hover_timer -= delta
	# Reposition every frame only when panel is visible (cheap, just unproject)
	if is_instance_valid(_turret_hover) and _turret_hover.visible:
		_turret_reposition()
	if _turret_hover_timer > 0.0: return
	_turret_hover_timer = _TURRET_HOVER_CHECK

	if not is_instance_valid(player): return

	# Find nearest friendly turret in range
	var best   : Node3D = null
	var best_d : float  = _TURRET_HOVER_RANGE
	var my_tid : int    = int(player.get("team_id") if "team_id" in player else 1)
	for t in get_tree().get_nodes_in_group("turrets"):
		if not (t is Node3D) or not is_instance_valid(t): continue
		if "team_id" in t and int(t.get("team_id")) != my_tid: continue
		var d : float = player.global_position.distance_to((t as Node3D).global_position)
		if d < best_d: best_d = d; best = t as Node3D

	# Hide during shop
	if shop_open:
		if is_instance_valid(_turret_hover): _turret_hover.visible = false
		return

	if not is_instance_valid(best):
		# Out of range — hide
		if is_instance_valid(_turret_hover): _turret_hover.visible = false
		_turret_hover_target  = null
		_turret_hover_closed  = false
		return

	if _turret_hover_closed and best == _turret_hover_target:
		return  # player closed it manually; don't reopen until they move away

	# New turret in range or changed
	if best != _turret_hover_target:
		_turret_hover_closed = false
		_turret_hover_target = best

	_turret_refresh_ui()
	if is_instance_valid(_turret_hover):
		_turret_hover.visible = true


func _turret_refresh_ui() -> void:
	if not is_instance_valid(_turret_hover_target): return
	var t      := _turret_hover_target
	var lvl    : int   = int(t.get("level"))     if "level"     in t else 1
	var maxlvl : int   = int(t.get("max_level")) if "max_level" in t else 5
	var hp     : float = float(t.get("health"))     if "health"     in t else 0.0
	var mhp    : float = float(t.get("max_health")) if "max_health" in t else 1.0
	var dmg    : float = float(t.get("damage"))     if "damage"     in t else 0.0
	var cost   : int   = _turret_upgrade_cost(t, lvl)

	if is_instance_valid(_turret_title_lbl):
		_turret_title_lbl.text = "⚙  %s  [Lv %d/%d]" % [t.name, lvl, maxlvl]
	if is_instance_valid(_turret_stats_lbl):
		_turret_stats_lbl.text = "HP:   %.0f / %.0f\nDMG: %.0f\nUpgrade cost: %d 💰" % [hp, mhp, dmg, cost]
	if is_instance_valid(_turret_upgrade_btn):
		_turret_upgrade_btn.disabled = lvl >= maxlvl
		_turret_upgrade_btn.text = ("★ MAX LEVEL" if lvl >= maxlvl
			else "⬆ Upgrade  [U]  (%d 💰)" % cost)
	if is_instance_valid(_turret_repair_btn):
		var repair_cost : int = maxi(1, int((mhp - hp) * 0.5))
		_turret_repair_btn.disabled = hp >= mhp
		_turret_repair_btn.text = ("✔ Full HP" if hp >= mhp
			else "🔧 Repair [R]  (%d 💰)" % repair_cost)


func _turret_upgrade_cost(t: Node, lvl: int) -> int:
	if t.has_method("get_upgrade_cost"): return int(t.call("get_upgrade_cost"))
	# Cost doubles every level: L1=150, L2=300, L5=2400, L10=76800
	return int(150 * pow(2.0, lvl - 1))


func _turret_reposition() -> void:
	if not is_instance_valid(_turret_hover) or not _turret_hover.visible: return
	if not is_instance_valid(_turret_hover_target): return
	var cam := _get_cam()
	if not is_instance_valid(cam): return
	var wp  : Vector3 = _turret_hover_target.global_position + Vector3(0.0, 3.5, 0.0)
	if cam.is_position_behind(wp):
		_turret_hover.modulate.a = 0.0
		return
	_turret_hover.modulate.a = 1.0
	var sp  : Vector2 = cam.unproject_position(wp)
	var vps : Vector2 = get_viewport().get_visible_rect().size
	# Use minimum_size so panel doesn't start at (0,0) before first layout pass
	var psz : Vector2 = _turret_hover.get_combined_minimum_size()
	psz.x = maxf(psz.x, 220.0)
	psz.y = maxf(psz.y, 120.0)
	_turret_hover.size = psz   # force size before clamping position
	_turret_hover.position = Vector2(
		clampf(sp.x - psz.x * 0.5, 4.0, vps.x - psz.x - 4.0),
		clampf(sp.y - psz.y - 6.0, 4.0, vps.y - psz.y - 4.0)
	)


func _turret_do_upgrade() -> void:
	if not is_instance_valid(_turret_hover_target): return
	var t := _turret_hover_target
	if t.has_method("upgrade"):
		t.upgrade()
	elif "level" in t and "max_level" in t:
		if int(t.get("level")) < int(t.get("max_level")):
			t.set("level", int(t.get("level")) + 1)
	_turret_refresh_ui()


func _turret_do_repair() -> void:
	if not is_instance_valid(_turret_hover_target): return
	var t := _turret_hover_target
	if t.has_method("repair"):
		t.repair()
	elif "health" in t and "max_health" in t:
		t.set("health", t.get("max_health"))
	_turret_refresh_ui()
