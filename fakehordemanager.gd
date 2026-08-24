# ============================================================
# ⚠ NOT LIVE — NOT AUTOLOADED, NOT INSTANTIATED (2026-07-25) ⚠
# Not in project.godot's autoload list, and fakehordemanager.tscn isn't
# referenced by main.tscn or any other live scene. Editing this file has
# no effect on gameplay. Real zombie spawning lives in Egg.gd / HiveCluster.gd
# (eggs/nests) and LaneSpawner.gd (lane delivery).
# ============================================================
# FakeHordeManager.gd
# ============================================================
# 50k fake horde units via MultiMesh + LaneFlowField
# Promotes to real zombies on player proximity
# ============================================================
extends Node

const MAX_UNITS         : int   = 50000
const PROMOTE_DIST_SQ   : float = 20.0 * 20.0
const PROMOTE_PER_FRAME : int   = 8
const MOVE_SPEED        : float = 3.5
const CELL_SIZE         : float = 6.0
const UPDATE_BATCH_SIZE : int   = 512
const GRID_REBUILD_HZ   : float = 4.0

@export var zombie_scene : PackedScene
@export var mesh         : Mesh

# ── Data arrays ───────────────────────────────────────────────
var _pos   : PackedVector3Array = []
var _vel   : PackedVector2Array = []
var _team  : PackedInt32Array   = []
var _lane  : PackedInt32Array   = []   # lane 0/1/2
var _alive : PackedByteArray    = []
var _count : int = 0

# ── MultiMesh ─────────────────────────────────────────────────
var _mmi : MultiMeshInstance3D = null
var _mm  : MultiMesh           = null

# ── Spatial grid ──────────────────────────────────────────────
var _grid       : Dictionary = {}
var _grid_timer : float      = 0.0

# ── Refs ──────────────────────────────────────────────────────
var _flow_field : Node  = null
var _zhm        : Node  = null
var _players    : Array = []

# ── Batch cursor ──────────────────────────────────────────────
var _batch_cursor : int = 0
var _frame        : int = 0


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	_zhm = get_tree().get_first_node_in_group("zombie_horde_manager")
	# LaneFlowField is an autoload
	_flow_field = get_node_or_null("/root/LaneFlowField")
	_build_multimesh()
	print("[FakeHorde] ready | flow=%s zhm=%s" % [
		_flow_field.name if is_instance_valid(_flow_field) else "NULL",
		_zhm.name        if is_instance_valid(_zhm)        else "NULL"])


func _build_multimesh() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format       = MultiMesh.TRANSFORM_3D
	_mm.instance_count         = MAX_UNITS
	_mm.visible_instance_count = 0
	_mm.mesh = mesh if is_instance_valid(mesh) else _make_fallback_mesh()

	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	add_child(_mmi)


# ============================================================
# SPAWN
# ============================================================
func spawn(position: Vector3, team_id: int, lane_id: int = 0) -> int:
	# Recycle dead slot first
	if _count >= MAX_UNITS:
		for i in _alive.size():
			if _alive[i] == 0:
				_set_slot(i, position, team_id, lane_id)
				return i
		push_warning("[FakeHorde] Pool full")
		return -1

	var i : int = _count
	_pos.append(position)
	_vel.append(Vector2.ZERO)
	_team.append(team_id)
	_lane.append(lane_id)
	_alive.append(1)
	_count += 1
	_mm.visible_instance_count = _count
	_mm.set_instance_transform(i, _make_transform(position))
	return i


func spawn_horde(positions: Array, team_id: int, lane_id: int = 0) -> void:
	for p in positions:
		spawn(p, team_id, lane_id)


func _set_slot(i: int, position: Vector3, team_id: int, lane_id: int) -> void:
	_pos[i]   = position
	_vel[i]   = Vector2.ZERO
	_team[i]  = team_id
	_lane[i]  = lane_id
	_alive[i] = 1
	_mm.set_instance_transform(i, _make_transform(position))
	if i >= _mm.visible_instance_count:
		_mm.visible_instance_count = i + 1


func kill(i: int) -> void:
	if i < 0 or i >= _count: return
	_alive[i] = 0
	_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	_frame += 1

	# Cache player positions every 6 frames
	if _frame % 6 == 0: _cache_players()

	# Rebuild spatial grid at GRID_REBUILD_HZ
	_grid_timer += delta
	if _grid_timer >= 1.0 / GRID_REBUILD_HZ:
		_grid_timer = 0.0
		_rebuild_grid()

	# Update rolling batch of units
	_update_batch(delta)

	# Check promotions every frame (capped by PROMOTE_PER_FRAME)
	_check_promotions()


func _cache_players() -> void:
	_players.clear()
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node3D:
			_players.append((p as Node3D).global_position)


# ============================================================
# UPDATE BATCH
# ============================================================
func _update_batch(delta: float) -> void:
	if _count == 0: return
	var end : int = mini(_batch_cursor + UPDATE_BATCH_SIZE, _count)
	for i in range(_batch_cursor, end):
		if _alive[i] == 0: continue
		_move_unit(i, delta)
	_batch_cursor = end % _count


