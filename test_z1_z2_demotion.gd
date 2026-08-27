extends Node
# Headless test for the Z1->Z2 demotion fix (2026-08-24, 7th session):
# ZombieHordeManager had _promote_z3_to_z2/_promote_z2_to_z1/
# _demote_z2_to_z3 but NO way to ever move a Z1-active real CharacterBody3D
# zombie back down to the cheap Z2 crowd based on distance -- only death
# freed a Z1 slot. Combined with zombie.gd::set_lod()'s missing level-3
# case (also fixed this session), a zombie left behind or abandoned by a
# retreating player just kept running full physics/AI cost forever while
# invisible. Also verifies the fix respects zombie ownership: only
# pool-owned (_promote_to_z1) zombies may be demoted back into the shared
# pool -- externally-registered ones (register_z1(), HiveCluster/Egg) must
# never be silently reclaimed.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_z1_z2_demotion.tscn --quit-after 300

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  Z1 -> Z2 DEMOTION FIX")
	print("=".repeat(60))

	var zhm := get_tree().root.get_node_or_null("ZombieHordeManager")
	_check("ZombieHordeManager autoload found", is_instance_valid(zhm))
	if not is_instance_valid(zhm):
		_finish()
		return

	# ZHM's own _try_init() (pool population, flow-field lookup, etc.) is
	# gated behind a 0.5s real-time retry accumulator in _process(), not
	# _ready() -- wait for it, same lesson learned earlier this session
	# about this project's heavy per-scene autoload boot tax.
	var waited := 0
	while not bool(zhm.get("_initialized")) and waited < 200:
		await get_tree().physics_frame
		waited += 1
	_check("ZombieHordeManager finished _try_init() (pool populated)", bool(zhm.get("_initialized")))

	# make sure this test starts from a clean slate regardless of whatever
	# main.tscn's own SceneSetup boot may have already spawned
	var before_z1 : int = (zhm.get("_z1_active") as Array).size()
	var before_z2 : int = int(zhm.get("_z2_count"))

	# a pool-owned zombie, spawned right at the origin (near the fake player below)
	var z = zhm.call("_promote_to_z1", Vector3(50000, 0, 50000), 2)
	_check("_promote_to_z1 returned a real zombie instance", is_instance_valid(z))
	if not is_instance_valid(z):
		_finish()
		return
	_check("promoted zombie is marked pool-owned (_horde_mgr set -- this line used to be a silent no-op)",
		z.get("_horde_mgr") == zhm)

	# an externally-registered zombie (simulates a HiveCluster patrol guard) --
	# must NEVER be silently demoted/reclaimed by distance alone
	var z_ext = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z_ext)
	z_ext.global_position = Vector3(50000, 0, 50000)
	z_ext.set("team_id", 2)
	zhm.call("register_z1", z_ext)
	_check("externally-registered zombie has NO _horde_mgr set", not is_instance_valid(z_ext.get("_horde_mgr")))

	# put the only "player" far away so both zombies are well outside
	# ZONE1_RADIUS*1.4
	zhm.set("_player_positions", [Vector3(-50000, 0, -50000)])

	var z1_before : int = (zhm.get("_z1_active") as Array).size()
	zhm.call("_check_promotions")
	var z1_after : Array = zhm.get("_z1_active")
	var z2_after : int = int(zhm.get("_z2_count"))

	print("  z1 active before=%d after=%d | z2 count before=%d after=%d" % [z1_before, z1_after.size(), before_z2, z2_after])
	_check("pool-owned far-away zombie is no longer in _z1_active", not z1_after.has(z))
	_check("pool-owned far-away zombie's slot moved into the Z2 crowd count", z2_after > before_z2)
	_check("externally-registered far-away zombie STAYS in _z1_active (never silently reclaimed)",
		z1_after.has(z_ext))

	z_ext.queue_free()
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
