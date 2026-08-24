# ============================================================
# ZombieHordeManager.gd — AUTOLOAD — L4D2-Style Horde Director
# ============================================================
# ARCHITECTURE:
#
#   Zone 1 (Z1)  — Real CharacterBody3D, full physics + AI
#                  Up to ZONE1_MAX simultaneous. LOD 0/1 here.
#
#   Zone 2 (Z2)  — MultiMesh crowd. Packed arrays, no scene nodes.
#                  Moved in rolling batches to spread CPU load.
#
#   Zone 3 (Z3)  — Dormant positions only. Zero CPU, zero GPU.
#                  Promoted to Z2 when player approaches.
#
#   Director     — L4D2-style AI Director controls spawn pacing.
#                  Tracks intensity, creates crescendo/relief cycles,
#                  never lets the game feel empty or overwhelming.
#
#   Player Push  — Every grid rebuild, nearby player refs are pushed
#                  directly into each zombie's _players_cache.
#                  Zombies detect the player with ZERO group scans.
# ============================================================
extends Node

# ── ZONE CONSTANTS ───────────────────────────────────────────
const ZONE1_RADIUS      : float = 45.0
const ZONE2_RADIUS      : float = 350.0
# REAL PERFORMANCE FIX (2026-07-21): measured the ACTUAL zombie mesh --
# 55,686 real vertices per zombie across 9 mesh surfaces, plus 28 separate
# PhysicalBone3D ragdoll bodies and a full AnimationTree, all real
# CharacterBody3D-tier cost (Zone 1). At the old ZONE1_MAX=150, up to
# 150 x 55,686 = ~8.35 MILLION vertices of skinned character geometry could
# be rendering simultaneously -- confirmed live: "15 FPS when zombies are
# close" (exactly the Zone-1-heavy case, since Zone 2/3 use the cheap
# multimesh crowd instead). Reduced to a real, GPU-sane budget. The
# complete fix is reducing the SOURCE mesh's vertex count (needs actual
# mesh decimation, not something GDScript can do -- see the Blender
# decimation script provided alongside this fix); this cap is the
# immediately-actionable mitigation.
const ZONE1_MAX         : int   = 60
const POOL_SIZE         : int   = 60
const MULTIMESH_MAX     : int   = 50_000
const CROWD_SPEED       : float = 3.8
const GRID_CELL         : float = 8.0
const UPDATE_BATCH_SIZE : int   = 256
const CLEANUP_INTERVAL  : float = 3.0
const PROMOTE_HZ        : float = 5.0
const ZOMBIE_SCALE      : float = 0.012
const ZOMBIE_Y_OFFSET   : float = 1.0

# ── LOD DISTANCES (reduced in splitscreen) ───────────────────
var LOD0_DIST : float = 40.0
var LOD1_DIST : float = 120.0
var LOD2_DIST : float = 350.0

# Beyond this radius shadow casting is disabled to cut GPU draw calls
# as horde density peaks near spawn edges (one shadow pass per mesh × 40 Z1
# zombies = 200 shadow draw calls eliminated when the pack surges forward).
const MESH_LOD_DIST_SQ : float = 28.0 * 28.0

# ── SCENE / MESH ─────────────────────────────────────────────
var zombie_scene    : PackedScene = preload("res://zombie/zombie.tscn")
var zombie_mesh     : Mesh        = null
var zombie_material : Material    = null

# ── ZONE 1 — real physics zombies ────────────────────────────
var _pool      : Array[CharacterBody3D] = []
var _z1_active : Array[CharacterBody3D] = []

# ── ZONE 2 — multimesh crowd (packed arrays, no nodes) ───────
var _mm_instance : MultiMeshInstance3D = null
var _multimesh   : MultiMesh           = null
var _z2_count    : int = 0
var _z2_pos      : PackedVector3Array  = PackedVector3Array()
var _z2_vel      : PackedVector2Array  = PackedVector2Array()
var _z2_team     : PackedInt32Array    = PackedInt32Array()
var _z2_lane     : PackedInt32Array    = PackedInt32Array()
var _mm_buffer   : PackedFloat32Array  = PackedFloat32Array()
var _mm_buf_count : int = 0

# ── ZONE 3 — dormant position data ───────────────────────────
var _z3_count : int = 0
var _z3_pos   : PackedVector3Array = PackedVector3Array()
var _z3_team  : PackedInt32Array   = PackedInt32Array()
var _z3_lane  : PackedInt32Array   = PackedInt32Array()

# ── SPATIAL GRID ─────────────────────────────────────────────
var _grid : Dictionary = {}

# ── SHARED GROUND CACHE ───────────────────────────────────────
# One PhysicsDirectSpaceState3D shape cast per occupied grid cell per
# grid-rebuild cycle (4 Hz) replaces per-zombie per-physics-frame raycasts.
# Zombies read get_ground_y() instead of calling intersect_ray each tick.
var _ground_y_cache : Dictionary    = {}   # Vector2i → float
var _ground_shape   : SphereShape3D = null # reused across all cell casts

