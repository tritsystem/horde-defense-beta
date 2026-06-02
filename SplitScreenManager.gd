# ============================================================
# SplitScreenManager.gd — AAA 4-Player Split Screen (Godot 4.x)
# ============================================================
extends Node
class_name SplitScreenManager

@export var player_scene : PackedScene
@export var hud_scene    : PackedScene
@export var level_root   : Node
@export var spawn_points : Array[Node3D] = []

const PLAYER_SCENE_PATH := "res://scenes/Player.tscn"
const HUD_SCENE_PATH    := "res://scenes/ui.tscn"
const MAX_PLAYERS       := 4
const DIVIDER_PX        := 2
const DIVIDER_COLOR     := Color(0.0, 0.0, 0.0, 1.0)

var _containers : Array[SubViewportContainer] = []
var _viewports  : Array[SubViewport]          = []
var _players    : Array[Node]                 = []
var _huds       : Array[Node]                 = []
var _devices    : Array[int]                  = []
var _spawned    : bool                        = false

var _player_count     : int        = 1
var _team_assignments : Dictionary = {}
var _screen_size      : Vector2    = Vector2.ZERO

signal all_players_spawned
signal player_spawned(player: Node, player_idx: int)


func _ready() -> void:
	add_to_group("splitscreen_manager")
	# Use a CanvasLayer on root so SubViewportContainers render correctly
	# regardless of where SSM sits in the scene tree
	var canvas := CanvasLayer.new()
	canvas.name  = "SSM_Canvas"
	canvas.layer = -100   # behind all UI
	get_tree().root.add_child(canvas)

	var root_ctrl := Control.new()
	root_ctrl.name         = "ViewportRoot"
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root_ctrl)

	await get_tree().process_frame
	await _boot()


func _exit_tree() -> void:
	var canvas := get_tree().root.get_node_or_null("SSM_Canvas")
	if is_instance_valid(canvas): canvas.queue_free()


# ── INPUT ROUTING ─────────────────────────────────────────────
# Mouse events: NOT intercepted — SubViewportContainer.stretch=true
# maps mouse coordinates correctly into sub-viewports automatically.
# Keyboard → P1 viewport only. Gamepad → owning player viewport only.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion \
	   or event is InputEventMagnifyGesture or event is InputEventPanGesture:
		return

	if event is InputEventKey:
		var idx := _device_to_player_idx(-1)
		if idx >= 0 and idx < _viewports.size() and is_instance_valid(_viewports[idx]):
			_viewports[idx].push_input(event)
			get_viewport().set_input_as_handled()
		return

	var device := -99
	if event is InputEventJoypadButton:
		device = (event as InputEventJoypadButton).device
	elif event is InputEventJoypadMotion:
		device = (event as InputEventJoypadMotion).device
	else:
		return

	var owner_idx := _device_to_player_idx(device)
	if owner_idx >= 0 and owner_idx < _viewports.size() and is_instance_valid(_viewports[owner_idx]):
		_viewports[owner_idx].push_input(event)
		get_viewport().set_input_as_handled()


func _owner_idx_for_event(event: InputEvent) -> int:
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		return _device_to_player_idx(-1)
	if event is InputEventJoypadButton:
		return _device_to_player_idx((event as InputEventJoypadButton).device)
	if event is InputEventJoypadMotion:
		return _device_to_player_idx((event as InputEventJoypadMotion).device)
	return -1


func _device_to_player_idx(device: int) -> int:
	for i in _devices.size():
		if _devices[i] == device: return i
	return -1


# ── BOOT ──────────────────────────────────────────────────────
# Public entry point called by SceneSetup
func boot() -> void:
	await _boot()


