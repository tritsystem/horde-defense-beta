# ============================================================
# SceneSetup.gd — AUTOLOAD
# ============================================================
extends Node

@export var base_turret_scene : PackedScene = null
@export var turret_positions  : Array[Vector3] = [
	Vector3(-5, 0, 0), Vector3(5, 0, 0),
	Vector3(0, 0, -5), Vector3(0, 0, 5),
]

const SSM_SCRIPT_PATHS := [
	"res://scripts/SplitScreenManager.gd",
	"res://SplitScreenManager.gd",
	"res://scenes/SplitScreenManager.gd",
]

var _setup_done_for : String = ""


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	await get_tree().process_frame
	_try_setup()


func _on_node_added(node: Node) -> void:
	if node == get_tree().current_scene:
		_setup_done_for = ""  # clear so the incoming scene always gets fresh setup
		await get_tree().process_frame
		_try_setup()


func _try_setup() -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return
	var path : String = scene.scene_file_path

	if path == _setup_done_for: return

	var path_lower := path.to_lower()
	if "main_menu" in path_lower or "mainmenu" in path_lower:
		print("[SceneSetup] Skipping main menu scene: %s" % path)
		return

	var gs       := _get_autoload("GameSettings", false)
	var gs_ready : bool = is_instance_valid(gs) and int(gs.get("player_count") if "player_count" in gs else 0) > 0
	var has_ssm  := not get_tree().get_nodes_in_group("splitscreen_manager").is_empty()
	var has_bases := not get_tree().get_nodes_in_group("bases").is_empty()
	var has_lane  := not get_tree().get_nodes_in_group("lane_spawner").is_empty() or \
					  scene.find_child("LaneSpawner", true, false) != null

	print("[SceneSetup] scene=%s | gs_ready=%s | has_ssm=%s | has_bases=%s" % [
		path, str(gs_ready), str(has_ssm), str(has_bases)])

	if not gs_ready and not has_ssm and not has_bases and not has_lane:
		print("[SceneSetup] Not a game scene — skipping")
		return

	_setup_done_for = path
	print("[SceneSetup] Running game setup for: %s" % path)

	await get_tree().process_frame
	await get_tree().process_frame
	_setup_bases()

	await _run_ssm_setup()


func _run_ssm_setup() -> void:
	# ── Find or create SSM ────────────────────────────────────
	var ssm_list := get_tree().get_nodes_in_group("splitscreen_manager")
	print("[SceneSetup] SSM nodes found: %d" % ssm_list.size())

	var ssm : Node = null

	if ssm_list.is_empty():
		push_warning("[SceneSetup] No SplitScreenManager in scene — creating dynamically")
		ssm = await _create_ssm()
		if not is_instance_valid(ssm):
			push_error("[SceneSetup] Failed to create SplitScreenManager")
			return
	else:
		if ssm_list.size() > 1:
			push_warning("[SceneSetup] %d SSM nodes found — using first" % ssm_list.size())
		ssm = ssm_list[0]
		print("[SceneSetup] SSM found at: %s" % str(ssm.get_path()))

	# ── Boot SSM immediately — don't wait for BaseLocator first ──
	# SSM handles its own world_3d wait loop internally.
	print("[SceneSetup] Booting SSM...")
	if ssm.has_method("boot"):
		await ssm.boot()
	elif ssm.has_method("_boot"):
		await ssm.call("_boot")
	else:
		push_error("[SceneSetup] SSM has no boot() method")

	_spawn_base_turrets()
	print("[SceneSetup] Done.")


func _create_ssm() -> Node:
	var scr : Script = null
	for path in SSM_SCRIPT_PATHS:
		if ResourceLoader.exists(path):
			scr = load(path)
			break

	if not is_instance_valid(scr):
		push_error("[SceneSetup] SplitScreenManager.gd not found at any known path")
		return null

	var ssm := Node.new()
	ssm.name = "SplitScreenManager"
	ssm.set_script(scr)
	get_tree().current_scene.add_child(ssm)
	print("[SceneSetup] Created SplitScreenManager dynamically")

	await get_tree().process_frame
	return ssm


# ============================================================
# BASES
# ============================================================
func _setup_bases() -> void:
	var scene := get_tree().current_scene
	if not is_instance_valid(scene): return

	var gs        := _get_autoload("GameSettings")
	var game_mode : String = gs.game_mode if (is_instance_valid(gs) and "game_mode" in gs) else "original"

	for pair in [["Base", 1], ["Base2", 2], ["base", 1], ["base2", 2],
				 ["base1", 1], ["Base1", 1]]:
		var node := scene.find_child(pair[0], true, false)
		if not is_instance_valid(node): continue
		if not node.is_in_group("bases"): node.add_to_group("bases")
		var tid : int = pair[1]
		if "team_id" in node: node.set("team_id", tid)
		node.set_meta("team_id", tid)

		# Original mode: team-2 base doesn't exist — hide it so zombies don't path to it
		if game_mode == "original" and tid == 2:
			if node is Node3D: (node as Node3D).visible = false
			node.remove_from_group("bases")
			print("[SceneSetup] Original mode — Base2 hidden (team_id=2)")
		else:
			print("[SceneSetup] Base '%s' → team_id=%d" % [node.name, tid])

	for node in get_tree().get_nodes_in_group("base"):
		if not node.is_in_group("bases"): node.add_to_group("bases")


# ============================================================
# BASE TURRETS
# ============================================================
func _spawn_base_turrets() -> void:
	if not is_instance_valid(base_turret_scene): return

	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not (b is Node3D): continue
		if b.has_method("_spawn_starting_turrets"): continue

		var tid : int = int(b.get_meta("team_id", 1))
		for offset in turret_positions:
			var turret := base_turret_scene.instantiate()
			get_tree().current_scene.add_child(turret)
			if "team_id" in turret: turret.set("team_id", tid)
			var spawn_pos : Vector3 = (b as Node3D).global_position + offset
			var space := get_tree().root.get_world_3d().direct_space_state
			var ray   := PhysicsRayQueryParameters3D.create(
				spawn_pos + Vector3(0, 5, 0),
				spawn_pos + Vector3(0, -15, 0))
			ray.collision_mask = 1
			var hit := space.intersect_ray(ray)
			if not hit.is_empty(): spawn_pos.y = hit.position.y + 0.1
			(turret as Node3D).global_position = spawn_pos
			turret.add_to_group("turrets")
			print("[SceneSetup] Turret team%d at %s" % [
				tid, str(spawn_pos.snapped(Vector3.ONE))])


# ============================================================
# HELPERS
# ============================================================
func _get_autoload(autoload_name: String, required: bool = true) -> Node:
	var node := get_node_or_null("/root/" + autoload_name)
	if not is_instance_valid(node):
		var msg := "[SceneSetup] Autoload '%s' not found at /root/%s" % [autoload_name, autoload_name]
		if required:
			push_error(msg)
		else:
			push_warning(msg + " — continuing without it")
	return node
