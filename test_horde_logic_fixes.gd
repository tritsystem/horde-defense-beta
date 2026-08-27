extends Node
# Headless test for two real bugs found while checking "creep logic and
# horde logic" (2026-08-24, 7th session):
#
# 1. zombie.gd::set_lod(level) had no case for level==3 -- ZombieHordeManager
#    ._update_z1_lod() computes a 4-band distance tier (0/1/2/3) and calls
#    set_lod(nlod) directly, but the match only ever handled 0/1/2. A Z1
#    zombie beyond LOD2_DIST (350u) silently kept whatever lod/physics
#    state it last had instead of actually sleeping.
#
# 2. tank.gd's Taunt ability called u.set("target", self) as a fallback
#    (no set_forced_target() existed anywhere on zombie.gd), which got
#    silently overwritten by the very next periodic targeting scan
#    (~0.18-0.4s later) -- Taunt's stated 3.5s duration lasted well under
#    half a second against any real zombie-type target. Added a real
#    set_forced_target() that _select_target() checks first.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_horde_logic_fixes.tscn --quit-after 400

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  HORDE/CREEP LOGIC FIXES (set_lod level 3, forced target)")
	print("=".repeat(60))

	await _test_set_lod_level_3()
	await _test_forced_target_persists()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _test_set_lod_level_3() -> void:
	print("\n-- set_lod(3) actually sleeps the zombie --")
	var z : Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	await get_tree().physics_frame

	z.call("set_lod", 0)
	_check("set_lod(0) enables physics_process", z.is_physics_processing())

	z.call("set_lod", 3)
	_check("set_lod(3) disables physics_process (was previously a no-op)", not z.is_physics_processing())
	_check("set_lod(3) sets internal lod to SLEEP", int(z.get("lod")) == 2)   # LOD.SLEEP == 2

	z.queue_free()

func _test_forced_target_persists() -> void:
	print("\n-- set_forced_target() survives the normal retarget scan --")
	var z : Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	z.set("team_id", 2)
	z.global_position = Vector3(8000, 0, 8000)

	var tank_stub := Node3D.new()
	add_child(tank_stub)
	tank_stub.set_script(_dummy_script())
	tank_stub.set("team_id", 1)
	tank_stub.global_position = Vector3(8005, 0, 8000)

	var decoy := Node3D.new()
	add_child(decoy)
	decoy.set_script(_dummy_script())
	decoy.set("team_id", 1)
	decoy.global_position = Vector3(8000.5, 0, 8000)   # much closer -- would normally win priority

	_check("has_method('set_forced_target') is now true (tank.gd's real branch, not the raw fallback)",
		z.has_method("set_forced_target"))

	z.call("set_forced_target", tank_stub, 3.5)

	# Run enough frames to span several normal retarget-scan cycles
	# (MARCH_SCAN_INTERVAL=0.18s / RETARGET_INTERVAL=0.4s) and confirm the
	# forced target ISN'T overwritten by the closer decoy.
	var stayed_locked := true
	for i in range(120):   # 2s at 60Hz
		await get_tree().physics_frame
		if z.get("target") != tank_stub:
			stayed_locked = false
	_check("forced target stays locked across ~2s / many retarget-scan cycles despite a closer decoy",
		stayed_locked)

	z.queue_free()
	tank_stub.queue_free()
	decoy.queue_free()

func _dummy_script() -> GDScript:
	var src := GDScript.new()
	src.source_code = "extends Node3D\nvar team_id : int = 0\nvar health : float = 100.0\nvar max_health : float = 100.0\n"
	src.reload()
	return src

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
