# ============================================================
# ZombieHordeManager.gd — AUTOLOAD — HIGH PERFORMANCE
# ============================================================
# Performance design:
#   - Buffer sized to ACTUAL unit count not MULTIMESH_MAX
#   - Single buffer upload per frame (not per-instance calls)
#   - Crowd sim runs on rolling batch (512/frame)
#   - Separation skipped for performance — units spread on spawn
#   - No alloc in hot path
#   - Z2 grid only rebuilt 4x/sec
#   - Real zombie LOD: 25m full AI, 60m cheap, 120m direct move
# ============================================================
extends Node

const ZONE1_RADIUS      := 25.0
const ZONE2_RADIUS      := 150.0
const ZONE1_MAX         := 300
const POOL_SIZE         := 300
const MULTIMESH_MAX     := 50_000
const CROWD_SPEED       := 3.8
const GRID_CELL         := 8.0
const UPDATE_BATCH_SIZE := 256
const CLEANUP_INTERVAL  := 3.0
const PROMOTE_HZ        := 5.0
const ZOMBIE_SCALE      := 0.012
const ZOMBIE_Y_OFFSET   := 1.0

const LOD0_DIST := 25.0
const LOD1_DIST := 60.0
const LOD2_DIST := 120.0

var zombie_scene    : PackedScene = preload("res://zombie/zombie.tscn")
var zombie_mesh     : Mesh        = null
var zombie_material : Material    = null

# ── Zone 1 ───────────────────────────────────────────────────
var _pool      : Array[CharacterBody3D] = []
var _z1_active : Array[CharacterBody3D] = []

# ── Zone 2 — packed arrays, sized to actual count ─────────────
var _mm_instance : MultiMeshInstance3D = null
var _multimesh   : MultiMesh           = null

var _z2_count : int = 0
var _z2_pos   : PackedVector3Array = PackedVector3Array()
var _z2_vel   : PackedVector2Array = PackedVector2Array()
var _z2_team  : PackedInt32Array   = PackedInt32Array()
var _z2_lane  : PackedInt32Array   = PackedInt32Array()

# Buffer sized to actual count — rebuilt when count changes
var _mm_buffer     : PackedFloat32Array = PackedFloat32Array()
var _mm_buf_count  : int = 0   # track when buffer needs resize

# ── Zone 3 ───────────────────────────────────────────────────
var _z3_count : int = 0
var _z3_pos   : PackedVector3Array = PackedVector3Array()
var _z3_team  : PackedInt32Array   = PackedInt32Array()
var _z3_lane  : PackedInt32Array   = PackedInt32Array()

# ── Refs ─────────────────────────────────────────────────────
var _flow_field  : Node     = null
var _camera      : Camera3D = null
var _cam_pos     : Vector3  = Vector3.ZERO
var _initialized : bool     = false

# ── Timers ───────────────────────────────────────────────────
var _grid         : Dictionary = {}
var _grid_t       : float = 0.0
var _promote_t    : float = 0.0
var _promote_acc  : int   = 0
var _batch_cursor : int   = 0
var _frame        : int   = 0
var _cleanup_t    : float = 0.0
var _init_retry_t : float = 0.0

var _selected : Array[CharacterBody3D] = []
signal selection_changed(selected: Array)
signal zombie_died(pos: Vector3)


# ============================================================
# LIFECYCLE
# ============================================================
func _enter_tree() -> void:
	Engine.register_singleton("ZombieHordeManager", self)

func _exit_tree() -> void:
	Engine.unregister_singleton("ZombieHordeManager")

func _ready() -> void:
	_setup_multimesh()
	_z2_pos.resize(MULTIMESH_MAX)
	_z2_vel.resize(MULTIMESH_MAX)
	_z2_team.resize(MULTIMESH_MAX)
	_z2_lane.resize(MULTIMESH_MAX)
	_z3_pos.resize(4096)
	_z3_team.resize(4096)
	_z3_lane.resize(4096)

func _process(delta: float) -> void:
	if not _initialized:
		_init_retry_t += delta
		if _init_retry_t >= 0.5:
			_init_retry_t = 0.0
			_try_init()
		return

	_frame  += 1
	_cam_pos = _get_cam_pos()

	# Crowd sim batch
	if _z2_count > 0:
		_update_z2_batch(delta)

	# Upload only every 3 frames — movement is smooth enough
	if _frame % 3 == 0 and _z2_count > 0:
		_upload_multimesh()

	# Grid rebuild 4x/sec
	_grid_t += delta
	if _grid_t >= 0.25:
		_grid_t = 0.0
		_rebuild_grid()
		_push_neighbors()

	# Z1 LOD every 15 frames
	if _frame % 15 == 0:
		_update_z1_lod()

	# Zone promotions
	_promote_t += delta
	if _promote_t >= 1.0 / PROMOTE_HZ:
		_promote_t = 0.0
		_check_promotions()

	# Cleanup
	_cleanup_t += delta
	if _cleanup_t >= CLEANUP_INTERVAL:
		_cleanup_t = 0.0
		_sweep_dead_z1()