func _boot() -> void:
	if _spawned: return
	_spawned = true
	_load_settings()
	_load_scenes()
	if not is_instance_valid(player_scene):
		push_error("[SSM] Cannot boot — no player scene found at: " + PLAYER_SCENE_PATH)
		return
	_clear()
	_screen_size = get_viewport().get_visible_rect().size
	print("[SSM] ══ BOOT ══  players=%d  screen=%s" % [_player_count, str(_screen_size)])
	for i in _player_count:
		print("[SSM]   P%d → team=%d  device=%s" % [
			i+1, _team_assignments.get(i,(i%2)+1), _device_name(_device(i))])
	for i in _player_count:
		var vp := _make_viewport(i)
		_spawn_player(i, vp)
	for _f in 8: await get_tree().process_frame
	_draw_dividers()
	_attach_cameras()
	for _f in 4: await get_tree().process_frame
	_register_topdown_cameras()
	_attach_audio_listeners()
	for _f in 8: await get_tree().process_frame
	await get_tree().physics_frame
	await _apply_spawn_positions()
	emit_signal("all_players_spawned")
	print("[SSM] ══ All players spawned ══")


func _load_settings() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if not is_instance_valid(gs):
		push_warning("[SSM] GameSettings not found — defaulting to 1 player")
		_player_count = 1; _team_assignments = {0:1}; return
	_player_count = clampi(int(gs.get("player_count") if "player_count" in gs else 1), 1, MAX_PLAYERS)
	_team_assignments = {}
	var _ta : Dictionary = gs.get("team_assignments") if "team_assignments" in gs else {}
	for i in _player_count:
		_team_assignments[i] = int(_ta.get(i, (i%2)+1))
	print("[SSM] players=%d  ai=%s  ai_team=%d" % [
		_player_count,
		str(gs.get("ai_enabled") if "ai_enabled" in gs else false),
		int(gs.get("ai_team_id") if "ai_team_id" in gs else 2)])


func _load_scenes() -> void:
	if not is_instance_valid(player_scene):
		player_scene = load(PLAYER_SCENE_PATH) if ResourceLoader.exists(PLAYER_SCENE_PATH) else null
	if not is_instance_valid(hud_scene):
		hud_scene = load(HUD_SCENE_PATH) if ResourceLoader.exists(HUD_SCENE_PATH) else null
	if not is_instance_valid(hud_scene):
		push_warning("[SSM] HUD scene not found — continuing without UI")


func _viewport_rect(idx: int, total: int, screen: Vector2) -> Rect2:
	var hw := floorf(screen.x * 0.5)
	var hh := floorf(screen.y * 0.5)
	match total:
		1: return Rect2(Vector2.ZERO, screen)
		2: return Rect2(Vector2(hw * idx, 0.0), Vector2(hw, screen.y))
		3:
			if idx < 2: return Rect2(Vector2(hw * idx, 0.0), Vector2(hw, hh))
			else:        return Rect2(Vector2(0.0, hh), Vector2(screen.x, hh))
		4: return Rect2(Vector2(hw*(idx%2), hh*floorf(float(idx)/2.0)), Vector2(hw, hh))
		_:
			var col := idx%2; var row := idx/2; var cols := 2
			var rows := ceili(float(total)/float(cols))
			return Rect2(Vector2(screen.x/cols*col, screen.y/rows*row), Vector2(screen.x/cols, screen.y/rows))


func _make_viewport(idx: int) -> SubViewport:
	var rect  := _viewport_rect(idx, _player_count, _screen_size)
	var vp_sz := Vector2i(int(rect.size.x), int(rect.size.y))
	var container := SubViewportContainer.new()
	container.name          = "VP_Container_P%d" % (idx+1)
	container.stretch       = true
	container.clip_contents = true
	container.mouse_filter  = Control.MOUSE_FILTER_PASS
	container.position      = rect.position
	container.size          = rect.size
	var _vr := get_tree().root.get_node_or_null("SSM_Canvas/ViewportRoot")
	if not is_instance_valid(_vr): _vr = get_tree().root.get_node_or_null("ViewportRoot")
	_vr.add_child(container)
	_containers.append(container)
	var vp := SubViewport.new()
	vp.name                      = "VP_P%d" % (idx+1)
	vp.size                      = vp_sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d              = false
	vp.handle_input_locally      = true   # must be true for GUI buttons to work
	vp.gui_disable_input         = false
	vp.audio_listener_enable_3d  = false
	# ── Split-screen performance: reduce render quality to recover FPS ──────────
	# These settings apply only when the screen is shared. In single-player the
	# SubViewport fills the whole window so quality should stay at project defaults.
	if _player_count > 1:
		vp.msaa_3d          = Viewport.MSAA_DISABLED           # biggest single FPS win
		vp.screen_space_aa  = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.use_taa          = false
		vp.use_debanding    = false
		vp.scaling_3d_mode  = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 0.75   # render at 75 % of the quadrant then upscale
		print("[SSM] P%d quality reduced for split-screen (75 %% scale, no AA)" % (idx+1))
	# own_world_3d=false means the SubViewport inherits the parent viewport's world.
	# Explicitly setting world_3d can cause issues if the reference is stale.
	# Only set it if Godot hasn't already shared it via inheritance.
	# Share the root Window's World3D — this is always the main game world
	var main_world : World3D = get_tree().root.world_3d
	if is_instance_valid(main_world):
		vp.world_3d = main_world
		print("[SSM] P%d world_3d set from root Window" % (idx+1))
	else:
		push_error("[SSM] P%d: root Window has no World3D!" % (idx+1))
	container.add_child(vp)
	_viewports.append(vp)
	print("[SSM] P%d viewport: pos=%s  size=%s" % [idx+1, str(rect.position), str(rect.size)])
	return vp