# ── PLAYER POSITIONS for grid push ───────────────────────────
# Updated once per grid rebuild — used to push player refs into
# each zombie's _players_cache (zero group-scan detection).
var _player_nodes    : Array = []   # Node3D refs
var _player_positions: Array = []   # Vector3 for distance checks

# ── TURRET CACHE for grid push ────────────────────────────────
# Collected alongside players every 0.25s so zombies share one
# group-scan result per rebuild instead of scanning per-frame.
var _turret_nodes    : Array = []   # Node3D refs

# ── REFS / STATE ─────────────────────────────────────────────
var _flow_field   : Node     = null
var _camera       : Camera3D = null
var _cam_pos      : Vector3  = Vector3.ZERO
var _initialized  : bool     = false

# ── TIMERS ───────────────────────────────────────────────────
var _grid_t      : float = 0.0
var _promote_t   : float = 0.0
var _promote_acc : int   = 0
var _batch_cursor: int   = 0
var _frame       : int   = 0
var _cleanup_t   : float = 0.0
var _init_retry_t: float = 0.0

# ── SELECTION ─────────────────────────────────────────────────
var _selected : Array[CharacterBody3D] = []

# ── SIGNALS ──────────────────────────────────────────────────
signal selection_changed(selected: Array)
signal zombie_died(pos: Vector3)

# ============================================================
# L4D2 AI DIRECTOR
# ============================================================
# The Director monitors "intensity" — how hard the player is being
# pressured — and controls the spawn cadence to create the tension
# waves L4D2 is famous for: a quiet walk, then a sudden mob.
#
# Intensity rises when zombies are close to players.
# Intensity falls passively (the "relief" phase).
# When intensity drops below MIN_INTENSITY, a new mob is triggered.
# Peak intensity causes a temporary spawn pause ("recovery").
# ============================================================

# Director configuration
const DIR_TICK_RATE    : float = 1.0   # evaluate every second
const DIR_MIN_INTENSITY: float = 0.15  # below this → trigger a mob
const DIR_MAX_INTENSITY: float = 1.0   # above this → pause spawning
const DIR_DECAY_RATE   : float = 0.08  # intensity lost per second (relief speed)
const DIR_PER_ZOMBIE   : float = 0.012 # intensity added per nearby Z1 zombie
const DIR_PROXIMITY_R  : float = 30.0  # radius considered "near player"
const DIR_MOB_SIZE_MIN : int   = 4     # min zombies in a director mob
const DIR_MOB_SIZE_MAX : int   = 14    # max zombies in a director mob

var _director_intensity  : float = 0.3   # 0 = calm, 1 = chaos
var _director_t          : float = 0.0
var _director_paused     : bool  = false  # true during relief (L4D2 "relax" window)
var _director_pause_t    : float = 0.0
const DIR_PAUSE_DURATION : float = 8.0   # seconds of peace after a peak

## External difficulty multiplier (0.5 = easy, 1.0 = normal, 2.0 = hard)
var director_difficulty  : float = 1.0
## AI DIRECTOR PERMANENTLY DISABLED (2026-07-25): this timer-based mob spawner
## used to throw zombies into the world independent of eggs/nests. Only
## eggs/nests (Egg.gd / HiveCluster.gd) should spawn zombies now. Left as a
## var (rather than deleted) so _run_director() below still compiles, but it
## must stay false — do not re-enable.
var director_enabled     : bool  = false


# ============================================================
# LIFECYCLE
# ============================================================
func _enter_tree() -> void:
	Engine.register_singleton("ZombieHordeManager", self)

func _exit_tree() -> void:
	Engine.unregister_singleton("ZombieHordeManager")

func _ready() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	var pc : int = int(gs.get("player_count") if is_instance_valid(gs) and "player_count" in gs else 1)
	if pc > 1:
		LOD0_DIST = 20.0; LOD1_DIST = 50.0; LOD2_DIST = 120.0
	_setup_multimesh()
	_z2_pos.resize(MULTIMESH_MAX); _z2_vel.resize(MULTIMESH_MAX)
	_z2_team.resize(MULTIMESH_MAX); _z2_lane.resize(MULTIMESH_MAX)
	_z3_pos.resize(4096); _z3_team.resize(4096); _z3_lane.resize(4096)


