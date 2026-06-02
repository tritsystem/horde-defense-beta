# ============================================================
# ValleyTerrain3D.gd — Attach to your Terrain3D node
# Run from the editor: select node → Script → Run
# Or call generate() from code at runtime
# Creates a Halo Valhalla-style valley with real Terrain3D heightmap
# ============================================================
@tool
extends Node

# ── Map settings ─────────────────────────────────────────────
@export_group("Map Size")
@export var map_size        : int   = 1024   # texture resolution (power of 2)
@export var terrain_scale   : float = 1.0    # Terrain3D vertex_spacing
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


func _ready() -> void:
	if Engine.is_editor_hint(): return  # editor: use Generate Button only
	if auto_generate_on_ready:
		_wait_and_generate()

func _wait_and_generate() -> void:
	var bl := get_node_or_null("/root/BaseLocator")
	if is_instance_valid(bl):
		if not bl.is_ready:
			await bl.bases_ready
		# Use actual base positions from locator
		base1_z_world = bl.base1_pos.z
		base2_z_world = bl.base2_pos.z
		print("[ValleyTerrain3D] Using base positions from BaseLocator: %.0f / %.0f" % [base1_z_world, base2_z_world])
	else:
		# No BaseLocator — wait frames
		for i in 8: await get_tree().process_frame
	generate()


func generate() -> void:
	if not is_inside_tree():
		push_error("[ValleyTerrain3D] Not inside scene tree yet — wait for scene to load")
		return
	var terrain := _get_terrain()
	if not is_instance_valid(terrain):
		push_error("[ValleyTerrain3D] No Terrain3D node found! Attach this script to a Terrain3D node.")
		return

	print("[ValleyTerrain3D] Generating valley heightmap %dx%d..." % [map_size, map_size])

	# Build heightmap as a float array
	var heights := PackedFloat32Array()
	heights.resize(map_size * map_size)

	var noise_a := FastNoiseLite.new()
	noise_a.noise_type     = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_a.seed           = 42
	noise_a.frequency      = noise_scale

	var noise_b := FastNoiseLite.new()
	noise_b.noise_type     = FastNoiseLite.TYPE_PERLIN
	noise_b.seed           = 137
	noise_b.frequency      = detail_scale

	var half := map_size * 0.5

	for row in map_size:
		for col in map_size:
			# Convert pixel to world coords
			var wx : float = (float(col) - half) / float(map_size) * world_size
			var wz : float = (float(row) - half) / float(map_size) * world_size

			var h : float = _sample_valley(wx, wz, noise_a, noise_b)
			heights[row * map_size + col] = h

	# Apply to Terrain3D
	_apply_heightmap(terrain, heights)
	print("[ValleyTerrain3D] Done! Bake navigation mesh after generating.")


func _sample_valley(wx: float, wz: float, noise_a: FastNoiseLite, noise_b: FastNoiseLite) -> float:
	# ── Valley cross-section ─────────────────────────────────
	# Signed distance from valley center line (X axis)
	var dist_from_center : float = abs(wx)
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
	var base1_world := Vector2(0.0, base1_z_world)
	var base2_world := Vector2(0.0, base2_z_world)
	var pos2d       := Vector2(wx, wz)
	for bpos in [base1_world, base2_world]:
		var bdist : float = pos2d.distance_to(bpos)
		if bdist < base_clear_radius:
			var blend : float = clampf(bdist / base_clear_radius, 0.0, 1.0)
			blend = blend * blend  # ease in
			ridge_h = lerpf(floor_height, ridge_h, blend)

	# ── Paths — flatten three lanes ──────────────────────────
	# Center lane
	var center_t := clampf(1.0 - abs(wx) / (center_path_width * 0.5), 0.0, 1.0)
	# Side lanes
	var side_x   : float = valley_width * 0.35
	var side_t_l := clampf(1.0 - abs(wx + side_x) / (side_path_width * 0.5), 0.0, 1.0)
	var side_t_r := clampf(1.0 - abs(wx - side_x) / (side_path_width * 0.5), 0.0, 1.0)
	var path_t   : float = maxf(center_t, maxf(side_t_l, side_t_r))
	if path_t > 0.0:
		path_t = path_t * path_flatten
		ridge_h = lerpf(ridge_h, floor_height + detail * 0.3, path_t)

	# ── Valley length cap — cliffs at north/south ends ────────
	var half_depth : float = valley_depth * 0.5
	var z_dist     : float = abs(wz)
	if z_dist > half_depth:
		var end_t : float = clampf((z_dist - half_depth) / 80.0, 0.0, 1.0)
		ridge_h = lerpf(ridge_h, ridge_height * 1.2, end_t * end_t)

	return ridge_h


