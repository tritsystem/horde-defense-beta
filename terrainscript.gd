# ============================================================
# ValleyTerrain3D.gd — Attach to any Node3D (no longer needs to be a
# Terrain3D child at all -- see REWRITE note below).
#
# REWRITE (2026-07-21): the previous version drove the Terrain3D addon
# directly (terrain.data.import_images/remove_region/etc). That API caused
# three separate real bugs this session (remove_region needing a Region
# object not a Vector2i, import_images needing an Array not a Dictionary,
# and a leftover empty shader_override on the Terrain3D material making
# everything render flat white) -- each only surfaced through live testing,
# no docs available for this addon version.
#
# Switched to the exact technique already proven working in the Tribe
# project's terrain_gen.gd: build a real SurfaceTool mesh AND a
# HeightMapShape3D collider from the SAME heights array, so visual and
# collision can never drift apart, plus real per-vertex color tinting
# instead of depending on Terrain3D's texture-splat/control-map system
# (which is what was making the ground "just white"). This script now
# creates its own MeshInstance3D + StaticBody3D children and no longer
# touches the Terrain3D node/addon at all for the generated ground.
# ============================================================
@tool
extends Node3D

# ── Map settings ─────────────────────────────────────────────
@export_group("Map Size")
# Mesh resolution (samples per side), NOT a texture size. Capped like
# Tribe's generator so this never builds a multi-million-triangle mesh --
# world_size/6 keeps cells roughly 6m without exploding on a huge map.
@export var world_size      : float = 1024.0 # total world units across

@export_group("Valley Shape")
@export var valley_width    : float = 180.0  # flat floor width in world units
@export var valley_depth    : float = 800.0  # length of valley (base to base)
@export var ridge_height    : float = 55.0   # peak height of ridges
@export var floor_height    : float = 0.0    # valley floor Y
@export var cliff_sharpness : float = 3.5    # how steep the walls are (2-6)

@export_group("Natural Detail")
@export var noise_scale     : float = 0.008  # large terrain features
@export var noise_strength  : float = 8.0    # amplitude of noise
@export var detail_scale    : float = 0.04   # small surface roughness
@export var detail_strength : float = 2.5    # amplitude of roughness

@export_group("Base Clearings")
@export var base_clear_radius : float = 60.0  # flat area around each base
@export var base1_z_world     : float = 180.0 # Z world pos of base 1 (positive)
@export var base2_z_world     : float = -180.0# Z world pos of base 2 (negative)

@export_group("Paths")
@export var center_path_width : float = 22.0
@export var side_path_width   : float = 14.0
@export var path_flatten      : float = 0.85  # how much to flatten paths (0-1)

@export_group("Run")
@export var auto_generate_on_ready : bool = false
@export var generate_button : bool = false :
	set(v):
		if v: generate()

var _res      : int = 160
var _cell     : float = 1.0
var _heights  : PackedFloat32Array = PackedFloat32Array()
var _mesh_inst : MeshInstance3D
var _body      : StaticBody3D

# REAL BUG FIX (2026-07-25): "zombies aren't running to base anymore, big
# invisible wall halfway through the map" -- this whole valley shape was
# hardcoded around a base1_z_world/base2_z_world (Z-axis only) assumption:
# flat floor centered on world X=0, cliffs rising with |wx|, valley end-caps
# rising with |wz|. But the actual "Base"/"Base2" nodes in main.tscn sit at
# roughly (-4.8, 13.3) and (213.7, -18.6) -- separated by ~218 units along X
# and only ~32 along Z, i.e. the real base-to-base lane runs mostly along X,
# almost perpendicular to what this script assumed. Egg/hive nests get
# placed relative to the REAL base positions (HiveNestManager), so most of
# them -- and the whole path back to the player's base -- landed well past
# half_valley (90u) out on the actual cliff slope (~40+ units of real
# elevation by world X~200), which is exactly what a CharacterBody3D reads
# as an unclimbable wall. Fix: derive the valley's own forward/right axes
# from the ACTUAL live base positions instead of assuming they lie on Z, and
# sample in that rotated frame. Falls back to the old Z-axis assumption only
# if no "bases" group nodes exist yet (e.g. editor preview with no bases in
# the scene).
var _valley_center  : Vector2 = Vector2.ZERO
var _valley_forward : Vector2 = Vector2.UP      # world (x,z) as (x,y) here
var _valley_right   : Vector2 = Vector2.RIGHT
var _base1_xz       : Vector2 = Vector2.ZERO
var _base2_xz       : Vector2 = Vector2.ZERO
var _has_real_bases : bool    = false


