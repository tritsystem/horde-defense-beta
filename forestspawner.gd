# ============================================================
# WorldGenerator.gd
# STRICT-TYPED GODOT 4.6 VERSION
# ============================================================
# CHANGES FROM ORIGINAL:
#   • Bush group — dedicated @export_group("Bushes") with its
#     own scenes array, count, scale range, and clustering
#     controls. Fully visible and tunable in the Inspector.
#
#   • Foliage density system — bushes between bases use a
#     three-layer approach:
#       1. BORDER BAND  — dense bush wall along each base
#          clear-radius edge (looks like overgrowth pressing in)
#       2. LANE FLANKS  — two thick corridors of bushes running
#          parallel to the centre lane on both sides, so the
#          lane feels like it cuts through heavy jungle
#       3. FILL SCATTER — high-count random fill covers the
#          entire between-bases region for depth and variety
#
#   • Cluster spawning — bushes spawn in tight clusters of
#     2-6 instances with a small random scatter radius, not
#     as evenly-distributed singles, so they look natural.
#
#   • Lane-flank exclusion zone widened slightly so clusters
#     don't bleed into the actual lane walkway.
#
#   • All existing systems (trees, grass, rocks) unchanged.
# ============================================================
extends Node3D
class_name WorldGenerator


# ============================================================
# WORLD
# ============================================================
@export_group("World")

@export var area_size         : float = 200.0
@export var ground_mask       : int   = 1


# ============================================================
# BASE PROTECTION
# ============================================================
@export_group("Protection")

@export var base_clear_radius  : float = 90.0
@export var spawn_clear_radius : float = 45.0
@export var lane_clear_width   : float = 18.0


# ============================================================
# TREES
# ============================================================
@export_group("Trees")

@export var tree_scenes         : Array[PackedScene] = []
@export var tree_count          : int   = 80
@export var tree_scale_min      : float = 0.8
@export var tree_scale_max      : float = 2.2
@export var tree_noise_threshold: float = -0.1


# ============================================================
# GRASS
# ============================================================
@export_group("Grass")

@export var grass_scenes    : Array[PackedScene] = []
@export var grass_count     : int   = 60
@export var grass_scale_min : float = 0.8
@export var grass_scale_max : float = 1.4


# ============================================================
# ROCKS
# ============================================================
@export_group("Rocks")

@export var rock_scenes    : Array[PackedScene] = []
@export var rock_count     : int   = 30
@export var rock_scale_min : float = 0.1
@export var rock_scale_max : float = 0.3


# ============================================================
# BUSHES
# ============================================================
@export_group("Bushes")

## Drag any number of bush / shrub PackedScenes here.
## The generator picks randomly from this list for every
## instance, so mixing 3-4 variety meshes looks natural.
@export var bush_scenes : Array[PackedScene] = []

## Total bush instances spawned in the scatter fill pass.
## The border-band and lane-flank passes add on top of this.
## Recommended: 400-800 for a dense jungle feel.
@export var bush_fill_count : int = 500

## Additional instances spawned along the border band
## (the ring where the base clear-radius meets the open field).
@export var bush_border_count : int = 200

## Additional instances spawned in the two lane-flank corridors
## (the thick strips of undergrowth flanking the centre lane).
@export var bush_lane_flank_count : int = 300

## Scale range for bush instances.
@export var bush_scale_min : float = 0.4
@export var bush_scale_max : float = 1.6

## How many bushes spawn per cluster (min).
@export var bush_cluster_min : int = 2
## How many bushes spawn per cluster (max).
@export var bush_cluster_max : int = 6

## Radius within which cluster members scatter from the
## cluster seed point (world units).
@export var bush_cluster_radius : float = 2.8

## Width of the lane-flank corridor on each side of the lane.
## Measured from lane edge outward. Keep above lane_clear_width.
@export var bush_flank_width : float = 22.0