func _draw_dividers() -> void:
	if _player_count <= 1: return
	var vr := get_tree().root.get_node_or_null("ViewportRoot")
	if not is_instance_valid(vr): return
	var existing := vr.get_node_or_null("Dividers")
	if is_instance_valid(existing): existing.queue_free()
	var div_root := Control.new()
	div_root.name = "Dividers"; div_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	div_root.set_anchors_preset(Control.PRESET_FULL_RECT); div_root.z_index = 10
	vr.add_child(div_root)
	var hw := _screen_size.x * 0.5; var hh := _screen_size.y * 0.5
	_divider_rect(div_root, Vector2(hw - DIVIDER_PX*0.5, 0.0), Vector2(DIVIDER_PX, _screen_size.y))
	if _player_count >= 3:
		_divider_rect(div_root, Vector2(0.0, hh - DIVIDER_PX*0.5), Vector2(_screen_size.x, DIVIDER_PX))
	for i in _player_count:
		var rect := _viewport_rect(i, _player_count, _screen_size)
		var lbl  := Label.new()
		lbl.text = "P%d" % (i+1)
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.35))
		lbl.position = rect.position + Vector2(6.0, 4.0)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		div_root.add_child(lbl)


func _divider_rect(parent: Control, pos: Vector2, sz: Vector2) -> void:
	var r := ColorRect.new()
	r.color = DIVIDER_COLOR; r.position = pos; r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE; parent.add_child(r)


func _spawn_player(idx: int, vp: SubViewport) -> void:
	var pid    : int = idx + 1
	var device : int = _device(idx)
	var tid    : int = _team_assignments.get(idx, (idx%2)+1)
	while _devices.size() <= idx: _devices.append(-99)
	_devices[idx] = device
	var player := player_scene.instantiate()
	player.name = "Player%d" % pid
	player.set_meta("player_id", pid)
	if "player_id" in player: player.set("player_id", pid)
	if "device_id" in player: player.set("device_id", device)
	if "team_id"   in player: player.set("team_id",   tid)
	# ── Mouse isolation: gamepad players' SubViewportContainers must not receive
	# mouse events. This stops the KBM player from accidentally clicking across
	# screen boundaries into another player's UI.  KBM player (device == -1) keeps
	# MOUSE_FILTER_PASS so their own mouse clicks still reach their SubViewport.
	if device >= 0 and idx < _containers.size() and is_instance_valid(_containers[idx]):
		_containers[idx].mouse_filter = Control.MOUSE_FILTER_IGNORE
		print("[SSM] P%d container mouse_filter = IGNORE (gamepad player)" % pid)

	var inp := get_node_or_null("/root/inputsetup")
	if not is_instance_valid(inp): inp = get_node_or_null("inputsetup")
	if is_instance_valid(inp) and inp.has_method("setup_player_inputs"):
		inp.setup_player_inputs(pid, device)
	var root := level_root if is_instance_valid(level_root) else get_tree().current_scene
	root.add_child(player)
	player.global_position = _spawn_pos_for_team(tid)
	if is_instance_valid(hud_scene):
		var hud_root := hud_scene.instantiate()
		vp.add_child(hud_root)
		_huds.append(hud_root)
		var hud := hud_root
		if not hud_root.has_method("bind_player"):
			hud = hud_root.get_node_or_null("Control")
			if not is_instance_valid(hud): hud = _find_first_with_method(hud_root, "bind_player")
		if is_instance_valid(hud) and hud.has_method("bind_player"):
			hud.bind_player(player)
			if "hud" in player: player.set("hud", hud)
			print("[SSM] P%d HUD bound ✓" % pid)
		else:
			push_error("[SSM] P%d HUD bind failed" % pid)
		var shop := hud_root.get_node_or_null("Control/SHOPUI")
		if not is_instance_valid(shop): shop = _find_first_with_method(hud_root, "open_shop")
		if is_instance_valid(shop) and player.has_method("bind_shop"):
			player.bind_shop(shop); print("[SSM] P%d shop bound ✓" % pid)
	else:
		_huds.append(null)
	_players.append(player)
	emit_signal("player_spawned", player, idx)
	print("[SSM] P%d spawned ✓  device=%s  team=%d" % [pid, _device_name(device), tid])
	var gnav := get_node_or_null("/root/GamepadUINavigator")
	if is_instance_valid(gnav) and gnav.has_method("register_device"):
		gnav.register_device(device, vp)