func _ready() -> void:
	if auto_generate_on_ready and not Engine.is_editor_hint():
		call_deferred("generate")


func _compute_valley_axes() -> void:
	var bases := get_tree().get_nodes_in_group("bases")
	var b1 : Node3D = null
	var b2 : Node3D = null
	for b in bases:
		if not is_instance_valid(b) or not (b is Node3D): continue
		if b1 == null: b1 = b as Node3D
		elif b2 == null: b2 = b as Node3D
	if is_instance_valid(b1) and is_instance_valid(b2):
		_base1_xz = Vector2(b1.global_position.x, b1.global_position.z)
		_base2_xz = Vector2(b2.global_position.x, b2.global_position.z)
		_valley_center = (_base1_xz + _base2_xz) * 0.5
		var dir : Vector2 = _base2_xz - _base1_xz
		if dir.length_squared() > 1.0:
			_valley_forward = dir.normalized()
			_valley_right   = Vector2(-_valley_forward.y, _valley_forward.x)
			_has_real_bases = true
			print("[ValleyTerrain3D] Orienting valley to real bases: %s -> %s" % [str(_base1_xz), str(_base2_xz)])
			return
	# Fallback: no usable base nodes found -- keep the old Z-axis assumption.
	_valley_center  = Vector2.ZERO
	_valley_forward = Vector2.UP
	_valley_right   = Vector2.RIGHT
	_base1_xz       = Vector2(0.0, base1_z_world)
	_base2_xz       = Vector2(0.0, base2_z_world)
	_has_real_bases = false


func generate() -> void:
	if not is_inside_tree():
		push_error("[ValleyTerrain3D] Not inside scene tree yet — wait for scene to load")
		return

	_compute_valley_axes()

	# Same RES-scaling idea as Tribe's terrain_gen.gd: keep cell size roughly
	# constant instead of a fixed sample count blowing up on a big map.
	_res = clampi(int(world_size / 6.0), 96, 320)
	_cell = world_size / float(_res - 1)

	print("[ValleyTerrain3D] Generating valley heightmap %dx%d (cell=%.2fm)..." % [_res, _res, _cell])

	_heights.resize(_res * _res)

	var noise_a := FastNoiseLite.new()
	noise_a.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_a.seed       = 42
	noise_a.frequency  = noise_scale

	var noise_b := FastNoiseLite.new()
	noise_b.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_b.seed       = 137
	noise_b.frequency  = detail_scale

	var half := world_size * 0.5

	for row in _res:
		for col in _res:
			var wx : float = -half + float(col) * _cell
			var wz : float = -half + float(row) * _cell
			_heights[row * _res + col] = _sample_valley(wx, wz, noise_a, noise_b)

	_build_mesh()
	_build_collision()
	# REAL BUG FIX (2026-07-21): forestspawner.gd's _ready() only waits for
	# the "bases" group before raycasting for ground height -- it never
	# waited for terrain generation itself, which also runs via a deferred
	# call. If forestspawner's raycasts ran before this collision body
	# existed, every ground query would silently miss (NO_HIT) and those
	# tree/grass/rock positions would just be skipped -- a quiet forest
	# under-spawn, not a crash. Tagging this group once real ground
	# collision exists lets forestspawner wait on it the same way it
	# already waits on "bases".
	add_to_group("terrain_ready")
	print("[ValleyTerrain3D] Done! %d verts, real collision matches visual mesh." % (_res * _res))


