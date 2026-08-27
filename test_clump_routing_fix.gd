extends Node
# Headless behavioral re-verification for the "zombies run to a corner of the
# map instead of at base/player" fix (4th session, 2026-08-24). Two
# INDEPENDENT real causes were found and fixed:
#
#   A) ZombieHordeManager._promote_to_z1()'s pooled-zombie recycling never
#      cleared squad_order/ai_mode/patrol_points in reset() -- a zombie whose
#      PREVIOUS life was a patrol guard or player-commanded unit kept
#      marching toward stale leftover coordinates after being recycled for
#      an unrelated new spawn (_tick_full()'s very first check routes on
#      squad_order != NONE before ever considering the current base).
#
#   B) zombie.gd::_find_bases() had no early-return guard, so it
#      unconditionally re-derived enemy_base/friendly_base from a raw
#      "bases" group scan on every _ready() -- silently discarding whatever
#      Egg.gd's _spawn_wave() had just explicitly pre-set (enemy_base =
#      HiveNestManager's chosen attack_target, friendly_base = the Egg
#      itself) the instant add_child() ran.
#
# This test stresses BOTH fixes harder than a single before/after check:
# (A) cycles many alternating squad-order "previous lives" through reset()
# to confirm the leak never reappears across repeated recycling, and (B)
# reproduces the EXACT scenario the original bug comment describes -- more
# than one enemy-team base present in the "bases" group -- to prove the
# pre-set target survives a raw scan that would otherwise overwrite it, and
# separately confirms the raw scan still works correctly for a zombie that
# legitimately has nothing pre-set (the fix must not break that path).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_clump_routing_fix.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ZOMBIE CLUMP / ROUTING FIX (re-verification)")
	print("=".repeat(60))

	_test_pool_recycle_stress()
	_test_find_bases_early_return()
	_test_find_bases_legit_scan_still_works()
	_test_convert_team_still_rederives()

	_finish()

# ── A: pool-recycle state-leak stress test ──────────────────────
func _test_pool_recycle_stress() -> void:
	print("\n-- A: pool-recycle state leak (reset() clearing) --")
	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)

	var far_patrol_points : Array = [Vector3(9999, 0, 9999), Vector3(-9999, 0, 9999)]
	var far_attack_pos := Vector3(12345, 0, -12345)
	var dummy_follow_target := Node3D.new()
	add_child(dummy_follow_target)

	var cycles := 40
	var leaks := 0
	for i in range(cycles):
		# simulate a "previous life" ending in one of several real
		# stateful commands, alternating so no single code path is
		# under-tested across the stress run
		match i % 3:
			0:
				z.set("patrol_points", far_patrol_points)
				z.call("command_patrol")
			1:
				z.call("command_attack_position", far_attack_pos, true)
			2:
				z.call("command_follow", dummy_follow_target, true)

		# simulate ZombieHordeManager._promote_to_z1()'s recycle call
		z.call("reset", Vector3(float(i), 0.0, 0.0))

		var squad_order : int = z.get("squad_order")
		var ai_mode : int = z.get("ai_mode")
		var patrol_pts : Array = z.get("patrol_points")
		var persistent : bool = z.get("order_persistent")

		if squad_order != 0 or ai_mode != 0 or not patrol_pts.is_empty() or persistent:
			leaks += 1
			print("  FAIL cycle %d (prev=%d): squad_order=%d ai_mode=%d patrol_points=%s persistent=%s" % [
				i, i % 3, squad_order, ai_mode, patrol_pts, persistent])

	_check("reset() clears squad_order/ai_mode/patrol_points/persistence across %d alternating recycle cycles (0 leaks)" % cycles,
		leaks == 0)

	z.queue_free()
	dummy_follow_target.queue_free()