func _process(delta: float) -> void:
	if not _initialized:
		_init_retry_t += delta
		if _init_retry_t >= 0.5: _init_retry_t = 0.0; _try_init()
		return

	_frame  += 1
	_cam_pos = _get_cam_pos()

	# Z2 crowd movement — rolling batch
	if _z2_count > 0: _update_z2_batch(delta)
	if _frame % 3 == 0 and _z2_count > 0: _upload_multimesh()

	# Spatial grid + neighbor + player push — 4x/sec
	_grid_t += delta
	if _grid_t >= 0.25:
		_grid_t = 0.0
		_refresh_player_list()
		_rebuild_grid()
		_push_neighbors()
		_push_players_to_zombies()   # L4D2 key: players visible to all nearby zombies instantly

	# Z1 LOD — every 15 frames (~4x/sec at 60fps)
	if _frame % 15 == 0: _update_z1_lod()

	# Zone promotions
	_promote_t += delta
	if _promote_t >= 1.0 / PROMOTE_HZ: _promote_t = 0.0; _check_promotions()

	# Director (L4D2 intensity + mob spawning)
	_director_t += delta
	if _director_t >= DIR_TICK_RATE: _director_t = 0.0; _run_director()

	# Cleanup dead refs
	_cleanup_t += delta
	if _cleanup_t >= CLEANUP_INTERVAL: _cleanup_t = 0.0; _sweep_dead_z1()


# ============================================================
# INITIALISATION
# ============================================================
func _try_init() -> void:
	if not is_instance_valid(zombie_mesh):
		var glb := load("res://zombie/scorpomesh.glb") as PackedScene
		if is_instance_valid(glb):
			var temp := glb.instantiate()
			for child in temp.find_children("*", "MeshInstance3D", true, false):
				var mi := child as MeshInstance3D
				if is_instance_valid(mi) and is_instance_valid(mi.mesh):
					zombie_mesh = mi.mesh; break
			temp.queue_free()
		if is_instance_valid(zombie_mesh): _multimesh.mesh = zombie_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.30, 0.48)   # cool grey-blue = Z2 crowd/dormant
	mat.roughness = 0.90; mat.metallic = 0.0
	zombie_material = mat
	_mm_instance.material_override = zombie_material

	if not is_instance_valid(_flow_field):
		_flow_field = get_node_or_null("/root/LaneFlowField")

	if _pool.is_empty() and is_instance_valid(zombie_scene):
		for _i in POOL_SIZE:
			var z := zombie_scene.instantiate() as CharacterBody3D
			if not z: continue
			z.set_physics_process(false)
			z.process_mode = Node.PROCESS_MODE_DISABLED
			z.visible = false
			add_child(z)
			_pool.append(z)

	if not is_instance_valid(_ground_shape):
		_ground_shape = SphereShape3D.new()
		_ground_shape.radius = 0.1

	_initialized = true
	print("[ZHM] ready | pool=%d flow=%s" % [_pool.size(),
		_flow_field.name if is_instance_valid(_flow_field) else "NULL"])


func reset_for_new_scene() -> void:
	_pool.clear(); _z1_active.clear(); _selected.clear(); _grid.clear()
	_z2_count = 0; _z3_count = 0; _camera = null
	_player_nodes.clear(); _player_positions.clear(); _turret_nodes.clear()
	_director_intensity = 0.3; _director_paused = false
	_initialized = false; _init_retry_t = 0.0; _flow_field = null
	print("[ZHM] reset")


# ============================================================
# MULTIMESH
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
	_mm_buffer.resize(MULTIMESH_MAX * 12)
	_mm_buffer.fill(0.0)


# ============================================================
# Z2 CROWD SIM — rolling batch, flow-field steered
# ============================================================
func _update_z2_batch(delta: float) -> void:
	var end : int = mini(_batch_cursor + UPDATE_BATCH_SIZE, _z2_count)
	for i in range(_batch_cursor, end):
		var p    : Vector3 = _z2_pos[i]
		var flow := _sample_flow(p, _z2_team[i], _z2_lane[i])
		var v    : Vector2 = _z2_vel[i]
		v = v.lerp(flow * CROWD_SPEED, 0.15)
		_z2_vel[i]    = v
		_z2_pos[i].x += v.x * delta
		_z2_pos[i].z += v.y * delta
	_batch_cursor = end % maxi(_z2_count, 1)


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
# MULTIMESH UPLOAD
# ============================================================
# Z2 crowd has no skeleton -- MultiMeshInstance3D packs raw transforms only,
# it can't play an AnimationPlayer clip per instance. The real technique for
# "idle" crowd members here (same category as foliage/grass wind sway in
# most engines) is a per-instance breathing bob applied to the transform
# itself: a small sinusoidal Y offset, phase-desynced per instance so the
# whole crowd doesn't breathe in lockstep, only active while an instance is
# actually near-stationary (same v.length_squared() <= 0.25 threshold the
# yaw-freeze already uses, i.e. "not actively pathing").
const IDLE_BOB_AMPLITUDE := 0.045
const IDLE_BOB_SPEED     := 3.2