func _attach_cameras() -> void:
	for i in _players.size():
		var player := _players[i]
		var vp     := _viewports[i] if i < _viewports.size() else null
		if not is_instance_valid(player) or not is_instance_valid(vp): continue

		# Ensure world_3d is still valid
		if not is_instance_valid(vp.world_3d):
			vp.world_3d = get_tree().root.world_3d
			print("[SSM] P%d world_3d re-set at attach time" % (i+1))

		var cam : Camera3D = null
		for path in ["CameraRoot/FPSPivot/FPSCamera","CameraRoot/FPSPivot/Camera3D",
					  "Head/Camera3D","Head/FPSCamera","FPSCamera","Camera3D"]:
			cam = player.get_node_or_null(path) as Camera3D
			if is_instance_valid(cam): break
		if not is_instance_valid(cam): cam = _find_camera(player)
		if not is_instance_valid(cam): push_error("[SSM] P%d: No Camera3D" % (i+1)); continue
		var vp_rid  := vp.get_viewport_rid()
		var cam_rid := cam.get_camera_rid()
		if not vp_rid.is_valid() or not cam_rid.is_valid():
			push_error("[SSM] P%d: invalid RID" % (i+1)); continue
		cam.current = false
		RenderingServer.viewport_attach_camera(vp_rid, cam_rid)
		cam.current = true
		print("[SSM] P%d camera attached: %s → %s | world_3d=%s" % [
			i+1, cam.name, vp.name, str(is_instance_valid(vp.world_3d))])
	_attach_audio_listeners()


func switch_player_camera(player: Node, new_cam: Camera3D) -> void:
	if not is_instance_valid(player) or not is_instance_valid(new_cam):
		push_error("[SSM] switch_player_camera: invalid args"); return
	var idx := _players.find(player)
	if idx < 0 or idx >= _viewports.size():
		push_error("[SSM] switch_player_camera: player not registered"); return
	var vp := _viewports[idx]
	if not is_instance_valid(vp): return
	RenderingServer.viewport_attach_camera(vp.get_viewport_rid(), new_cam.get_camera_rid())
	print("[SSM] P%d camera switched → %s" % [idx+1, new_cam.name])