# ============================================================
# INIT
# ============================================================
func _try_init() -> void:
	# Extract mesh from GLB
	if not is_instance_valid(zombie_mesh):
		var glb := load("res://zombie/scorpomesh.glb") as PackedScene
		if is_instance_valid(glb):
			var temp := glb.instantiate()
			for child in temp.find_children("*", "MeshInstance3D", true, false):
				var mi := child as MeshInstance3D
				if is_instance_valid(mi) and is_instance_valid(mi.mesh):
					zombie_mesh = mi.mesh
					break
			temp.queue_free()
		if is_instance_valid(zombie_mesh):
			_multimesh.mesh = zombie_mesh
			print("[ZHM] mesh set from GLB")

	# Always use a fresh standard material — GLB material is emissive/unlit
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.05, 0.05)
	mat.roughness    = 0.85
	mat.metallic     = 0.0
	zombie_material  = mat
	_mm_instance.material_override = zombie_material

	# Flow field
	if not is_instance_valid(_flow_field):
		_flow_field = get_node_or_null("/root/LaneFlowField")

	# Pool
	if _pool.is_empty() and is_instance_valid(zombie_scene):
		for i in POOL_SIZE:
			var z := zombie_scene.instantiate() as CharacterBody3D
			if not z: continue
			z.set_physics_process(false)
			z.process_mode = Node.PROCESS_MODE_DISABLED
			z.visible = false
			add_child(z)
			_pool.append(z)

	_initialized = true
	print("[ZHM] initialized | flow=%s mesh=%s pool=%d" % [
		_flow_field.name if is_instance_valid(_flow_field) else "NULL",
		"ok" if is_instance_valid(zombie_mesh) else "NULL",
		_pool.size()])

func reset_for_new_scene() -> void:
	_pool.clear(); _z1_active.clear(); _selected.clear(); _grid.clear()
	_z2_count = 0; _z3_count = 0; _camera = null
	_initialized = false; _init_retry_t = 0.0; _flow_field = null
	print("[ZHM] reset")


# ============================================================
# MULTIMESH SETUP
# ============================================================
func _setup_multimesh() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format       = MultiMesh.TRANSFORM_3D
	_multimesh.instance_count         = MULTIMESH_MAX
	_multimesh.visible_instance_count = 0
	_multimesh.mesh                   = _make_zombie_mesh()

	_mm_instance = MultiMeshInstance3D.new()
	_mm_instance.multimesh         = _multimesh
	_mm_instance.material_override = null
	add_child(_mm_instance)
	# Pre-allocate full buffer — must match instance_count * 12
	_mm_buffer.resize(MULTIMESH_MAX * 12)
	_mm_buffer.fill(0.0)


# ============================================================
# Z2 CROWD — rolling batch, no separation (spread on spawn)
# ============================================================
func _update_z2_batch(delta: float) -> void:
	var end : int = mini(_batch_cursor + UPDATE_BATCH_SIZE, _z2_count)
	for i in range(_batch_cursor, end):
		var p    : Vector3 = _z2_pos[i]
		var team : int     = _z2_team[i]
		var lane : int     = _z2_lane[i]
		var flow := _sample_flow(p, team, lane)
		var v    : Vector2 = _z2_vel[i]
		v = v.lerp(flow * CROWD_SPEED, 0.15)
		_z2_vel[i]    = v
		_z2_pos[i].x += v.x * delta
		_z2_pos[i].z += v.y * delta
	_batch_cursor = end % _z2_count

func _sample_flow(pos: Vector3, team: int, lane: int) -> Vector2:
	if is_instance_valid(_flow_field) and _flow_field.has_method("is_ready"):
		if _flow_field.is_ready():
			var d3 : Vector3 = _flow_field.get_flow(team, lane, pos)
			if d3.length_squared() > 0.001:
				return Vector2(d3.x, d3.z).normalized()
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == team: continue
		var d := pos - (b as Node3D).global_position
		if d.length_squared() > 0.1:
			return Vector2(-d.x, -d.z).normalized()
	return Vector2(1.0, 0.0)