func _upload_multimesh() -> void:
	if _z2_count == 0: return
	_multimesh.visible_instance_count = _z2_count
	var s := ZOMBIE_SCALE
	var t := float(_frame) * (1.0 / 60.0)  # wall-clock-ish time for the bob
	for i in range(_z2_count):
		var p   : Vector3 = _z2_pos[i]
		var v   : Vector2 = _z2_vel[i]
		var yaw : float   = 0.0
		var moving := v.length_squared() > 0.25
		if moving: yaw = atan2(v.x, v.y) - PI * 0.5
		var cy := cos(yaw); var sy := sin(yaw)
		var bob_y := 0.0
		if not moving:
			var phase := float(i % 41) * 0.87  # desync without a per-instance array
			bob_y = sin(t * IDLE_BOB_SPEED + phase) * IDLE_BOB_AMPLITUDE
		var b  := i * 12
		_mm_buffer[b+0]=cy*s;  _mm_buffer[b+1]=0.0;   _mm_buffer[b+2]=-sy*s; _mm_buffer[b+3]=p.x
		_mm_buffer[b+4]=0.0;   _mm_buffer[b+5]=s;     _mm_buffer[b+6]=0.0;   _mm_buffer[b+7]=p.y+ZOMBIE_Y_OFFSET+bob_y
		_mm_buffer[b+8]=sy*s;  _mm_buffer[b+9]=0.0;   _mm_buffer[b+10]=cy*s; _mm_buffer[b+11]=p.z
	_multimesh.buffer = _mm_buffer


# ============================================================
# LOD FOR Z1 ZOMBIES — every 15 frames
# LOD2/3: physics disabled, ZHM moves them directly.
# This is the key to scalability — only LOD0/1 run full physics.
# ============================================================
func _update_z1_lod() -> void:
	if not is_instance_valid(_camera): _camera = get_viewport().get_camera_3d()
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
			# set_lod() on the zombie handles physics_process itself:
			#   LOD 0/1/2 → physics ON (zombie self-drives, incl. cheap LOD2 march)
			#   LOD 3     → physics OFF (sleeping)
			# We only manage _process (audio/anim housekeeping) and visibility here.
			if z.has_method("set_lod"): z.set_lod(nlod)
			match nlod:
				0, 1: z.set_process(true)
				2, 3: z.set_process(false)
			z.visible = nlod < 3
			if nlod == 2: z.call_deferred("_snap_to_ground")
			if nlod < 3: _apply_lod_tint(z, nlod)

		if z.has_method("set_mesh_near"):
			z.set_mesh_near(d2 < MESH_LOD_DIST_SQ)


# ============================================================
# PLAYER LIST — refreshed each grid tick
# ============================================================
func _refresh_player_list() -> void:
	_player_nodes.clear()
	_player_positions.clear()
	_turret_nodes.clear()
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p) or not (p is Node3D): continue
		if "is_dead" in p and p.get("is_dead"): continue
		_player_nodes.append(p)
		_player_positions.append((p as Node3D).global_position)
	for t in get_tree().get_nodes_in_group("turrets"):
		if not is_instance_valid(t) or not (t is Node3D): continue
		_turret_nodes.append(t)


# ============================================================
# PLAYER PUSH — L4D2 technique
# Each zombie gets a list of player refs within its detection range.
# This replaces per-zombie "player" group scans entirely.
# Cost: O(Z1 × players) once per 0.25s — negligible for 1-4 players.
# ============================================================
func _push_players_to_zombies() -> void:
	if _player_nodes.is_empty() and _turret_nodes.is_empty(): return
	const PUSH_RANGE  : float = 50.0    # push players within this distance to zombie
	const PUSH_R2     : float = PUSH_RANGE * PUSH_RANGE
	# Turret push range covers both blocker engage (~6 u) and aggro scan (~22 u).
	const TURRET_RANGE : float = 25.0
	const TURRET_R2    : float = TURRET_RANGE * TURRET_RANGE

	for z in _z1_active:
		if not is_instance_valid(z): continue
		var zpos : Vector3 = z.global_position
		if z.has_method("push_players"):
			var nearby : Array = []
			for i in _player_nodes.size():
				if zpos.distance_squared_to(_player_positions[i]) < PUSH_R2:
					nearby.append(_player_nodes[i])
			z.push_players(nearby)
		if z.has_method("push_turrets"):
			var nearby_t : Array = []
			for t in _turret_nodes:
				if zpos.distance_squared_to((t as Node3D).global_position) < TURRET_R2:
					nearby_t.append(t)
			z.push_turrets(nearby_t)


# ============================================================
# SPATIAL GRID + NEIGHBOR PUSH
# ============================================================
func _rebuild_grid() -> void:
	_grid.clear()
	for z in _z1_active:
		if not is_instance_valid(z): continue
		var c := Vector2i(int(z.global_position.x / GRID_CELL),
						  int(z.global_position.z / GRID_CELL))
		if not _grid.has(c): _grid[c] = []
		(_grid[c] as Array).append(z)
	_rebuild_ground_cache()


