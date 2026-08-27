extends Node
# Headless test for the Builder patrol fix (2026-08-24, 8th session):
# Builder previously picked a fresh RANDOM point each time it arrived near
# its last one -- reads as aimless drifting, not a deliberate patrol.
# Replaced with a fixed circular route around its own spawn point (which
# is always near the base -- see game_phase_script.gd::_spawn_team_ally).
# This confirms the route is real (repeats, doesn't just wander randomly
# forever) and stays within the intended patrol radius of the base/spawn.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_builder_patrol.tscn --quit-after 500

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BUILDER PATROL FIX")
	print("=".repeat(60))

	var script := load("res://team_ally.gd")
	var ally := CharacterBody3D.new()
	ally.set_script(script)
	ally.set("team_id", 1)
	ally.set("ally_class", 0)   # BUILDER
	add_child(ally)
	ally.global_position = Vector3(6000, 0, 6000)

	for i in range(60):
		await get_tree().physics_frame

	var spawn_pos : Vector3 = ally.get("_spawn_pos")

	# This minimal test scene has no baked NavigationRegion3D, so _seek()'s
	# NavigationAgent3D-based pathing can't produce real movement toward a
	# far target (a test-environment limitation, not a gameplay bug -- the
	# real levels have a baked navmesh). Directly simulate "having arrived"
	# at each patrol point instead, so this tests the actual thing that
	# changed -- point generation + circular index advancement -- rather
	# than depending on pathfinding infrastructure this scene doesn't have.
	var visited_indices : Dictionary = {}
	var max_dist_from_spawn := 0.0
	var last_idx := -1
	var idx_sequence : Array = []

	for i in range(30):
		var idx : int = int(ally.get("_builder_patrol_idx"))
		var pts : Array = ally.get("_builder_patrol_pts")
		if not pts.is_empty():
			ally.global_position = pts[idx]   # simulate arrival at the current target
		ally.call("_tick_builder_wander", 1.0 / 60.0)
		var d : float = ally.global_position.distance_to(spawn_pos)
		max_dist_from_spawn = maxf(max_dist_from_spawn, d)
		var new_idx : int = int(ally.get("_builder_patrol_idx"))
		if new_idx != last_idx:
			idx_sequence.append(new_idx)
			visited_indices[new_idx] = true
			last_idx = new_idx

	print("  distinct patrol points visited: %d" % visited_indices.size())
	print("  index sequence: %s" % str(idx_sequence))
	print("  max distance from spawn/base: %.2f" % max_dist_from_spawn)

	_check("visited at least 3 distinct patrol points (a real circuit, not stuck on one)",
		visited_indices.size() >= 3)
	_check("patrol sequence advances in a fixed, repeatable order (not random -- index 0,1,2,...)",
		idx_sequence.size() >= 3 and idx_sequence[1] == (idx_sequence[0] + 1) % 6)
	_check("stays within a reasonable radius of the base/spawn point (a real patrol, not drifting off)",
		max_dist_from_spawn < 10.0)

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