func _clear_terrain(terrain: Node) -> void:
	print("[ValleyTerrain3D] Clearing existing terrain data...")
	var storage = null
	if "storage" in terrain: storage = terrain.get("storage")
	if not is_instance_valid(storage):
		storage = terrain.find_child("Terrain3DStorage", true, false)
	if not is_instance_valid(storage):
		push_warning("[ValleyTerrain3D] No storage found to clear")
		return

	# Method 1: Terrain3D 0.9+ — remove all regions
	if storage.has_method("get_region_locations"):
		var locs : Array = storage.get_region_locations()
		for loc in locs:
			if storage.has_method("remove_region"):
				storage.remove_region(loc)
		print("[ValleyTerrain3D] Removed %d regions" % locs.size())
		return

	# Method 2: Older API — clear height maps directly
	if "height_maps" in storage:
		storage.set("height_maps", [])
	if "control_maps" in storage:
		storage.set("control_maps", [])
	if "color_maps" in storage:
		storage.set("color_maps", [])
	if storage.has_method("update"):
		storage.update()
	print("[ValleyTerrain3D] Cleared via property reset")

func _apply_heightmap(terrain: Node, heights: PackedFloat32Array) -> void:
	_clear_terrain(terrain)
	# Terrain3D uses a Storage node
	var storage = null
	if "storage" in terrain:
		storage = terrain.get("storage")
	if not is_instance_valid(storage):
		storage = terrain.find_child("Terrain3DStorage", true, false)
	if not is_instance_valid(storage):
		push_error("[ValleyTerrain3D] Could not find Terrain3DStorage on Terrain3D node")
		return

	# Build Image from float array
	var img := Image.create(map_size, map_size, false, Image.FORMAT_RF)
	for row in map_size:
		for col in map_size:
			var h : float = heights[row * map_size + col]
			# Terrain3D stores height normalized — check your version's expected range
			img.set_pixel(col, row, Color(h / 512.0, 0, 0))  # normalize to 0-1 range

	# Try Terrain3D 0.9+ API
	if storage.has_method("set_height_range"):
		storage.set_height_range(Vector2(floor_height - 5.0, ridge_height + noise_strength + 5.0))

	# Import via heightmap
	if terrain.has_method("import_images"):
		var imgs := { "height": img }
		terrain.import_images(imgs, Vector3.ZERO, 0.0, 512.0)
		print("[ValleyTerrain3D] Imported via terrain.import_images()")
	elif storage.has_method("import_images"):
		storage.import_images({ "height": img }, Vector3.ZERO, 0.0, 512.0)
		print("[ValleyTerrain3D] Imported via storage.import_images()")
	else:
		# Fallback: set height map texture directly
		var tex := ImageTexture.create_from_image(img)
		if "height_maps" in storage:
			storage.set("height_maps", [tex])
		print("[ValleyTerrain3D] Set height texture directly")

	# Force terrain to regenerate collision + mesh
	if terrain.has_method("update"):
		terrain.update()
	elif terrain.has_method("build"):
		terrain.build(terrain.get("clipmap_levels") if "clipmap_levels" in terrain else 7,
					  terrain.get("mesh_vertex_spacing") if "mesh_vertex_spacing" in terrain else 1.0)

	# Rebuild collision
	if terrain.has_method("bake_collision"):
		terrain.bake_collision()


func _get_terrain() -> Node:
	# Primary: parent is Terrain3D (your setup — terrainscript child of Terrain3D2)
	var p := get_parent()
	if is_instance_valid(p) and p.get_class() == "Terrain3D": return p
	# Grandparent
	if is_instance_valid(p):
		var gp := p.get_parent()
		if is_instance_valid(gp) and gp.get_class() == "Terrain3D": return gp
	# Search upward through ancestors
	var node : Node = self
	for _i in 5:
		node = node.get_parent()
		if not is_instance_valid(node): break
		if node.get_class() == "Terrain3D": return node
	# Tree search — only if tree is available
	if is_inside_tree() and is_instance_valid(get_tree()) and is_instance_valid(get_tree().root):
		for n in ["Terrain3D2", "Terrain3D", "Terrain", "terrain"]:
			var found := get_tree().root.find_child(n, true, false)
			if is_instance_valid(found) and found.get_class() == "Terrain3D": return found
	push_error("[ValleyTerrain3D] Cannot find Terrain3D — make sure this script is a child of your Terrain3D node")
	return null