func _register_topdown_cameras() -> void:
	for i in _players.size():
		var player := _players[i]
		if not is_instance_valid(player): continue
		var td : Camera3D = null
		for path in ["CameraRoot/TopDownPivot/TopDownCamera","CameraRoot/TopDownPivot/Camera3D",
					  "TopdownCamera","TopDownCamera"]:
			td = player.get_node_or_null(path) as Camera3D
			if is_instance_valid(td): break
		if not is_instance_valid(td):
			push_warning("[SSM] P%d: TopdownCamera not found — creating" % (i+1))
			td = Camera3D.new(); td.name = "TopdownCamera"
			td.current = false; td.fov = 60.0; td.near = 0.1; td.far = 500.0
			player.add_child(td)
			if "td_camera" in player: player.set("td_camera", td)
		if is_instance_valid(td):
			var h : float = float(player.get("topdown_height") if "topdown_height" in player else 20.0)
			var p : float = float(player.get("topdown_angle")  if "topdown_angle"  in player else -70.0)
			td.global_position = player.global_position + Vector3(0, h, 0)
			td.rotation_degrees = Vector3(p, 0.0, 0.0)
			print("[SSM] P%d TopdownCamera ready" % (i+1))


func _attach_audio_listeners() -> void:
	for i in _players.size():
		var player := _players[i]
		if not is_instance_valid(player): continue
		var anchor : Node3D = null
		for path in ["Head","CameraRoot/FPSPivot"]:
			var n := player.get_node_or_null(path) as Node3D
			if is_instance_valid(n): anchor = n; break
		if not is_instance_valid(anchor): anchor = player as Node3D
		var old := anchor.get_node_or_null("AudioListener3D")
		if is_instance_valid(old): old.queue_free()
		var listener := AudioListener3D.new(); listener.name = "AudioListener3D"
		anchor.add_child(listener)
		if i == 0: listener.make_current()
		print("[SSM] P%d audio listener%s" % [i+1, " (active)" if i==0 else ""])


func _device(player_idx: int) -> int:
	if player_idx == 0: return -1
	var pads    := Input.get_connected_joypads()
	var pad_idx := player_idx - 1
	if pad_idx < pads.size(): return pads[pad_idx]
	push_warning("[SSM] P%d: no gamepad" % (player_idx+1))
	return -99


func _device_name(device: int) -> String:
	match device:
		-1:  return "KBM"
		-99: return "NONE"
		_:   return "Pad%d" % device


func _spawn_pos_for_team(tid: int) -> Vector3:
	for sp in spawn_points:
		if is_instance_valid(sp) and sp.has_meta("team_id") and int(sp.get_meta("team_id")) == tid:
			return _ground_snap(sp.global_position)
	var valid : Array[Node3D] = spawn_points.filter(func(s): return is_instance_valid(s))
	if not valid.is_empty():
		return _ground_snap(valid[clampi(tid-1,0,valid.size()-1)].global_position)
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and "team_id" in b and int(b.get("team_id")) == tid:
			return _ground_snap((b as Node3D).global_position + Vector3(0,2,5))
	var names := ["Base","Base1","PlayerBase"] if tid==1 else ["Base2","Base 2","EnemyBase"]
	for bname in names:
		var bn := get_tree().root.find_child(bname, true, false)
		if is_instance_valid(bn) and bn is Node3D:
			return _ground_snap((bn as Node3D).global_position + Vector3(0,2,5))
	push_warning("[SSM] No spawn for team %d" % tid)
	return Vector3(float(tid-1)*8, 2, 0)


func _ground_snap(pos: Vector3) -> Vector3:
	var space := get_tree().root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(pos+Vector3(0,12,0), pos+Vector3(0,-30,0))
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	return hit.position + Vector3(0,1.2,0) if not hit.is_empty() else pos + Vector3(0,1.2,0)


func _apply_spawn_positions() -> void:
	var bl := get_node_or_null("/root/BaseLocator")
	if is_instance_valid(bl) and bl.has_signal("bases_ready"):
		if "is_ready" in bl and not bl.is_ready: await bl.bases_ready
	else:
		for _f in 3: await get_tree().physics_frame
	for p in _players:
		if not is_instance_valid(p): continue
		p.set_physics_process(false)
		if "velocity" in p: p.velocity = Vector3.ZERO
		var tid : int = int(p.get("team_id") if "team_id" in p else 1)
		p.global_position = _spawn_pos_for_team(tid)
		print("[SSM] P%d → %s (team %d)" % [
			int(p.get("player_id") if "player_id" in p else 0),
			str(p.global_position.snapped(Vector3.ONE)), tid])
	await get_tree().physics_frame
	for p in _players:
		if is_instance_valid(p):
			if "velocity" in p: p.velocity = Vector3.ZERO
			p.set_physics_process(true)


