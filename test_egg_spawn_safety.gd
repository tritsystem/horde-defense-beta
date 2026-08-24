extends Node
# Headless test for the egg spawn-position fix (2026-07-20): "they shouldn't
# spawn in castle or above" -- _spawn_wave() used to place zombies at a flat
# offset with zero ground-height check. Proves _safe_spawn_position() finds
# real ground (terrain layer=1) and doesn't get fooled by a wall directly
# above/around the naive spawn point.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_egg_spawn_safety.tscn --quit

func _ready() -> void:
	print("=".repeat(60))
	print("  EGG SPAWN SAFETY -- real ground-height correction")
	print("=".repeat(60))

	# real ground on the dedicated terrain-only layer (bit 1, matches
	# LaneSpawner's ground_layer / basenode.gd's TERRAIN_COLLISION_MASK)
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	add_child(ground)
	var gshape := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(200, 1, 200)
	gshape.shape = gbox
	ground.add_child(gshape)
	ground.global_position = Vector3(0, 0, 0)

	# a "castle wall" directly above the egg's spawn point, on a DIFFERENT
	# layer (bit 2 only) -- exactly like this project's real wall/prop
	# convention (not on the dedicated terrain-only bit 1)
	var wall := StaticBody3D.new()
	wall.collision_layer = 2
	add_child(wall)
	var wshape := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(4, 4, 4)
	wshape.shape = wbox
	wall.add_child(wshape)
	wall.global_position = Vector3(0, 10, 0)   # a wall segment floating above the spawn point

	var egg := Node3D.new()
	egg.set_script(load("res://Egg.gd"))
	add_child(egg)
	egg.global_position = Vector3(0, 10, 0)   # egg placed right next to/inside the "wall"

	var safe_pos: Vector3 = egg.call("_safe_spawn_position", egg.global_position)
	print("  egg position: %s" % egg.global_position)
	print("  naive old behavior would have spawned at: %s (egg.y + 0.5, ignoring the wall)" % (egg.global_position + Vector3(0, 0.5, 0)))
	print("  _safe_spawn_position() actually returned: %s" % safe_pos)

	# the exact value can shift slightly with shape/collision-margin details;
	# what actually matters is that it's nowhere near the wall (y~8-12) or
	# the egg's own elevated spawn height (y=10) -- it should have found
	# real, low ground instead.
	var ok: bool = safe_pos.y < 5.0
	var label: String = "ok  " if ok else "FAIL"
	print("\n  %s -- found real low ground (y=%.2f), not the wall or the egg's own elevated height (10)" % [label, safe_pos.y])

	print("\n" + "-".repeat(42))
	print("  %s" % ("PASS" if ok else "FAIL"))
	print("-".repeat(42) + "\n")
	get_tree().quit(0 if ok else 1)
