extends Node
# Headless test for the movement rework (2026-07-20): "they don't move
# normal, they glitch around and bounce" -- replaced the flickering
# NavigationAgent/direct-steering branch in _move_toward() with
# deterministic direct steering modulated by a real Spikeling brain
# (Aggro/Caution). Also proves basic real movement still works (the
# project's own documented verification pattern: floor + base + zombie,
# tick ~90 frames, check movedXZ>1).
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_zombie_movement_rework.tscn

func _ready() -> void:
	print("=".repeat(60))
	print("  ZOMBIE MOVEMENT REWORK -- deterministic steering + Spikeling brain")
	print("=".repeat(60))

	# a real floor
	var floor := StaticBody3D.new()
	floor.collision_layer = 3
	floor.collision_mask = 3
	add_child(floor)
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	floor_shape.shape = box
	floor.add_child(floor_shape)
	floor.global_position = Vector3(0, 0, 0)

	# a real enemy base far away
	var base := Node3D.new()
	add_child(base)
	base.global_position = Vector3(0, 0, 50)

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	z.global_position = Vector3(0, 5, 0)
	z.set("enemy_base", base)
	z.set("ai_mode", 0)   # LANE_PUSH

	await get_tree().physics_frame
	var pos0: Vector3 = z.global_position

	for i in range(90):
		await get_tree().physics_frame

	var pos1: Vector3 = z.global_position
	var moved_xz: float = Vector2(pos1.x - pos0.x, pos1.z - pos0.z).length()
	print("  moved XZ over 90 ticks: %.3f  (pos0=%s pos1=%s)" % [moved_xz, pos0, pos1])
	var pass1: bool = moved_xz > 1.0
	print("  %s -- real forward movement happens (project's own verification bar)" % ("ok  " if pass1 else "FAIL"))

	# ── brain: sustained closing distance drives a real Aggro speed burst ──
	var chaser: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(chaser)
	chaser.global_position = Vector3(100, 5, 100)
	var prey := Node3D.new()
	add_child(prey)
	prey.global_position = Vector3(100, 5, 120)
	chaser.set("target", prey)
	var mult_before: float = chaser.call("_current_speed_mult")
	print("  speed mult before any chase data: %.2f" % mult_before)
	var burst := false
	for i in range(60):
		chaser.global_position.z += 0.3   # genuinely closing on the target each tick
		chaser.call("_brain_tick", 0.05)
		if chaser.call("_current_speed_mult") > 1.0:
			burst = true
			break
	print("  %s -- sustained real closing distance drives a genuine Aggro speed burst" % ("ok  " if burst else "FAIL"))

	# NOTE: zombie.tscn has its own scene-authored NavigationAgent3D node
	# (separate from the one the SCRIPT used to dynamically create) --
	# it has no avoidance_enabled set and nothing in the script reads it
	# anymore, so it's inert dead weight, not a functional concern. The
	# real, meaningful claim is that the script's OWN _nav_agent reference
	# (previously created and driven every _move_toward() call) is now
	# never instantiated at all.
	var nav_agent_var = z.get("_nav_agent")
	print("  script's own _nav_agent var: %s" % ("null (never created)" if nav_agent_var == null else "NOT null"))
	var no_script_nav: bool = nav_agent_var == null
	print("  %s -- the script no longer creates/drives its own NavigationAgent3D" % ("ok  " if no_script_nav else "FAIL"))

	var all_pass: bool = pass1 and burst and no_script_nav
	print("\n" + "-".repeat(42))
	print("  %s" % ("ALL PASS" if all_pass else "SOME FAILED"))
	print("-".repeat(42) + "\n")
	get_tree().quit(0 if all_pass else 1)