# ============================================================
# MULTIMESH UPLOAD — buffer stays MULTIMESH_MAX, visible_instance_count limits render
# ============================================================
func _upload_multimesh() -> void:
	if _z2_count == 0: return
	_multimesh.visible_instance_count = _z2_count
	var s := ZOMBIE_SCALE
	for i in range(_z2_count):
		var p   : Vector3 = _z2_pos[i]
		var v   : Vector2 = _z2_vel[i]
		var yaw : float   = 0.0
		if v.length_squared() > 0.25:
			yaw = atan2(v.x, v.y) - PI * 0.5
		var cy  := cos(yaw); var sy := sin(yaw)
		var base := i * 12
		_mm_buffer[base + 0] =  cy * s; _mm_buffer[base + 1] = 0.0
		_mm_buffer[base + 2] = -sy * s; _mm_buffer[base + 3] = p.x
		_mm_buffer[base + 4] =  0.0;    _mm_buffer[base + 5] = s
		_mm_buffer[base + 6] =  0.0;    _mm_buffer[base + 7] = p.y + ZOMBIE_Y_OFFSET
		_mm_buffer[base + 8] =  sy * s; _mm_buffer[base + 9] = 0.0
		_mm_buffer[base +10] =  cy * s; _mm_buffer[base +11] = p.z
	_multimesh.buffer = _mm_buffer


# ============================================================
# LOD FOR REAL ZOMBIES
# ============================================================
func _update_z1_lod() -> void:
	if not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
	if not _camera: return
	var cam := _camera.global_position
	var dt  : float = 1.0 / 15.0

	for z in _z1_active:
		if not is_instance_valid(z): continue
		var d2   := cam.distance_squared_to(z.global_position)
		var nlod : int
		if   d2 < LOD0_DIST * LOD0_DIST: nlod = 0
		elif d2 < LOD1_DIST * LOD1_DIST: nlod = 1
		elif d2 < LOD2_DIST * LOD2_DIST: nlod = 2
		else:                              nlod = 3

		var clod : int = z.get_lod() if z.has_method("get_lod") else 0
		if clod != nlod:
			if z.has_method("set_lod"): z.set_lod(nlod)
			match nlod:
				0, 1: z.set_physics_process(true);  z.set_process(true);  z.visible = true
				2:    z.set_physics_process(false); z.set_process(false); z.visible = true
				3:    z.set_physics_process(false); z.set_process(false); z.visible = false
			if z.has_method("set_health_bar_visible"):
				z.set_health_bar_visible(d2 < 400.0)

		if nlod == 2:
			var dest = z.get("enemy_base") if "enemy_base" in z else null
			if is_instance_valid(dest):
				var dir := (dest as Node3D).global_position - z.global_position
				dir.y = 0.0
				if dir.length_squared() > 1.0:
					var spd : float = z.get("move_speed") if "move_speed" in z else 4.0
					z.global_position += dir.normalized() * spd * dt


# ============================================================
# ZONE PROMOTIONS
# ============================================================
func _check_promotions() -> void:
	var cam  := _cam_pos
	var z1r2 := ZONE1_RADIUS * ZONE1_RADIUS
	var z2r2 := ZONE2_RADIUS * ZONE2_RADIUS

	var player_positions : Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node3D:
			player_positions.append((p as Node3D).global_position)
	if player_positions.is_empty():
		player_positions.append(cam)

	# Z3 → Z2
	if _z3_count > 0:
		var slice    := mini(64, _z3_count)
		_promote_acc  = _promote_acc % _z3_count
		var start    := _promote_acc
		var end_idx  := mini(start + slice, _z3_count)
		_promote_acc  = end_idx % maxi(_z3_count, 1)
		var to_z2 : Array[int] = []
		for i in range(start, end_idx):
			if cam.distance_squared_to(_z3_pos[i]) < z2r2:
				to_z2.append(i)
		to_z2.reverse()
		for i in to_z2:
			_promote_z3_to_z2(i)

	# Z2 → Z1 or Z2 → Z3
	var i := _z2_count - 1
	while i >= 0:
		var pos      := _z2_pos[i]
		var promoted := false
		if _z1_active.size() < ZONE1_MAX:
			for pp in player_positions:
				if pos.distance_squared_to(pp) < z1r2:
					_promote_z2_to_z1(i)
					promoted = true
					break
		if not promoted and cam.distance_squared_to(pos) >= z2r2:
			_demote_z2_to_z3(i)
		i -= 1