func _sample_valley(wx: float, wz: float, noise_a: FastNoiseLite, noise_b: FastNoiseLite) -> float:
	# Project this world point into the valley's own (across, along) frame,
	# oriented on the REAL base-to-base axis (see _compute_valley_axes) --
	# "across" is perpendicular to the base lane (valley width), "along" runs
	# base-to-base (valley depth), regardless of which world axes that maps to.
	var pos2d  : Vector2 = Vector2(wx, wz) - _valley_center
	var across : float = pos2d.dot(_valley_right)
	var along  : float = pos2d.dot(_valley_forward)

	# ── Valley cross-section ─────────────────────────────────
	var dist_from_center : float = abs(across)
	var half_valley       : float = valley_width * 0.5

	# Smooth step from floor to ridge
	var wall_t : float = clampf((dist_from_center - half_valley) / (world_size * 0.25), 0.0, 1.0)
	wall_t = pow(wall_t, 1.0 / cliff_sharpness)  # sharper = more vertical cliff
	var ridge_h : float = floor_height + ridge_height * wall_t

	# ── Natural noise on ridge tops ──────────────────────────
	var ridge_noise : float = noise_a.get_noise_2d(wx, wz) * noise_strength
	# Only apply noise where we're on the ridge, not the floor
	var noise_blend : float = clampf(wall_t * 1.5, 0.0, 1.0)
	ridge_h += ridge_noise * noise_blend

	# ── Small surface roughness everywhere ───────────────────
	var detail : float = noise_b.get_noise_2d(wx, wz) * detail_strength
	ridge_h += detail

	# ── Base clearings — flatten near each base ───────────────
	# Use the real base positions directly (world XZ), not a re-derived
	# along/across guess -- avoids any rounding mismatch with where the
	# bases actually sit.
	var pos2d_world := Vector2(wx, wz)
	for bpos in [_base1_xz, _base2_xz]:
		var bdist : float = pos2d_world.distance_to(bpos)
		if bdist < base_clear_radius:
			var blend : float = clampf(bdist / base_clear_radius, 0.0, 1.0)
			blend = blend * blend  # ease in
			ridge_h = lerpf(floor_height, ridge_h, blend)

	# ── Paths — flatten three lanes ──────────────────────────
	# Center lane
	var center_t := clampf(1.0 - abs(across) / (center_path_width * 0.5), 0.0, 1.0)
	# Side lanes
	var side_x   : float = valley_width * 0.35
	var side_t_l := clampf(1.0 - abs(across + side_x) / (side_path_width * 0.5), 0.0, 1.0)
	var side_t_r := clampf(1.0 - abs(across - side_x) / (side_path_width * 0.5), 0.0, 1.0)
	var path_t   : float = maxf(center_t, maxf(side_t_l, side_t_r))
	if path_t > 0.0:
		path_t = path_t * path_flatten
		ridge_h = lerpf(ridge_h, floor_height + detail * 0.3, path_t)

	# ── Valley length cap — cliffs beyond the bases (along the real axis) ──
	var half_depth : float = valley_depth * 0.5
	var along_dist : float = abs(along)
	if along_dist > half_depth:
		var end_t : float = clampf((along_dist - half_depth) / 80.0, 0.0, 1.0)
		ridge_h = lerpf(ridge_h, ridge_height * 1.2, end_t * end_t)

	return ridge_h