func set_viewport_input(player_idx: int, shop_open: bool) -> void:
	print("[SSM] P%d shop: %s" % [player_idx+1, "OPEN" if shop_open else "CLOSED"])
	# IMPORTANT: handle_input_locally must remain TRUE at all times.
	# Setting it false causes push_input() to forward events to the parent viewport
	# instead of processing them locally, which breaks per-player input isolation and
	# can create infinite re-dispatch loops for keyboard events.
	# The SSM _input() already routes keyboard → VP_P1 and gamepad → owner's VP.
	# Each UI script's own _is_my_event / device_id guards handle the rest.
	if player_idx < 0 or player_idx >= _viewports.size(): return
	var vp := _viewports[player_idx]
	if not is_instance_valid(vp): return
	vp.handle_input_locally = true   # never disable
	# gui_disable_input stays false — shop/HUD visibility manages their own state
	print("[SSM] P%d SubVP input OK (shop=%s)" % [player_idx+1, str(shop_open)])


func set_ui_input_enabled(player_idx: int, enabled: bool) -> void:
	if player_idx < 0 or player_idx >= _viewports.size(): return
	var vp := _viewports[player_idx]
	if not is_instance_valid(vp): return
	vp.gui_disable_input = not enabled
	print("[SSM] P%d UI input: %s" % [player_idx+1, "ON" if enabled else "OFF"])
	var gnav := get_node_or_null("/root/GamepadUINavigator")
	if is_instance_valid(gnav) and gnav.has_method("set_ui_active"):
		var device := _devices[player_idx] if player_idx < _devices.size() else -99
		if device >= 0: gnav.set_ui_active(device, enabled)


func on_window_resized() -> void:
	_screen_size = get_viewport().get_visible_rect().size
	for i in _containers.size():
		if not is_instance_valid(_containers[i]): continue
		var rect := _viewport_rect(i, _player_count, _screen_size)
		_containers[i].position = rect.position; _containers[i].size = rect.size
		if i < _viewports.size() and is_instance_valid(_viewports[i]):
			_viewports[i].size = Vector2i(int(rect.size.x), int(rect.size.y))
	_draw_dividers()


func restart() -> void:
	_spawned = false; _clear()
	await get_tree().process_frame; await _boot()


func _clear() -> void:
	for p in _players:
		if is_instance_valid(p): p.queue_free()
	_players.clear(); _huds.clear(); _devices.clear()
	for c in _containers:
		if is_instance_valid(c): c.queue_free()
	_containers.clear(); _viewports.clear()


func get_player(idx: int) -> Node:
	return _players[idx] if idx >= 0 and idx < _players.size() else null
func get_all_players() -> Array[Node]: return _players.duplicate()
func get_player_count() -> int: return _players.size()
func get_hud(player_idx: int) -> Node:
	return _huds[player_idx] if player_idx >= 0 and player_idx < _huds.size() else null
func get_viewport_for_player(player: Node) -> SubViewport:
	var idx := _players.find(player)
	return _viewports[idx] if idx >= 0 and idx < _viewports.size() else null
func get_device_for_player(player_idx: int) -> int:
	return _devices[player_idx] if player_idx >= 0 and player_idx < _devices.size() else -99


## Warp the OS cursor to the centre of a player's screen quadrant.
## Call when opening a KBM-accessible UI (shop, class select) so the
## cursor starts inside that player's half of the screen.
func warp_mouse_to_player(player_idx: int) -> void:
	if player_idx < 0 or player_idx >= _player_count: return
	var rect := _viewport_rect(player_idx, _player_count, _screen_size)
	DisplayServer.warp_mouse(rect.position + rect.size * 0.5)


func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D: return node as Camera3D
	for child in node.get_children():
		var c := _find_camera(child); if is_instance_valid(c): return c
	return null

func _find_first_with_method(node: Node, method: String) -> Node:
	if node.has_method(method): return node
	for child in node.get_children():
		var found := _find_first_with_method(child, method)
		if is_instance_valid(found): return found
	return null