# ── B: _find_bases() honors a pre-set Egg.gd contract ───────────
func _test_find_bases_early_return() -> void:
	print("\n-- B: _find_bases() early-return honors Egg.gd's pre-set bases --")

	# reproduce the exact risk the original bug comment describes: MORE
	# THAN ONE enemy-team base present in the "bases" group when the
	# zombie spawns.
	var real_target := Node3D.new()
	real_target.set("team_id", 1)
	real_target.name = "RealIntendedEnemyBase"
	add_child(real_target)
	real_target.add_to_group("bases")

	var decoy := Node3D.new()
	decoy.set_script(_dummy_base_script())
	decoy.set("team_id", 1)
	decoy.name = "DecoyEnemyBase"
	add_child(decoy)
	decoy.add_to_group("bases")   # added AFTER real_target -- wins a raw last-write-wins scan

	var egg_dummy := Node3D.new()
	egg_dummy.name = "EggDummy"
	add_child(egg_dummy)
	# deliberately NOT added to the "bases" group -- matches Egg.gd's real
	# contract (friendly_base = self, the Egg node, never group-tagged)

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	z.set("team_id", 2)
	# Egg.gd's real sequence: set both BEFORE add_child()
	z.set("enemy_base", real_target)
	z.set("friendly_base", egg_dummy)
	add_child(z)   # triggers _ready() -> _find_bases()

	var final_enemy = z.get("enemy_base")
	var final_friendly = z.get("friendly_base")

	_check("enemy_base stays the Egg-assigned target, not overwritten by the decoy found in a raw group scan",
		final_enemy == real_target)
	_check("friendly_base stays the Egg-assigned value (the Egg itself, never group-tagged)",
		final_friendly == egg_dummy)

	z.queue_free()
	real_target.queue_free()
	decoy.queue_free()
	egg_dummy.queue_free()

# ── B (control): a zombie with NOTHING pre-set must still resolve bases ──
func _test_find_bases_legit_scan_still_works() -> void:
	print("\n-- B (control): _find_bases() raw scan still works when nothing is pre-set --")

	var enemy_of_2 := Node3D.new()
	enemy_of_2.set_script(_dummy_base_script())
	enemy_of_2.set("team_id", 1)
	add_child(enemy_of_2)
	enemy_of_2.add_to_group("bases")

	var friendly_of_2 := Node3D.new()
	friendly_of_2.set_script(_dummy_base_script())
	friendly_of_2.set("team_id", 2)
	add_child(friendly_of_2)
	friendly_of_2.add_to_group("bases")

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	z.set("team_id", 2)
	# nothing pre-set this time -- matches a manager-recycled zombie whose
	# reset() path (ZombieHordeManager._promote_to_z1) sets bases directly
	# via a different mechanism, but here simulates any code path that
	# genuinely needs the scan to run
	add_child(z)

	var final_enemy = z.get("enemy_base")
	var final_friendly = z.get("friendly_base")

	_check("with nothing pre-set, enemy_base still resolves correctly via the raw scan (fix didn't break the legitimate path)",
		final_enemy == enemy_of_2)
	_check("with nothing pre-set, friendly_base still resolves correctly via the raw scan",
		final_friendly == friendly_of_2)

	z.queue_free()
	enemy_of_2.queue_free()
	friendly_of_2.queue_free()

# ── convert_team() must still force a fresh re-derivation ───────
func _test_convert_team_still_rederives() -> void:
	print("\n-- convert_team() still nulls + re-derives (early-return doesn't block this) --")

	var base_team1 := Node3D.new()
	base_team1.set_script(_dummy_base_script())
	base_team1.set("team_id", 1)
	add_child(base_team1)
	base_team1.add_to_group("bases")

	var base_team2 := Node3D.new()
	base_team2.set_script(_dummy_base_script())
	base_team2.set("team_id", 2)
	add_child(base_team2)
	base_team2.add_to_group("bases")

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	z.set("team_id", 1)
	add_child(z)
	var before_enemy = z.get("enemy_base")
	_check("sanity: before convert_team(), enemy_base resolved to the team-2 base",
		before_enemy == base_team2)

	z.call("convert_team")
	var after_enemy = z.get("enemy_base")
	var after_friendly = z.get("friendly_base")
	_check("convert_team() re-derives enemy_base to the NEW opposing team's base (team_id flipped, was 1 now 2)",
		after_enemy == base_team1 and z.get("team_id") == 2)
	_check("convert_team() re-derives friendly_base to the NEW same-team base",
		after_friendly == base_team2)

	z.queue_free()
	base_team1.queue_free()
	base_team2.queue_free()

func _dummy_base_script() -> GDScript:
	var src := GDScript.new()
	src.source_code = "extends Node3D\nvar team_id : int = 0\n"
	src.reload()
	return src

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
