extends Node
# Real-cost profiling (2026-07-20): "fix fps game too slow". Times the REAL
# _physics_process(delta) -- the full AAA tick chain (status effects, boss
# checks, elite ability, swarm broadcast, network sync, debug overlay, plus
# movement/targeting) -- across increasing zombie counts, to see whether
# this per-zombie cost is the real remaining FPS bottleneck.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_zombie_fps_profile.tscn --quit

func _ready() -> void:
	print("=".repeat(70))
	print("  FPS PROFILE -- real _physics_process() cost vs zombie count")
	print("=".repeat(70))

	var floor := StaticBody3D.new()
	floor.collision_layer = 3
	floor.collision_mask = 3
	add_child(floor)
	var fshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(500, 1, 500)
	fshape.shape = box
	floor.add_child(fshape)
	floor.global_position = Vector3(9000, 0, 9000)   # isolated, away from any autoloaded scene content

	for n in [10, 30, 60, 100]:
		_profile_n(n)

	get_tree().quit()

func _profile_n(n: int) -> void:
	var zombies: Array = []
	var base := Node3D.new()
	add_child(base)
	base.global_position = Vector3(9000, 0, 9050)

	for i in range(n):
		var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
		add_child(z)
		z.global_position = Vector3(9000 + randf_range(-20, 20), 2, 9000 + randf_range(-20, 20))
		z.set("enemy_base", base)
		z.set("team_id", 1)
		zombies.append(z)

	const DELTA := 1.0 / 60.0
	var start_us := Time.get_ticks_usec()
	for tick in range(60):   # one simulated second
		for z in zombies:
			z._physics_process(DELTA)
	var elapsed_ms: float = float(Time.get_ticks_usec() - start_us) / 1000.0

	print("n=%3d zombies -> 1 simulated second (60 ticks) costs %9.3f ms total  (%.4f ms/zombie/sec, %.4f ms/zombie/tick)" % [
		n, elapsed_ms, elapsed_ms / float(n), elapsed_ms / float(n) / 60.0])

	for z in zombies:
		z.free()
	base.free()