func _promote_to_z1(pos: Vector3, team_id: int) -> CharacterBody3D:
	while not _pool.is_empty() and not is_instance_valid(_pool.back()):
		_pool.pop_back()
	if _pool.is_empty() or _z1_active.size() >= ZONE1_MAX:
		_add_to_z2(pos, team_id, 0); return null
	var z := _pool.pop_back() as CharacterBody3D
	if not is_instance_valid(z):
		_add_to_z2(pos, team_id, 0); return null
	z.process_mode = Node.PROCESS_MODE_INHERIT
	z.visible = true
	if z.has_method("reset"): z.reset(pos)
	else: z.global_position = pos; z.set_physics_process(true)
	if "team_id" in z: z.set("team_id", team_id)
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == team_id:
			if "friendly_base" in z: z.set("friendly_base", b)
		else:
			if "enemy_base" in z: z.set("enemy_base", b)
	_z1_active.append(z)
	return z

func return_to_pool(z: CharacterBody3D) -> void:
	_return_to_pool(z)

func _return_to_pool(z: CharacterBody3D) -> void:
	var idx := _z1_active.find(z)
	if idx != -1:
		_z1_active[idx] = _z1_active[_z1_active.size() - 1]
		_z1_active.resize(_z1_active.size() - 1)
	_pool.append(z)
	z.visible = false
	z.process_mode = Node.PROCESS_MODE_DISABLED
	z.set_physics_process(false)
	z.set_process(false)

func _add_to_z2(pos: Vector3, team_id: int, lane_id: int) -> void:
	if _z2_count >= MULTIMESH_MAX: _add_to_z3(pos, team_id, lane_id); return
	_z2_pos[_z2_count]  = pos
	_z2_vel[_z2_count]  = Vector2.ZERO
	_z2_team[_z2_count] = team_id
	_z2_lane[_z2_count] = lane_id
	_z2_count += 1

func _add_to_z3(pos: Vector3, team_id: int, lane_id: int) -> void:
	if _z3_count >= _z3_pos.size():
		_z3_pos.resize(_z3_pos.size() + 2048)
		_z3_team.resize(_z3_team.size() + 2048)
		_z3_lane.resize(_z3_lane.size() + 2048)
	_z3_pos[_z3_count]  = pos
	_z3_team[_z3_count] = team_id
	_z3_lane[_z3_count] = lane_id
	_z3_count += 1

func _promote_z3_to_z2(idx: int) -> void:
	var pos := _z3_pos[idx]; var team := _z3_team[idx]; var lane := _z3_lane[idx]
	_swap_remove_z3(idx); _add_to_z2(pos, team, lane)

func _promote_z2_to_z1(idx: int) -> void:
	var pos := _z2_pos[idx]; var team := _z2_team[idx]
	_swap_remove_z2(idx); _promote_to_z1(pos, team)

func _demote_z2_to_z3(idx: int) -> void:
	var pos := _z2_pos[idx]; var team := _z2_team[idx]; var lane := _z2_lane[idx]
	_swap_remove_z2(idx); _add_to_z3(pos, team, lane)

func _swap_remove_z2(idx: int) -> void:
	_z2_count -= 1
	_z2_pos[idx]  = _z2_pos[_z2_count]; _z2_vel[idx]  = _z2_vel[_z2_count]
	_z2_team[idx] = _z2_team[_z2_count]; _z2_lane[idx] = _z2_lane[_z2_count]

func _swap_remove_z3(idx: int) -> void:
	_z3_count -= 1
	_z3_pos[idx]  = _z3_pos[_z3_count]
	_z3_team[idx] = _z3_team[_z3_count]; _z3_lane[idx] = _z3_lane[_z3_count]


# ============================================================
# SPAWN API
# ============================================================
func spawn_horde(count: int, area: AABB, team_id: int = 1, lane_id: int = 0) -> void:
	for i in count:
		var pos := Vector3(
			area.position.x + randf() * area.size.x,
			area.position.y,
			area.position.z + randf() * area.size.z)
		_place_unit(pos, team_id, lane_id)
	# Init buffer for new count
	if _z2_count > 0:
		_upload_multimesh()
	print("[ZHM] spawn_horde done | z1=%d z2=%d z3=%d" % [_z1_active.size(), _z2_count, _z3_count])

func _place_unit(pos: Vector3, team_id: int, lane_id: int) -> void:
	var cam := _get_cam_pos()
	var d2  := cam.distance_squared_to(pos)
	if d2 < ZONE1_RADIUS * ZONE1_RADIUS and _z1_active.size() < ZONE1_MAX:
		_promote_to_z1(pos, team_id)
	elif d2 < ZONE2_RADIUS * ZONE2_RADIUS:
		_add_to_z2(pos, team_id, lane_id)
	else:
		_add_to_z3(pos, team_id, lane_id)