# One downward shape cast per occupied grid cell replaces up to ZONE1_MAX
# per-zombie per-physics-frame raycasts with a handful of 4 Hz queries.
func _rebuild_ground_cache() -> void:
	_ground_y_cache.clear()
	if not is_instance_valid(_ground_shape) or _grid.is_empty(): return
	var world : World3D = get_viewport().find_world_3d()
	if not is_instance_valid(world): return
	var space : PhysicsDirectSpaceState3D = world.direct_space_state
	if not is_instance_valid(space): return

	# Exclude all active Z1 zombie bodies so the cast finds terrain, not zombies.
	var excl : Array[RID] = []
	for z in _z1_active:
		if is_instance_valid(z): excl.append(z.get_rid())

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape                = _ground_shape
	params.collision_mask       = 0xFFFF
	params.collide_with_bodies  = true
	params.collide_with_areas   = false
	params.exclude              = excl

	const CAST_TOP   : float = 80.0
	const CAST_DEPTH : float = 90.0

	# REAL BUG FIX: PhysicsDirectSpaceState3D.cast_motion() in Godot 4.7 takes
	# only the params object -- the motion vector is a property ON
	# PhysicsShapeQueryParameters3D (params.motion), not a second call
	# argument. Confirmed via the real parse error this caused: "Too many
	# arguments for 'cast_motion()' call. Expected at most 1 but received 2."
	params.motion = Vector3(0.0, -CAST_DEPTH, 0.0)

	for cell in _grid.keys():
		var cx : float = (float(cell.x) + 0.5) * GRID_CELL
		var cz : float = (float(cell.y) + 0.5) * GRID_CELL
		params.transform = Transform3D(Basis.IDENTITY, Vector3(cx, CAST_TOP, cz))
		# cast_motion returns [safe_fraction, unsafe_fraction]; unsafe < 1 = hit.
		var result : Array = space.cast_motion(params)
		if result.size() == 2 and result[1] < 1.0:
			# unsafe_fraction gives sphere-centre Y at first contact; subtract
			# sphere radius to get the actual ground surface height.
			_ground_y_cache[cell] = CAST_TOP - CAST_DEPTH * result[1] - _ground_shape.radius


## Returns the cached ground surface Y for the grid cell containing world_pos,
## or -1000.0 on a cache miss (zombie off-grid or cache not yet built).
func get_ground_y(world_pos: Vector3) -> float:
	var cell := Vector2i(int(world_pos.x / GRID_CELL), int(world_pos.z / GRID_CELL))
	return _ground_y_cache.get(cell, -1000.0)


func _push_neighbors() -> void:
	for z in _z1_active:
		if not is_instance_valid(z) or not z.has_method("push_neighbors"): continue
		var bc := Vector2i(int(z.global_position.x / GRID_CELL),
						   int(z.global_position.z / GRID_CELL))
		var nb : Array = []
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key := Vector2i(bc.x + dx, bc.y + dz)
				if _grid.has(key): nb.append_array(_grid[key])
		z.push_neighbors(nb)


# ============================================================
# L4D2 AI DIRECTOR — runs every DIR_TICK_RATE seconds
#
# The Director's job: keep the game feeling intense but fair.
# It watches intensity, triggers mob surges when things are quiet,
# and creates a recovery pause after peak pressure — just like L4D2.
# ============================================================
func _run_director() -> void:
	if not director_enabled: return

	# ── Recovery pause after peak ────────────────────────────
	if _director_paused:
		_director_pause_t -= DIR_TICK_RATE
		if _director_pause_t <= 0.0:
			_director_paused = false
			_director_intensity = DIR_MIN_INTENSITY + 0.1   # restart from low tension
		return

	# ── Measure intensity from Z1 proximity to players ───────
	if not _player_positions.is_empty():
		var pressure : float = 0.0
		var pr2 : float = DIR_PROXIMITY_R * DIR_PROXIMITY_R
		for z in _z1_active:
			if not is_instance_valid(z): continue
			for pp in _player_positions:
				if z.global_position.distance_squared_to(pp) < pr2:
					pressure += DIR_PER_ZOMBIE
					break  # count each zombie once
		# Blend toward measured pressure — smoothed, not instant
		_director_intensity = lerp(_director_intensity,
			clampf(pressure * director_difficulty, 0.0, DIR_MAX_INTENSITY), 0.35)

	# ── Passive decay (the "relief" — L4D2's breathing room) ─
	_director_intensity -= DIR_DECAY_RATE * DIR_TICK_RATE

	# ── Peak → trigger recovery pause ────────────────────────
	if _director_intensity >= DIR_MAX_INTENSITY * 0.95:
		_director_paused  = true
		_director_pause_t = DIR_PAUSE_DURATION
		return

	# ── Below threshold → trigger a mob surge ────────────────
	if _director_intensity < DIR_MIN_INTENSITY:
		_director_trigger_mob()