## How far outside each base's clear radius the border band
## extends. Bushes press right up against the clear edge.
@export var bush_border_band : float = 12.0


# ============================================================
# PERFORMANCE
# ============================================================
@export_group("Performance")

@export var frame_budget_ms : float = 6.0
@export var grow_time       : float = 0.35


# ============================================================
# INTERNAL
# ============================================================
var _noise : FastNoiseLite
var _space : PhysicsDirectSpaceState3D

const RAY_FROM_Y : float =  500.0
const RAY_TO_Y   : float = -300.0
const NO_HIT     : float = -99999.0


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	randomize()
	_setup_noise()

	for _i : int in range(6):
		await get_tree().physics_frame

	_space = get_world_3d().direct_space_state
	if _space == null:
		push_error("[WorldGen] Missing physics space")
		return

	print("[WorldGen] Generating world...")

	# Standard objects
	await _spawn_objects(tree_scenes,  tree_count,  tree_scale_min,  tree_scale_max,  true)
	await _spawn_objects(grass_scenes, grass_count, grass_scale_min, grass_scale_max, false)
	await _spawn_objects(rock_scenes,  rock_count,  rock_scale_min,  rock_scale_max,  false)

	# Bush system — three layered passes
	if not bush_scenes.is_empty():
		print("[WorldGen] Spawning bush layers...")
		await _spawn_bushes_fill()
		await _spawn_bushes_border()
		await _spawn_bushes_lane_flanks()

	print("[WorldGen] Generation complete")


# ============================================================
# NOISE
# ============================================================
func _setup_noise() -> void:
	_noise            = FastNoiseLite.new()
	_noise.seed       = randi()
	_noise.frequency  = 0.03
	_noise.fractal_octaves = 3


# ============================================================
# BUSH PASS 1 — SCATTER FILL
# Blankets the entire between-bases region with clustered
# bushes. Each "seed" spawns bush_cluster_min..max instances
# scattered within bush_cluster_radius, so they look like
# natural clumps rather than evenly spaced singles.
# ============================================================
func _spawn_bushes_fill() -> void:
	var budget_us  : float = frame_budget_ms * 1000.0
	var frame_start: int   = Time.get_ticks_usec()
	var spawned    : int   = 0
	var attempts   : int   = 0
	var max_att    : int   = bush_fill_count * 20

	while spawned < bush_fill_count and attempts < max_att:
		attempts += 1

		var x : float = randf_range(-area_size, area_size)
		var z : float = randf_range(-area_size, area_size)

		# Only fill the between-bases strip — skip positions
		# that are deep inside either base's protected zone
		if not _is_between_bases(x, z):
			continue
		if _is_in_base_clear(x, z):
			continue
		if _is_in_lane(x, z):
			continue

		var cluster_n : int = randi_range(bush_cluster_min, bush_cluster_max)
		for _c in cluster_n:
			var cx : float = x + randf_range(-bush_cluster_radius, bush_cluster_radius)
			var cz : float = z + randf_range(-bush_cluster_radius, bush_cluster_radius)
			if _is_in_base_clear(cx, cz) or _is_in_lane(cx, cz):
				continue
			var y : float = _get_ground_y(cx, cz)
			if y == NO_HIT:
				continue
			_spawn_patch(bush_scenes, Vector3(cx, y, cz),
				randf_range(bush_scale_min, bush_scale_max))
			spawned += 1

		if Time.get_ticks_usec() - frame_start >= budget_us:
			await get_tree().process_frame
			frame_start = Time.get_ticks_usec()

	print("[WorldGen] Bush fill: %d instances" % spawned)


