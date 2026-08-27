extends Node
# Headless regression test for a real gap found while unifying zombie.gd's
# target-priority scorers (2026-08-24 rebuild): the default lane-march path
# (_tick_lane_march, used by every FULL-LOD zombie with no squad order --
# i.e. almost all of them) had NO code path to ever attack the enemy base,
# even once every turret was destroyed. Only LOD.CHEAP's separate
# simplified logic could. A FULL-LOD marching zombie just walked to the
# base and stood there forever, doing nothing. Fixed by folding base
# priority into the unified TargetPriority.select() call both paths share.
#
# This test proves the fix at the _tick_lane_march() integration level (not
# just TargetPriority.select() in isolation, already covered by
# test_target_priority_unified.gd): a real zombie, with a real enemy_base
# and zero turrets, should actually reach AND start damaging the base.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_march_reaches_base.tscn --quit-after 1300

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  MARCH REACHES + ATTACKS BASE (no turrets alive)")
	print("=".repeat(60))

	var floor := StaticBody3D.new()
	floor.collision_layer = 3
	floor.collision_mask = 3
	add_child(floor)
	var fshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	fshape.shape = box
	floor.add_child(fshape)
	floor.global_position = Vector3(9500, 0, 9500)

	var base := Node3D.new()
	base.set_script(_base_script())
	add_child(base)
	base.set("team_id", 2)
	base.global_position = Vector3(9500, 0.5, 9515)   # 15 units away

	var z : Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	z.global_position = Vector3(9500, 5, 9500)
	z.set("team_id", 1)
	z.set("enemy_base", base)   # bypass _find_bases() -- same contract Egg.gd uses

	# No turrets anywhere in the "turrets" group -- base should be
	# immediately reachable (not shielded), matching basenode.gd's own
	# "shield scales with living turret count" rule at zero turrets.

	var reached_range := false
	var damage_landed := false
	for i in range(700):
		await get_tree().physics_frame
		var dist : float = (z as Node3D).global_position.distance_to(base.global_position)
		if dist <= float(z.get("attack_range")) + float(z.get("base_range")):
			reached_range = true
		if float(base.get("damage_taken")) > 0.0:
			damage_landed = true
			break

	print("  final distance to base: %.2f" % (z as Node3D).global_position.distance_to(base.global_position))
	print("  final target_type: %s" % z.get("target_type"))
	print("  base damage_taken: %.2f" % float(base.get("damage_taken")))
	_check("zombie actually closed the distance toward the base", reached_range)
	_check("zombie's target_type became 'base' once in range", z.get("target_type") == "base")
	_check("zombie actually landed real damage on the base (not just standing there)", damage_landed)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _base_script() -> GDScript:
	var src := GDScript.new()
	src.source_code = "extends Node3D\nvar team_id : int = 0\nvar health : float = 500.0\nvar max_health : float = 500.0\nvar damage_taken : float = 0.0\nfunc take_damage(amount: float, _instigator = null) -> void:\n\tdamage_taken += amount\n\thealth -= amount\n"
	src.reload()
	return src

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