## Spawn a sudden mob burst — L4D2's "mobbing" behaviour.
## Zombies materialize near the player's flanks/behind, never directly
## in front, so the player has a moment to react (fair but scary).
func _director_trigger_mob() -> void:
	if _player_positions.is_empty(): return

	var mob_size : int = int(randf_range(DIR_MOB_SIZE_MIN, DIR_MOB_SIZE_MAX) \
		* director_difficulty)
	mob_size = clampi(mob_size, 1, ZONE1_MAX - _z1_active.size())
	if mob_size <= 0: return

	# Find a player to mob — pick the most isolated one
	var focus_pos : Vector3 = _player_positions[0]

	# Spawn in a ring 18-32 m behind/flanking the player
	# Uses camera forward to determine "behind"
	var cam_fwd := Vector3.FORWARD
	if is_instance_valid(_camera):
		cam_fwd = -_camera.global_transform.basis.z
		cam_fwd.y = 0.0
		if cam_fwd.length_squared() > 0.01: cam_fwd = cam_fwd.normalized()

	for i in mob_size:
		# Angle biased away from camera forward (spawn behind / flanks)
		var bias     : float = PI + randf_range(-0.9, 0.9)   # roughly behind
		var angle    : float = atan2(cam_fwd.x, cam_fwd.z) + bias
		var dist     : float = randf_range(18.0, 32.0)
		var offset   : Vector3 = Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		var spawn_pos : Vector3 = focus_pos + offset

		# Try to find ground Y
		var space := get_tree().root.get_world_3d().direct_space_state
		if is_instance_valid(space):
			var ray := PhysicsRayQueryParameters3D.create(
				spawn_pos + Vector3(0, 80, 0), spawn_pos + Vector3(0, -10, 0))
			ray.collision_mask = 1
			var hit := space.intersect_ray(ray)
			if not hit.is_empty():
				spawn_pos.y = (hit.position as Vector3).y + 0.3

		_place_unit(spawn_pos, 2, 0)   # team 2 = enemies; lane 0

	# Reset intensity upward after mob spawns (they're now close to player)
	_director_intensity = clampf(_director_intensity + float(mob_size) * DIR_PER_ZOMBIE, 0.0, 1.0)
	print("[Director] mob of %d | intensity=%.2f" % [mob_size, _director_intensity])


# ============================================================
# ZONE PROMOTIONS — Z3→Z2→Z1 as player approaches
# ============================================================
func _check_promotions() -> void:
	var cam  := _cam_pos
	var z1r2 := ZONE1_RADIUS * ZONE1_RADIUS
	var z2r2 := ZONE2_RADIUS * ZONE2_RADIUS

	if _player_positions.is_empty():
		_player_positions.append(cam)

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
		for i in to_z2: _promote_z3_to_z2(i)

	# Z2 → Z1 (or Z2 → Z3 if out of range)
	# REAL BUG FIX (2026-07-24): "zombies stuck at a door have no idle/attack
	# animation" -- this loop processed Z2 candidates in raw array index
	# order (arbitrary, correlating with spawn order), not by actual
	# proximity to the player. With a hard ZONE1_MAX cap on real animated
	# CharacterBody3D zombies, a chokepoint packed with many zombies within
	# ZONE1_RADIUS turned "which ones get real animation" into a coin flip
	# -- zombies actually fighting at the front of the crowd could lose the
	# scarce Zone-1 slots to unrelated zombies elsewhere in range while
	# still visually reading as "stuck"/lifeless (Zone-2 multimesh crowd
	# zombies have no AnimationPlayer at all, only a position bob -- see
	# _upload_multimesh's idle-bob note). Fixed: when slots are scarce,
	# rank candidates by actual distance to the nearest player and promote
	# the closest ones first, so the zombies the player is actually looking
	# at/fighting get real animated bodies.
	var free_slots := ZONE1_MAX - _z1_active.size()
	if free_slots > 0 and _z2_count > 0:
		var candidates : Array = []   # [dist2, idx]
		for j in range(_z2_count):
			var p := _z2_pos[j]
			var best_d2 := INF
			for pp in _player_positions:
				var d2 := p.distance_squared_to(pp)
				if d2 < best_d2: best_d2 = d2
			if best_d2 < z1r2:
				candidates.append([best_d2, j])
		candidates.sort_custom(func(a, b): return a[0] < b[0])
		var to_promote : Array[int] = []
		for k in range(mini(free_slots, candidates.size())):
			to_promote.append(candidates[k][1])
		to_promote.sort()
		to_promote.reverse()   # remove from highest index first -- swap-remove safe
		for idx in to_promote:
			_promote_z2_to_z1(idx)

	# Remaining out-of-range Z2 entries demote to Z3 (unchanged behaviour)
	var i := _z2_count - 1
	while i >= 0:
		var pos := _z2_pos[i]
		if cam.distance_squared_to(pos) >= z2r2:
			_demote_z2_to_z3(i)
		i -= 1


# ── Promote a pool zombie to Z1 ──────────────────────────────
func _promote_to_z1(pos: Vector3, team_id: int) -> CharacterBody3D:
	while not _pool.is_empty() and not is_instance_valid(_pool.back()): _pool.pop_back()
	if _pool.is_empty() or _z1_active.size() >= ZONE1_MAX:
		_add_to_z2(pos, team_id, 0); return null
	var z := _pool.pop_back() as CharacterBody3D
	if not is_instance_valid(z): _add_to_z2(pos, team_id, 0); return null
	z.process_mode = Node.PROCESS_MODE_INHERIT
	z.visible = true
	if z.has_method("reset"):
		z.call("reset", pos)
		if "_horde_mgr" in z: z.set("_horde_mgr", self)
	else:
		z.global_position = pos; z.set_physics_process(true)
	if "team_id" in z: z.set("team_id", team_id)
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == team_id:
			if "friendly_base" in z: z.set("friendly_base", b)
		else:
			if "enemy_base" in z: z.set("enemy_base", b)
	_z1_active.append(z)
	_apply_lod_tint(z, 0)   # clear any leftover tint from the pool
	return z


