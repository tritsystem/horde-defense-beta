extends Node
# Headless behavioral test for the terraform/biome port from Tribe
# (2026-08-24, 9th session): flatten_area()/raise_area()/biome_at(),
# ported onto the REAL live terrain generator (terrainscript.gd -- NOT
# ValleyMapGen.gd, which turned out to be dead code from an earlier,
# abandoned Terrain3D-API approach; terrainscript.gd already uses Tribe's
# own raw-heightmap-array technique per its own REWRITE header comment).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_terrain_terraform.tscn --quit-after 300

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TERRAIN TERRAFORMING + BIOME PORT (from Tribe)")
	print("=".repeat(60))

	var script := load("res://terrainscript.gd")
	var terrain := Node3D.new()
	terrain.set_script(script)
	terrain.set("world_size", 400.0)
	add_child(terrain)

	terrain.call("generate")
	_check("terrain_ready group tag was added after generate()", terrain.is_in_group("terrain_ready"))

	# ── flatten_area ──────────────────────────────────────────
	var probe_x := 40.0
	var probe_z := 5.0   # off the flattened base-clearing/path lanes, on real slope
	var before_h : float = terrain.call("height_at", probe_x, probe_z)
	terrain.call("flatten_area", probe_x, probe_z, 10.0, 0.0, 1.0)
	var after_flatten_h : float = terrain.call("height_at", probe_x, probe_z)
	print("  height at (%.0f,%.0f) before=%.3f after flatten(target=0.0)=%.3f" % [probe_x, probe_z, before_h, after_flatten_h])
	_check("flatten_area() actually changed the height", not is_equal_approx(before_h, after_flatten_h))
	_check("flatten_area() moved height toward the real target (0.0)", absf(after_flatten_h) < absf(before_h))

	# ── raise_area ────────────────────────────────────────────
	var probe2_x := -40.0
	var probe2_z := 5.0
	var far_x := -40.0
	var far_z := 60.0   # >10 units away from probe2 -- outside the edit radius
	var before2_h : float = terrain.call("height_at", probe2_x, probe2_z)
	var far_before : float = terrain.call("height_at", far_x, far_z)
	terrain.call("raise_area", probe2_x, probe2_z, 10.0, 8.0, 1.0)
	var after_raise_h : float = terrain.call("height_at", probe2_x, probe2_z)
	var far_after : float = terrain.call("height_at", far_x, far_z)
	print("  height at (%.0f,%.0f) before=%.3f after raise(delta=+8)=%.3f" % [probe2_x, probe2_z, before2_h, after_raise_h])
	_check("raise_area() actually raised the height", after_raise_h > before2_h + 0.5)
	print("  height at (%.0f,%.0f) [outside radius] before=%.3f after=%.3f" % [far_x, far_z, far_before, far_after])
	_check("raise_area() did not affect terrain outside its radius (falloff actually bounded)",
		is_equal_approx(far_before, far_after))

	# ── biome_at / biome_name_at ─────────────────────────────
	var valley_biome : String = terrain.call("biome_name_at", 0.0, 0.0)   # valley floor, center
	print("  biome at valley floor (0,0): %s" % valley_biome)
	_check("valley floor classifies as 'valley'", valley_biome == "valley")

	# Force a point to a known high elevation via raise_area, then confirm
	# biome_at reads the actual current (post-edit) height, not a stale value.
	var peak_x := 100.0
	var peak_z := 5.0
	terrain.call("raise_area", peak_x, peak_z, 5.0, 200.0, 1.0)
	var peak_biome : String = terrain.call("biome_name_at", peak_x, peak_z)
	print("  biome at artificially-raised point: %s" % peak_biome)
	_check("a point raised well above ridge_height classifies as 'peak'", peak_biome == "peak")

	_finish()

func _finish() -> void:
	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