# ============================================================
# BUSH PASS 2 — BORDER BAND
# Packs bushes into a ring just outside each base's
# clear radius — the overgrowth-pressing-in look.
# ============================================================
func _spawn_bushes_border() -> void:
	var budget_us  : float = frame_budget_ms * 1000.0
	var frame_start: int   = Time.get_ticks_usec()
	var spawned    : int   = 0
	var attempts   : int   = 0
	var max_att    : int   = bush_border_count * 30

	var bases : Array[Node3D] = _get_base_nodes()
	if bases.is_empty():
		return

	# Distribute border budget evenly across bases
	var per_base : int = int(ceil(float(bush_border_count) / float(bases.size())))

	for base_node : Node3D in bases:
		var bc    : Vector2 = Vector2(base_node.global_position.x,
									  base_node.global_position.z)
		var inner : float   = base_clear_radius
		var outer : float   = base_clear_radius + bush_border_band
		var base_spawned : int = 0

		while base_spawned < per_base and attempts < max_att:
			attempts += 1
			# Sample uniformly in annulus: r = sqrt(lerp(inner², outer², rand))
			var r   : float = sqrt(randf_range(inner * inner, outer * outer))
			var ang : float = randf() * TAU
			var x   : float = bc.x + r * cos(ang)
			var z   : float = bc.y + r * sin(ang)

			if absf(x) > area_size or absf(z) > area_size:
				continue
			if _is_in_lane(x, z):
				continue

			var cluster_n : int = randi_range(bush_cluster_min, bush_cluster_max)
			for _c in cluster_n:
				var cx : float = x + randf_range(-bush_cluster_radius, bush_cluster_radius)
				var cz : float = z + randf_range(-bush_cluster_radius, bush_cluster_radius)
				if _is_in_base_clear(cx, cz) or _is_in_lane(cx, cz):
					continue
				var y : float = _get_ground_y(cx, cz)
				if y == NO_HIT:
					continue
				_spawn_patch(bush_scenes, Vector3(cx, y, cz),
					randf_range(bush_scale_min, bush_scale_max))
				spawned      += 1
				base_spawned += 1

			if Time.get_ticks_usec() - frame_start >= budget_us:
				await get_tree().process_frame
				frame_start = Time.get_ticks_usec()

	print("[WorldGen] Bush border: %d instances" % spawned)


# ============================================================
# BUSH PASS 3 — LANE FLANKS
# Two thick corridors of undergrowth run parallel to the
# centre lane, pressing in from both sides. The lane itself
# stays clear; everything outside lane_clear_width up to
# lane_clear_width + bush_flank_width is saturated.
# ============================================================
func _spawn_bushes_lane_flanks() -> void:
	var budget_us  : float = frame_budget_ms * 1000.0
	var frame_start: int   = Time.get_ticks_usec()
	var spawned    : int   = 0
	var attempts   : int   = 0
	var max_att    : int   = bush_lane_flank_count * 30

	var bases : Array[Node3D] = _get_base_nodes()
	if bases.size() < 2:
		return

	var a : Vector2 = Vector2(bases[0].global_position.x, bases[0].global_position.z)
	var b : Vector2 = Vector2(bases[1].global_position.x, bases[1].global_position.z)
	var lane_len : float = a.distance_to(b)

	while spawned < bush_lane_flank_count and attempts < max_att:
		attempts += 1

		# Pick a random point along the lane (parametric t in 0..1)
		var t       : float   = randf()
		var on_lane : Vector2 = a.lerp(b, t)

		# Pick a flank side: left or right, at distance in the flank band
		var side    : float   = 1.0 if randf() > 0.5 else -1.0
		var dist    : float   = randf_range(
			lane_clear_width + 1.0,
			lane_clear_width + bush_flank_width)

		# Perpendicular to lane direction
		var lane_dir  : Vector2 = (b - a).normalized()
		var perp      : Vector2 = Vector2(-lane_dir.y, lane_dir.x) * side

		var px : float = on_lane.x + perp.x * dist
		var pz : float = on_lane.y + perp.y * dist

		if absf(px) > area_size or absf(pz) > area_size:
			continue
		if _is_in_base_clear(px, pz):
			continue

		var cluster_n : int = randi_range(bush_cluster_min, bush_cluster_max)
		for _c in cluster_n:
			var cx : float = px + randf_range(-bush_cluster_radius, bush_cluster_radius)
			var cz : float = pz + randf_range(-bush_cluster_radius, bush_cluster_radius)
			if _is_in_base_clear(cx, cz) or _is_in_lane(cx, cz):
				continue
			var y : float = _get_ground_y(cx, cz)
			if y == NO_HIT:
				continue
			_spawn_patch(bush_scenes, Vector3(cx, y, cz),
				randf_range(bush_scale_min, bush_scale_max))
			spawned += 1

		if Time.get_ticks_usec() - frame_start >= budget_us:
			await get_tree().process_frame
			frame_start = Time.get_ticks_usec()

	print("[WorldGen] Bush lane flanks: %d instances (lane length %.1fm)" % [
		spawned, lane_len])