func return_to_pool(z: CharacterBody3D) -> void: _return_to_pool(z)

func _return_to_pool(z: CharacterBody3D) -> void:
	var idx := _z1_active.find(z)
	if idx != -1:
		_z1_active[idx] = _z1_active[_z1_active.size() - 1]
		_z1_active.resize(_z1_active.size() - 1)
	if z.has_method("push_players"): z.push_players([])
	if z.has_method("push_neighbors"): z.push_neighbors([])
	_pool.append(z)
	z.visible = false
	z.process_mode = Node.PROCESS_MODE_DISABLED
	z.set_physics_process(false)
	z.set_process(false)


## Register a zombie that was spawned externally (Egg, LaneSpawner, etc.)
## into the Z1 tracking list so it gets LOD management, neighbor push,
## REAL BUG FIX (2026-07-24, severe): "drastically reduce lag" -- register_z1
## had NO cap check at all, unlike every other Zone-1 spawn path in this file
## (see the ZONE1_MAX checks at the Director/pool call sites above). Hive
## clusters and eggs (HiveCluster.gd's patrol guards + hive-heart extra
## zombies, Egg.gd's hatch/retaliation waves) call this directly -- with up
## to 8 clusters each capable of waves up to 18 units, this let real
## full-CharacterBody3D zombie counts (55,686 verts each, confirmed earlier)
## blow straight past the carefully-measured 40-zombie cap, completely
## undoing that fix. can_register_z1() lets every spawner check the cap
## BEFORE instantiating -- refusing registration after the node already
## exists would leave an orphaned, unmanaged full-cost zombie in the tree,
## which is worse than the original bug.
func can_register_z1() -> bool:
	return _z1_active.size() < ZONE1_MAX

## and player push — exactly as if it came from the pool.
## The zombie is NOT returned to the pool on death (no _horde_mgr set);
## dead refs are swept by _sweep_dead_z1 on the next cleanup tick.
func register_z1(z: CharacterBody3D) -> void:
	if not is_instance_valid(z): return
	if _z1_active.has(z): return   # already registered
	_z1_active.append(z)
	# Push current bases so the zombie doesn't need to scan "bases" group itself
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		var tid : int = int(b.get("team_id"))
		var ztid : int = int(z.get("team_id") if "team_id" in z else -1)
		if tid == ztid:
			if "friendly_base" in z and not is_instance_valid(z.get("friendly_base")):
				z.set("friendly_base", b)
		else:
			if "enemy_base" in z and not is_instance_valid(z.get("enemy_base")):
				z.set("enemy_base", b)


## Alias used by LaneSpawner (legacy call site: zhm.register_zombie(creep, team))
func register_zombie(z: Node, _team_id: int) -> void:
	if z is CharacterBody3D: register_z1(z as CharacterBody3D)


func _add_to_z2(pos: Vector3, team_id: int, lane_id: int) -> void:
	if _z2_count >= MULTIMESH_MAX: _add_to_z3(pos, team_id, lane_id); return
	_z2_pos[_z2_count]  = pos; _z2_vel[_z2_count]  = Vector2.ZERO
	_z2_team[_z2_count] = team_id; _z2_lane[_z2_count] = lane_id
	_z2_count += 1


func _add_to_z3(pos: Vector3, team_id: int, lane_id: int) -> void:
	if _z3_count >= _z3_pos.size():
		_z3_pos.resize(_z3_pos.size() + 2048)
		_z3_team.resize(_z3_team.size() + 2048)
		_z3_lane.resize(_z3_lane.size() + 2048)
	_z3_pos[_z3_count] = pos; _z3_team[_z3_count] = team_id; _z3_lane[_z3_count] = lane_id
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
	_z2_pos[idx]=_z2_pos[_z2_count]; _z2_vel[idx]=_z2_vel[_z2_count]
	_z2_team[idx]=_z2_team[_z2_count]; _z2_lane[idx]=_z2_lane[_z2_count]

func _swap_remove_z3(idx: int) -> void:
	_z3_count -= 1
	_z3_pos[idx]=_z3_pos[_z3_count]
	_z3_team[idx]=_z3_team[_z3_count]; _z3_lane[idx]=_z3_lane[_z3_count]