## Ground height at any world x,z (bilinear between samples). Same API shape
## as Tribe's height_at() so any script that wants to query ground height
## (tree placement, spawn positioning) can use it directly instead of a
## raycast, though the physics body works fine for raycasts too.
func height_at(x: float, z: float) -> float:
	if _heights.is_empty():
		return floor_height
	var half := world_size * 0.5
	var fi := clampf((x + half) / _cell, 0.0, _res - 1.001)
	var fj := clampf((z + half) / _cell, 0.0, _res - 1.001)
	var i := int(fi)
	var j := int(fj)
	var tx := fi - i
	var tz := fj - j
	var h00 := _heights[j * _res + i]
	var h10 := _heights[j * _res + i + 1]
	var h01 := _heights[(j + 1) * _res + i]
	var h11 := _heights[(j + 1) * _res + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _build_mesh() -> void:
	if is_instance_valid(_mesh_inst):
		_mesh_inst.queue_free()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := world_size * 0.5
	for row in range(_res - 1):
		for col in range(_res - 1):
			var x0 := -half + float(col) * _cell
			var z0 := -half + float(row) * _cell
			var x1 := x0 + _cell
			var z1 := z0 + _cell
			var v00 := Vector3(x0, _heights[row * _res + col], z0)
			var v10 := Vector3(x1, _heights[row * _res + col + 1], z0)
			var v01 := Vector3(x0, _heights[(row + 1) * _res + col], z1)
			var v11 := Vector3(x1, _heights[(row + 1) * _res + col + 1], z1)
			for v in [v00, v10, v11, v00, v11, v01]:
				st.set_color(_tint(v.y))
				st.add_vertex(v)
	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	st.set_material(mat)

	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "GeneratedGroundMesh"
	_mesh_inst.mesh = st.commit()
	add_child(_mesh_inst)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_mesh_inst.owner = get_tree().edited_scene_root


## Elevation-tinted so the ground reads as real terrain at a glance (valley
## floor/path green, ridge slopes tan/grey, peaks near-white) -- real vertex
## colors, not a texture-splat pipeline, so there is no "control map" step
## that can silently fail and render flat white.
func _tint(y: float) -> Color:
	var f := clampf(y / maxf(1.0, ridge_height + noise_strength), 0.0, 1.0)
	if f < 0.08:
		return Color(0.30, 0.42, 0.24)         # valley floor / path — green
	elif f < 0.35:
		return Color(0.40, 0.48, 0.28)          # lower slope
	elif f < 0.70:
		return Color(0.50, 0.46, 0.36).lerp(Color(0.55, 0.53, 0.48), (f - 0.35) / 0.35)
	return Color(0.58, 0.57, 0.55).lerp(Color(0.85, 0.85, 0.83), (f - 0.70) / 0.30)


func _build_collision() -> void:
	if is_instance_valid(_body):
		_body.queue_free()

	# Same technique as Tribe: HeightMapShape3D built from the identical
	# _heights array used for the mesh, so what you see is exactly what you
	# stand on -- no drift between visual and collision.
	var shape := HeightMapShape3D.new()
	shape.map_width = _res
	shape.map_depth = _res
	shape.map_data  = _heights

	_body = StaticBody3D.new()
	_body.name = "GeneratedGroundCollision"
	_body.collision_layer = 3
	_body.collision_mask  = 3
	var col := CollisionShape3D.new()
	col.shape = shape
	_body.add_child(col)
	# HeightMapShape3D is centred on the origin in grid units -- scale to
	# world cells so it lines up with the mesh built from the same samples.
	_body.scale = Vector3(_cell, 1.0, _cell)
	add_child(_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_body.owner = get_tree().edited_scene_root
		col.owner = get_tree().edited_scene_root


# ============================================================
# RUNTIME TERRAFORMING (2026-08-24 -- ported from Tribe's terrain_gen.gd
# ::_edit_disc/flatten_area/raise_area). This script already uses the
# same technique Tribe's does (raw _heights array -> mesh + collision, see
# the REWRITE note at the top of this file) -- a much more direct, faithful
# port than going through any addon API: same array, same disc-shaped
# smoothstep-falloff edit shape, just mutates _heights in place by grid
# index and rebuilds mesh+collision once after (matching generate()'s own
# existing rebuild calls, not a new mechanism).
# ============================================================

## Flattens a disc of terrain toward target_height (world Y). strength=1.0
## fully flattens at the center, falling off smoothly (no change) at radius.
func flatten_area(center_x: float, center_z: float, radius: float, target_height: float, strength: float = 1.0) -> void:
	_edit_disc(center_x, center_z, radius, func(h: float, falloff: float) -> float:
		return lerpf(h, target_height, falloff * strength))


## Raises (delta > 0) or lowers (delta < 0) a disc of terrain by up to
## delta at the center, falling off smoothly (no change) at radius.
func raise_area(center_x: float, center_z: float, radius: float, delta: float, strength: float = 1.0) -> void:
	_edit_disc(center_x, center_z, radius, func(h: float, falloff: float) -> float:
		return h + delta * falloff * strength)


## Shared disc-edit driver: iterates only the grid cells whose bounding box
## overlaps the disc (not the whole heightmap), computes a smoothstep
## falloff per cell (1.0 at center, 0.0 at radius -- same shape as Tribe's
## _edit_disc), applies edit_fn(current_height, falloff), then rebuilds
## mesh+collision once at the end (a discrete per-tool-use edit, not a
## per-frame stream, so a single full rebuild is cheap enough -- Tribe's
## own 20/sec throttle exists for continuous drag-edits, which this
## key-triggered tool doesn't do).
func _edit_disc(center_x: float, center_z: float, radius: float, edit_fn: Callable) -> void:
	if _heights.is_empty():
		push_warning("[ValleyTerrain3D] _edit_disc: terrain not generated yet")
		return
	var half  : float = world_size * 0.5
	var i_min : int = int(clampf((center_x - radius + half) / _cell, 0, _res - 1))
	var i_max : int = int(clampf((center_x + radius + half) / _cell, 0, _res - 1))
	var j_min : int = int(clampf((center_z - radius + half) / _cell, 0, _res - 1))
	var j_max : int = int(clampf((center_z + radius + half) / _cell, 0, _res - 1))
	var r2      : float = radius * radius
	var touched : bool  = false
	for j in range(j_min, j_max + 1):
		for i in range(i_min, i_max + 1):
			var wx : float = -half + float(i) * _cell
			var wz : float = -half + float(j) * _cell
			var dx : float = wx - center_x
			var dz : float = wz - center_z
			var dist2 : float = dx * dx + dz * dz
			if dist2 > r2: continue
			var dist : float = sqrt(dist2)
			var t       : float = clampf(dist / radius, 0.0, 1.0)
			var falloff : float = 1.0 - smoothstep(0.0, 1.0, t)
			var idx : int = j * _res + i
			_heights[idx] = edit_fn.call(_heights[idx], falloff)
			touched = true
	if touched:
		_build_mesh()
		_build_collision()


# ============================================================
# BIOME CLASSIFICATION (2026-08-24 -- ported from Tribe's terrain_gen.gd
# ::biome_at(): elevation-fraction bucketed into named bands). Reuses the
# EXACT same fraction thresholds _tint() already uses above (0.08/0.35/
# 0.70) rather than an independently-chosen set -- so "biome" boundaries
# line up with what's actually visually distinct on screen (this script
# has no texture-splat/control-map step to paint separately -- ground
# appearance is real per-vertex color, see _tint()'s own header comment).
# ============================================================

enum Biome { VALLEY, LOWER_SLOPE, UPPER_SLOPE, PEAK }

func biome_at(x: float, z: float) -> Biome:
	var h : float = height_at(x, z)
	var f : float = clampf(h / maxf(1.0, ridge_height + noise_strength), 0.0, 1.0)
	if f < 0.08:   return Biome.VALLEY
	elif f < 0.35: return Biome.LOWER_SLOPE
	elif f < 0.70: return Biome.UPPER_SLOPE
	else:          return Biome.PEAK

func biome_name_at(x: float, z: float) -> String:
	match biome_at(x, z):
		Biome.VALLEY:       return "valley"
		Biome.LOWER_SLOPE:  return "lower_slope"
		Biome.UPPER_SLOPE:  return "upper_slope"
		Biome.PEAK:         return "peak"
	return "valley"
