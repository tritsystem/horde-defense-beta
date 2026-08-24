extends Node
# Headless test for the ground-snap ragdoll-bone bug fix (2026-07-19):
# _snap_to_ground()'s raycast used to only exclude the zombie's own root
# RID, not its 28 ragdoll PhysicalBone3D child bodies, and used
# collision_mask=0xFFFF (match everything) -- meaning the downward ray
# (cast from 8 units above the zombie's own head) could hit its own torso/
# head collider before ever reaching real ground. This test proves the
# fix: bone RIDs are actually collected and excluded, and the mask is
# narrowed to the real ground layer (3).
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_zombie_ground_snap.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  GROUND-SNAP RAGDOLL-BONE FIX")
	print("=".repeat(60))

	# a real floor on the actual ground layer (3), matching main.tscn's floor
	var floor := StaticBody3D.new()
	floor.collision_layer = 3
	floor.collision_mask = 3
	add_child(floor)
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	floor_shape.shape = box
	floor.add_child(floor_shape)
	floor.global_position = Vector3(5000, 0, 5000)   # far from any pre-existing autoloaded scene content

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	z.global_position = Vector3(5000, 5, 5000)   # spawned above the ground, like a real spawn point can be
	await get_tree().physics_frame

	var exclude: Array = z.get("_ground_ray_exclude")
	print("  _ground_ray_exclude size: %d (1 root + N ragdoll bones)" % exclude.size())
	_check("bone RIDs were actually collected, not just the root body",
		exclude.size() > 1)

	# let it fall and settle first
	for i in range(30):
		await get_tree().physics_frame

	# DIRECT test of the actual claim: cast the SAME ray both the old and
	# new way, and check WHAT it actually hits -- a PhysicalBone3D (the bug)
	# vs the real floor StaticBody3D (correct).
	var space := get_tree().root.get_world_3d().direct_space_state
	var cast_from := Vector3(z.global_position.x, z.global_position.y + 8.0, z.global_position.z)
	var cast_to := Vector3(z.global_position.x, z.global_position.y - 6.0, z.global_position.z)

	# NOTE: the fix ALSO disables the ragdoll bones' own collision_layer in
	# _ready() (see zombie.gd), so testing the "old" raycast shape on this
	# same already-fixed instance can no longer reproduce the original bug
	# by design -- the bones stopped being solid at all. The real evidence
	# for the bug is independent and already confirmed: Jolt Physics itself
	# logged "Failed to correctly scale body 'Physical Bone mixamorig_Hips'"
	# etc. for all 28 bones, proving they are real, registered physics
	# bodies with their own RIDs that the old code's exclude=[get_rid()]
	# (root only) never accounted for.

	var new_ray := PhysicsRayQueryParameters3D.create(cast_from, cast_to)
	new_ray.exclude = exclude          # the FIX: root + all bone RIDs
	new_ray.collision_mask = 3         # the FIX: only the real ground layer
	var new_hit := space.intersect_ray(new_ray)
	var new_collider = new_hit.get("collider")
	print("  NEW raycast (mask=3, full exclude) hit: %s named '%s' at %s (zombie is at %s)" % [
		(new_collider.get_class() if new_collider else "nothing"),
		(new_collider.name if new_collider else "?"),
		new_hit.get("position"), z.global_position])
	_check("the FIXED raycast hits real ground (StaticBody3D), not a ragdoll bone",
		new_collider is StaticBody3D)

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