# ============================================================
# SPAWN OBJECTS (original — trees / grass / rocks)
# ============================================================
func _spawn_objects(
	scenes    : Array[PackedScene],
	count     : int,
	scale_min : float,
	scale_max : float,
	use_noise : bool
) -> void:
	if scenes.is_empty():
		return

	var spawned     : int   = 0
	var attempts    : int   = 0
	var max_attempts: int   = count * 40
	var budget_us   : float = frame_budget_ms * 1000.0
	var frame_start : int   = Time.get_ticks_usec()

	while spawned < count and attempts < max_attempts:
		attempts += 1

		var x : float = randf_range(-area_size, area_size)
		var z : float = randf_range(-area_size, area_size)

		if _is_blocked_position(x, z):
			continue

		if use_noise:
			var n : float = _noise.get_noise_2d(x, z)
			if n < tree_noise_threshold:
				continue

		var y : float = _get_ground_y(x, z)
		if y == NO_HIT:
			continue

		_spawn_patch(scenes, Vector3(x, y, z), randf_range(scale_min, scale_max))
		spawned += 1

		if Time.get_ticks_usec() - frame_start >= budget_us:
			await get_tree().process_frame
			frame_start = Time.get_ticks_usec()

	print("[WorldGen] Spawned %d/%d" % [spawned, count])


# ============================================================
# POSITION TESTS
# ============================================================

## Full blocked check used by the original tree/grass/rock system.
func _is_blocked_position(x : float, z : float) -> bool:
	var p : Vector2 = Vector2(x, z)

	for b : Node in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not (b is Node3D):
			continue
		var bp : Vector2 = Vector2(
			(b as Node3D).global_position.x,
			(b as Node3D).global_position.z)
		if p.distance_to(bp) < base_clear_radius:
			return true

	for sp : Node in get_tree().get_nodes_in_group("spawn_points"):
		if not is_instance_valid(sp) or not (sp is Node3D):
			continue
		var spp : Vector2 = Vector2(
			(sp as Node3D).global_position.x,
			(sp as Node3D).global_position.z)
		if p.distance_to(spp) < spawn_clear_radius:
			return true

	var bases : Array = get_tree().get_nodes_in_group("bases")
	if bases.size() >= 2:
		var b1 : Node3D = bases[0] as Node3D
		var b2 : Node3D = bases[1] as Node3D
		if is_instance_valid(b1) and is_instance_valid(b2):
			var a   : Vector2 = Vector2(b1.global_position.x, b1.global_position.z)
			var bv  : Vector2 = Vector2(b2.global_position.x, b2.global_position.z)
			var ab  : Vector2 = bv - a
			var len_sq : float = ab.length_squared()
			if len_sq > 0.001:
				var t    : float  = clampf(((p - a).dot(ab)) / len_sq, 0.0, 1.0)
				var proj : Vector2 = a + (ab * t)
				if p.distance_to(proj) < lane_clear_width:
					return true

	return false


