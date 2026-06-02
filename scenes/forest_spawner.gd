extends Node3D
# ===============================
# CONFIG
# ===============================
@export var tree_scenes: Array[PackedScene] = []
@export var forest_size: Vector2 = Vector2(500, 700)  # matches bigger valley
@export var tree_count: int = 90  # more trees for bigger map
@export var min_spacing: float = 8.0
@export var random_scale: bool = true
@export var scale_range: Vector2 = Vector2(0.8, 1.4)
@export var max_slope_angle: float = 35.0
@export var base_clear_radius: float = 45.0   # big clear zone around bases

# ===============================
# INTERNAL
# ===============================
var placed_positions: Array[Vector3] = []
var _base_positions: Array[Vector3] = []

# ===============================
# READY
# ===============================
func _ready() -> void:
	var bl := get_node_or_null("/root/BaseLocator")
	if is_instance_valid(bl):
		if not bl.is_ready: await bl.bases_ready
		_base_positions = [bl.base1_pos, bl.base2_pos]
		print("[WorldGen] Got base positions from BaseLocator")
	else:
		# Fallback wait
		for _i in 6: await get_tree().process_frame
		_base_positions.clear()
		for b in get_tree().get_nodes_in_group("bases"):
			if b is Node3D: _base_positions.append((b as Node3D).global_position)
		if _base_positions.size() < 2:
			for bname in ["Base","Base 2","Base1","Base2"]:
				var bn := get_tree().root.find_child(bname, true, false)
				if is_instance_valid(bn) and bn is Node3D:
					var bp := (bn as Node3D).global_position
					if not _base_positions.has(bp): _base_positions.append(bp)
	if _base_positions.size() < 2:
		push_warning("[WorldGen] Only found %d bases" % _base_positions.size())
	generate_forest()

# ===============================
# GENERATE
# ===============================
func generate_forest() -> void:
	if tree_scenes.is_empty():
		push_error("No tree scenes assigned!")
		return
	placed_positions.clear()
	var spawned: int = 0
	var attempts: int = 0
	var max_attempts: int = tree_count * 15

	# Compute spawn zone = midpoint between bases
	var spawn_center : Vector3 = global_position
	var spawn_radius : float   = forest_size.x * 0.5
	if _base_positions.size() >= 2:
		spawn_center = (_base_positions[0] + _base_positions[1]) * 0.5
		# 45% of base distance — forest fills the valley sides
		spawn_radius = _base_positions[0].distance_to(_base_positions[1]) * 0.45

	while spawned < tree_count and attempts < max_attempts:
		attempts += 1
		var pos: Vector3
		if not _get_valid_position_around(spawn_center, spawn_radius, pos):
			continue
		var scene: PackedScene = tree_scenes.pick_random()
		var tree: Node3D = scene.instantiate()
		add_child(tree)
		tree.global_position = pos
		tree.rotation.y = randf_range(0.0, TAU)
		if random_scale:
			var s: float = randf_range(scale_range.x, scale_range.y)
			tree.scale = Vector3.ONE * s
		placed_positions.append(pos)
		spawned += 1
	print("[WorldGen] placed %d / %d between bases (attempts=%d)" % [spawned, tree_count, attempts])

func _get_valid_position_around(center: Vector3, radius: float, out_pos: Vector3) -> bool:
	for _i in range(30):
		var angle : float = randf_range(0.0, TAU)
		# Use sqrt for uniform disk distribution — avoids center clustering
		var dist  : float = sqrt(randf_range(0.15, 1.0)) * radius
		var x : float = center.x + cos(angle) * dist
		var z : float = center.z + sin(angle) * dist
		var world_pos := Vector3(x, 50.0, z)
		var ground_hit := _raycast_to_ground(world_pos)
		if not ground_hit: continue
		var pos : Vector3 = ground_hit.position
		var normal : Vector3 = ground_hit.normal
		if rad_to_deg(acos(normal.dot(Vector3.UP))) > max_slope_angle: continue
		if not _is_far_enough(pos): continue
		if not _is_clear_of_bases(pos): continue
		out_pos = pos
		return true
	return false

# ===============================
# POSITION CHECK
# ===============================
func _get_valid_position(out_pos: Vector3) -> bool:
	for _i in range(20):
		var x: float = randf_range(-forest_size.x * 0.5, forest_size.x * 0.5)
		var z: float = randf_range(-forest_size.y * 0.5, forest_size.y * 0.5)
		var world_pos: Vector3 = global_position + Vector3(x, 50.0, z)
		var ground_hit := _raycast_to_ground(world_pos)
		if not ground_hit:
			continue
		var pos: Vector3 = ground_hit.position
		var normal: Vector3 = ground_hit.normal
		var angle: float = rad_to_deg(acos(normal.dot(Vector3.UP)))
		if angle > max_slope_angle:
			continue
		if not _is_far_enough(pos):
			continue
		if not _is_clear_of_bases(pos):
			continue
		out_pos = pos
		return true
	return false

# ===============================
# BASE CLEARANCE
# ===============================
func _is_clear_of_bases(pos: Vector3) -> bool:
	for bp in _base_positions:
		var flat_dist: float = Vector2(pos.x - bp.x, pos.z - bp.z).length()
		if flat_dist < base_clear_radius:
			return false
	return true

# ===============================
# RAYCAST
# ===============================
func _raycast_to_ground(from_pos: Vector3) -> Dictionary:
	var space = get_world_3d().direct_space_state
	return space.intersect_ray(
		PhysicsRayQueryParameters3D.create(
			from_pos,
			from_pos + Vector3.DOWN * 200.0))

# ===============================
# SPACING
# ===============================
func _is_far_enough(pos: Vector3) -> bool:
	for p in placed_positions:
		if p.distance_to(pos) < min_spacing:
			return false
	return true