func spawn_from_scene(scene: PackedScene, pos: Vector3, team_id: int = 1) -> Node:
	var z := scene.instantiate()
	if not is_instance_valid(z): return null
	get_tree().current_scene.add_child(z)
	if z is Node3D: (z as Node3D).global_position = pos
	if "team_id" in z: z.set("team_id", team_id)
	if z is CharacterBody3D: _z1_active.append(z as CharacterBody3D)
	return z

func on_zombie_died(z: CharacterBody3D) -> void:
	zombie_died.emit(z.global_position)
	_return_to_pool(z)


# ============================================================
# SPATIAL HASH + NEIGHBOR PUSH (Z1 only)
# ============================================================
func _rebuild_grid() -> void:
	_grid.clear()
	for z in _z1_active:
		if not is_instance_valid(z): continue
		var c := Vector2i(int(z.global_position.x / GRID_CELL), int(z.global_position.z / GRID_CELL))
		if not _grid.has(c): _grid[c] = []
		(_grid[c] as Array).append(z)

func _push_neighbors() -> void:
	for z in _z1_active:
		if not is_instance_valid(z) or not z.has_method("push_neighbors"): continue
		var bc := Vector2i(int(z.global_position.x / GRID_CELL), int(z.global_position.z / GRID_CELL))
		var nb : Array = []
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key := Vector2i(bc.x + dx, bc.y + dz)
				if _grid.has(key): nb.append_array(_grid[key])
		z.push_neighbors(nb)

func get_z1_neighbors(pos: Vector3, radius: float) -> Array:
	var result : Array = []
	var cr := int(ceil(radius / GRID_CELL))
	var bc := Vector2i(int(pos.x / GRID_CELL), int(pos.z / GRID_CELL))
	var r2 := radius * radius
	for dx in range(-cr, cr + 1):
		for dz in range(-cr, cr + 1):
			var key := Vector2i(bc.x + dx, bc.y + dz)
			if not _grid.has(key): continue
			for z in _grid[key]:
				if is_instance_valid(z) and pos.distance_squared_to(z.global_position) <= r2:
					result.append(z)
	return result


# ============================================================
# DEAD-REF SWEEP
# ============================================================
func _sweep_dead_z1() -> void:
	var i := _z1_active.size() - 1
	while i >= 0:
		if not is_instance_valid(_z1_active[i]):
			_z1_active[i] = _z1_active[_z1_active.size() - 1]
			_z1_active.resize(_z1_active.size() - 1)
		i -= 1


# ============================================================
# HELPERS
# ============================================================
func _get_cam_pos() -> Vector3:
	if not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
	return _camera.global_position if is_instance_valid(_camera) else Vector3.ZERO

func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str: return node
	for child in node.get_children():
		var found := _find_node_by_class(child, class_name_str)
		if is_instance_valid(found): return found
	return null


# ============================================================
# SELECTION
# ============================================================
func select(units: Array) -> void:
	_selected.clear()
	for u in units:
		if is_instance_valid(u): _selected.append(u)

func get_selected() -> Array:
	_selected = _selected.filter(func(u): return is_instance_valid(u))
	return _selected

func clear_selection() -> void: _selected.clear()


# ============================================================
# PUBLIC COUNTERS
# ============================================================
func z1_count()    -> int: return _z1_active.size()
func z2_count()    -> int: return _z2_count
func z3_count()    -> int: return _z3_count
func total_count() -> int: return _z1_active.size() + _z2_count + _z3_count


# ============================================================
# FALLBACK MESH
# ============================================================
func _make_zombie_mesh() -> ArrayMesh:
	var st  := SurfaceTool.new()
	var arr := ArrayMesh.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := 0.22; var segs := 8
	for ring in 2:
		var y0 := float(ring); var y1 := float(ring + 1)
		for seg in segs:
			var a0 := TAU * float(seg) / float(segs)
			var a1 := TAU * float(seg + 1) / float(segs)
			var v00 := Vector3(cos(a0)*r, y0, sin(a0)*r)
			var v10 := Vector3(cos(a1)*r, y0, sin(a1)*r)
			var v01 := Vector3(cos(a0)*r, y1, sin(a0)*r)
			var v11 := Vector3(cos(a1)*r, y1, sin(a1)*r)
			st.add_vertex(v00); st.add_vertex(v11); st.add_vertex(v01)
			st.add_vertex(v00); st.add_vertex(v10); st.add_vertex(v11)
	st.commit(arr)
	return arr
func get_z1_active_by_team(tid: int) -> Array:
	var result : Array = []
	for z in _z1_active:
		if is_instance_valid(z) and "team_id" in z and int(z.get("team_id")) == tid:
			result.append(z)
	return result