## True when the position is within any base's protected radius.
func _is_in_base_clear(x : float, z : float) -> bool:
	var p : Vector2 = Vector2(x, z)
	for b : Node in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not (b is Node3D):
			continue
		var bp : Vector2 = Vector2(
			(b as Node3D).global_position.x,
			(b as Node3D).global_position.z)
		if p.distance_to(bp) < base_clear_radius:
			return true
	return false


## True when the position is within the centre lane walkway.
func _is_in_lane(x : float, z : float) -> bool:
	var p     : Vector2 = Vector2(x, z)
	var bases : Array   = get_tree().get_nodes_in_group("bases")
	if bases.size() < 2:
		return false
	var b1 : Node3D = bases[0] as Node3D
	var b2 : Node3D = bases[1] as Node3D
	if not is_instance_valid(b1) or not is_instance_valid(b2):
		return false
	var a  : Vector2 = Vector2(b1.global_position.x, b1.global_position.z)
	var bv : Vector2 = Vector2(b2.global_position.x, b2.global_position.z)
	var ab : Vector2 = bv - a
	var len_sq : float = ab.length_squared()
	if len_sq < 0.001:
		return false
	var t    : float   = clampf(((p - a).dot(ab)) / len_sq, 0.0, 1.0)
	var proj : Vector2 = a + (ab * t)
	return p.distance_to(proj) < lane_clear_width


## True when the position is roughly between the two bases
## (within the bounding box of the lane with generous padding).
func _is_between_bases(x : float, z : float) -> bool:
	var bases : Array = get_tree().get_nodes_in_group("bases")
	if bases.size() < 2:
		# No bases yet — allow everywhere
		return true
	var b1 : Node3D = bases[0] as Node3D
	var b2 : Node3D = bases[1] as Node3D
	if not is_instance_valid(b1) or not is_instance_valid(b2):
		return true
	var min_x : float = minf(b1.global_position.x, b2.global_position.x) - 20.0
	var max_x : float = maxf(b1.global_position.x, b2.global_position.x) + 20.0
	var min_z : float = minf(b1.global_position.z, b2.global_position.z) - 20.0
	var max_z : float = maxf(b1.global_position.z, b2.global_position.z) + 20.0
	return x >= min_x and x <= max_x and z >= min_z and z <= max_z


# ============================================================
# HELPERS
# ============================================================

func _get_base_nodes() -> Array[Node3D]:
	var out : Array[Node3D] = []
	for b : Node in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and b is Node3D:
			out.append(b as Node3D)
	return out


# ============================================================
# GROUND RAYCAST
# ============================================================
func _get_ground_y(x : float, z : float) -> float:
	var from  : Vector3 = Vector3(x, RAY_FROM_Y, z)
	var to    : Vector3 = Vector3(x, RAY_TO_Y,   z)
	var query : PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = ground_mask
	var hit : Dictionary = _space.intersect_ray(query)
	if hit.is_empty():
		return NO_HIT
	var normal : Vector3 = hit["normal"]
	if normal.y < 0.2:
		return NO_HIT
	return (hit["position"] as Vector3).y


# ============================================================
# SPAWN PATCH
# ============================================================
func _spawn_patch(
	scenes       : Array[PackedScene],
	pos          : Vector3,
	scale_amount : float
) -> void:
	var packed : PackedScene = scenes.pick_random() as PackedScene
	if packed == null:
		return
	var inst : Node = packed.instantiate()
	if not (inst is Node3D):
		inst.queue_free()
		return
	var node : Node3D = inst as Node3D
	node.position  = pos
	node.rotation.y = randf() * TAU
	node.scale     = Vector3.ZERO
	add_child(node)
	node.add_to_group("generated_world")
	var tw : Tween = create_tween()
	tw.set_trans(Tween.TRANS_ELASTIC)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector3.ONE * scale_amount, grow_time)


# ============================================================
# CLEAR GENERATED
# ============================================================
func clear_generated() -> void:
	for child : Node in get_children():
		if child.is_in_group("generated_world"):
			child.queue_free()