# ============================================================
# SPAWN API
# ============================================================
func spawn_horde(count: int, area: AABB, team_id: int = 1, lane_id: int = 0) -> void:
	for _i in count:
		var pos := Vector3(
			area.position.x + randf() * area.size.x,
			area.position.y,
			area.position.z + randf() * area.size.z)
		_place_unit(pos, team_id, lane_id)
	if _z2_count > 0: _upload_multimesh()
	print("[ZHM] spawn_horde | z1=%d z2=%d z3=%d" % [_z1_active.size(), _z2_count, _z3_count])


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
	if not is_instance_valid(_camera): _camera = get_viewport().get_camera_3d()
	return _camera.global_position if is_instance_valid(_camera) else Vector3.ZERO


func _make_zombie_mesh() -> ArrayMesh:
	var st  := SurfaceTool.new()
	var arr := ArrayMesh.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := 0.22; var segs := 8
	for ring in 2:
		var y0 := float(ring); var y1 := float(ring + 1)
		for seg in segs:
			var a0 := TAU * float(seg) / float(segs)
			var a1 := TAU * float(seg+1) / float(segs)
			var v00 := Vector3(cos(a0)*r, y0, sin(a0)*r)
			var v10 := Vector3(cos(a1)*r, y0, sin(a1)*r)
			var v01 := Vector3(cos(a0)*r, y1, sin(a0)*r)
			var v11 := Vector3(cos(a1)*r, y1, sin(a1)*r)
			st.add_vertex(v00); st.add_vertex(v11); st.add_vertex(v01)
			st.add_vertex(v00); st.add_vertex(v10); st.add_vertex(v11)
	st.commit(arr); return arr


# ============================================================
# LOD TINT HELPERS
# LOD 0 = natural (no tint), LOD 1 = faint blue-grey (dormant),
# LOD 2 = darker desaturated blue (cheap-march).
# CharacterBody3D has no "modulate" -- that's a CanvasItem/2D-only property
# and assigning it is a real runtime error (confirmed live: "Invalid
# assignment of property or key 'modulate' ... CharacterBody3D"). The
# correct 3D equivalent is per-mesh material_override with a tinted
# albedo_color, which multiplies with (not replaces) the original texture,
# so skin detail isn't lost the way a flat solid-color override would.
func _apply_lod_tint(z: CharacterBody3D, lod: int) -> void:
	var tint := Color(1.0, 1.0, 1.0)
	match lod:
		1: tint = Color(0.65, 0.70, 0.80)
		2: tint = Color(0.45, 0.50, 0.65)
	for child in z.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if not is_instance_valid(mi):
			continue
		if lod == 0:
			mi.material_override = null
			continue
		var base := mi.get_active_material(0)
		if base is StandardMaterial3D:
			var dup := (base as StandardMaterial3D).duplicate() as StandardMaterial3D
			dup.albedo_color = tint
			mi.material_override = dup


# ============================================================
# PUBLIC COUNTERS / DIRECTOR API
# ============================================================
func z1_count()    -> int: return _z1_active.size()
func z2_count()    -> int: return _z2_count
func z3_count()    -> int: return _z3_count
func total_count() -> int: return _z1_active.size() + _z2_count + _z3_count

func get_director_intensity() -> float: return _director_intensity
func set_director_difficulty(d: float) -> void: director_difficulty = clampf(d, 0.1, 5.0)
func pause_director(duration: float) -> void:
	_director_paused = true; _director_pause_t = duration


func get_crowd_positions(max_count: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	var z2b    := max_count * 2 / 3
	var z3b    := max_count - z2b
	if _z2_count > 0:
		var step := maxi(1, _z2_count / maxi(z2b, 1))
		var i := 0
		while i < _z2_count and result.size() < z2b:
			result.append(_z2_pos[i]); i += step
	if _z3_count > 0 and z3b > 0:
		var step := maxi(1, _z3_count / maxi(z3b, 1))
		var i := 0
		while i < _z3_count and result.size() < max_count:
			result.append(_z3_pos[i]); i += step
	return result


func get_z1_neighbors(pos: Vector3, radius: float) -> Array:
	var result : Array = []
	var cr := int(ceil(radius / GRID_CELL))
	var bc := Vector2i(int(pos.x / GRID_CELL), int(pos.z / GRID_CELL))
	var r2 := radius * radius
	for dx in range(-cr, cr+1):
		for dz in range(-cr, cr+1):
			var key := Vector2i(bc.x+dx, bc.y+dz)
			if not _grid.has(key): continue
			for z in _grid[key]:
				if is_instance_valid(z) and pos.distance_squared_to(z.global_position) <= r2:
					result.append(z)
	return result


func get_z1_active_by_team(tid: int) -> Array:
	var result : Array = []
	for z in _z1_active:
		if is_instance_valid(z) and "team_id" in z and int(z.get("team_id")) == tid:
			result.append(z)
	return result


# ── SELECTION ────────────────────────────────────────────────
func select(units: Array) -> void:
	_selected.clear()
	for u in units:
		if is_instance_valid(u): _selected.append(u)

func get_selected() -> Array:
	_selected = _selected.filter(func(u): return is_instance_valid(u))
	return _selected

func clear_selection() -> void: _selected.clear()