func _move_unit(i: int, delta: float) -> void:
	var pos  : Vector3 = _pos[i]
	var dir  : Vector3 = _get_flow_dir(pos, _team[i], _lane[i])

	# Separation
	var sep : Vector3 = _get_separation(i, pos)
	if sep.length_squared() > 0.001:
		dir = (dir + sep * 0.3).normalized()

	if dir.length_squared() < 0.001:
		return

	pos.x += dir.x * MOVE_SPEED * delta
	pos.z += dir.z * MOVE_SPEED * delta
	_pos[i] = pos

	_mm.set_instance_transform(i, _make_transform(pos, dir))


func _get_flow_dir(pos: Vector3, team_id: int, lane_id: int) -> Vector3:
	# Use LaneFlowField.get_flow(team, lane, pos)
	if is_instance_valid(_flow_field) and _flow_field.is_ready():
		var d : Vector3 = _flow_field.get_flow(team_id, lane_id, pos)
		if d.length_squared() > 0.001: return d

	# Fallback: move toward enemy base directly
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == team_id: continue
		var d2 := pos - (b as Node3D).global_position
		d2.y = 0.0
		if d2.length_squared() > 0.1: return -d2.normalized()
	return Vector3.FORWARD


func _get_separation(i: int, pos: Vector3) -> Vector3:
	var force : Vector3 = Vector3.ZERO
	var count : int     = 0
	for j in _grid_get_nearby(pos):
		if j == i or _alive[j] == 0: continue
		var diff : Vector3 = pos - _pos[j]
		diff.y = 0.0
		var d : float = diff.length()
		if d < 0.01 or d > 1.2: continue
		force += diff.normalized() * (1.0 - d / 1.2)
		count += 1
		if count >= 4: break
	return force


# ============================================================
# PROMOTION — fake → real zombie
# ============================================================
func _check_promotions() -> void:
	if _players.is_empty(): return
	if not is_instance_valid(_zhm): return
	if not is_instance_valid(zombie_scene): return

	var promoted : int = 0
	for i in range(_count):
		if promoted >= PROMOTE_PER_FRAME: break
		if _alive[i] == 0: continue
		var pos : Vector3 = _pos[i]
		for player_pos in _players:
			if pos.distance_squared_to(player_pos) <= PROMOTE_DIST_SQ:
				_promote(i, pos)
				promoted += 1
				break


func _promote(i: int, pos: Vector3) -> void:
	var team_id : int = _team[i]
	kill(i)

	if not _zhm.has_method("spawn_from_scene"): return
	var z : Node = _zhm.spawn_from_scene(zombie_scene, pos)
	if not is_instance_valid(z): return

	if "team_id"  in z: z.set("team_id",  team_id)
	if "enemy_base" in z:
		# Wire enemy base so zombie knows where to march
		for b in get_tree().get_nodes_in_group("bases"):
			if is_instance_valid(b) and "team_id" in b and int(b.get("team_id")) != team_id:
				z.set("enemy_base", b); break
	# Small spread so promoted zombies don't stack
	if z is CharacterBody3D:
		var rng := Vector3(randf_range(-1,1), 0, randf_range(-1,1)).normalized()
		(z as CharacterBody3D).velocity = rng * 2.0


# ============================================================
# SPATIAL GRID
# ============================================================
func _rebuild_grid() -> void:
	_grid.clear()
	for i in _count:
		if _alive[i] == 0: continue
		var c := _cell(_pos[i])
		if not _grid.has(c): _grid[c] = []
		(_grid[c] as Array).append(i)

func _cell(pos: Vector3) -> Vector2i:
	return Vector2i(int(pos.x / CELL_SIZE), int(pos.z / CELL_SIZE))

func _grid_get_nearby(pos: Vector3) -> Array:
	var c := _cell(pos)
	var result : Array = []
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(c.x + dx, c.y + dz)
			if _grid.has(key): result += _grid[key]
	return result


# ============================================================
# TRANSFORM HELPER
# ============================================================
func _make_transform(pos: Vector3, dir: Vector3 = Vector3.FORWARD) -> Transform3D:
	var basis : Basis = Basis.IDENTITY
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() > 0.001:
		flat = flat.normalized()
		var right := flat.cross(Vector3.UP).normalized()
		basis = Basis(right, Vector3.UP, -flat)
	return Transform3D(basis, pos)


# ============================================================
# FALLBACK MESH
# ============================================================
func _make_fallback_mesh() -> ArrayMesh:
	var st  := SurfaceTool.new()
	var arr := ArrayMesh.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Simple capsule-ish body — 8 sided cylinder, 2 rings
	var r : float = 0.22; var segs : int = 8
	for ring in 2:
		var y0 : float = float(ring); var y1 : float = float(ring + 1)
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


# ============================================================
# PUBLIC API
# ============================================================
func alive_count() -> int:
	var n : int = 0
	for i in _count:
		if _alive[i] == 1: n += 1
	return n

func total_count() -> int: return _count
