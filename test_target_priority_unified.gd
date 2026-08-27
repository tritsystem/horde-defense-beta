extends Node
# Headless test for TargetPriority.gd (2026-08-24 rebuild) -- the unified
# target-priority scorer that replaced zombie.gd's two previously
# independent, inconsistently-tuned implementations (_find_best_target,
# squad-order-only, and _find_blocker, default-march-only). Tests the
# extracted class directly with plain Node3D mocks -- no need to instantiate
# a real zombie.tscn (and pay this project's ~150-iteration SceneSetup
# autoload boot tax) since TargetPriority is deliberately host-agnostic.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_target_priority_unified.tscn --quit-after 300

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TARGET PRIORITY UNIFIED SCORER")
	print("=".repeat(60))

	_test_priority_order()
	_test_closer_weaker_scoring()
	_test_cone_gating()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _mock(pos: Vector3, team_id: int, health: float = 100.0, max_health: float = 100.0) -> Node3D:
	var n := Node3D.new()
	n.set_script(_mock_script())
	add_child(n)
	n.set("team_id", team_id)
	n.set("health", health)
	n.set("max_health", max_health)
	n.global_position = pos
	return n

func _mock_script() -> GDScript:
	var src := GDScript.new()
	src.source_code = "extends Node3D\nvar team_id : int = 0\nvar health : float = 100.0\nvar max_health : float = 100.0\n"
	src.reload()
	return src

func _always_visible(_n: Node3D) -> bool:
	return true

func _never_visible(_n: Node3D) -> bool:
	return false

# ── (a)(b)(c): priority order -- player > unit > turret > base ─────────
func _test_priority_order() -> void:
	print("\n-- Priority order --")
	var self_node := _mock(Vector3.ZERO, 2)
	var player := _mock(Vector3(2, 0, 0), 1)
	var unit := _mock(Vector3(2, 0, 0), 1)
	var turret := _mock(Vector3(2, 0, 0), 1)
	var base := _mock(Vector3(2, 0, 0), 1)

	var los := Callable(self, "_always_visible")

	# (a) player beats unit/turret when all are in range
	var r1 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[player], [unit], [turret], {}, base)
	_check("player wins over unit/turret when all in range", r1.target == player and r1.target_type == "player")

	# (b) with no player/unit, nearest living turret wins
	var r2 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[], [], [turret], {}, base)
	_check("turret wins when no player/unit present", r2.target == turret and r2.target_type == "turret")

	# (c) with turret dead (health<=0), base becomes reachable
	var dead_turret := _mock(Vector3(2, 0, 0), 1, 0.0, 100.0)
	var r3 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[], [], [dead_turret], {}, base)
	_check("base becomes the target once the only turret is dead", r3.target == base and r3.target_type == "base")

	# (d) REAL BUG FIX (2026-08-24): base must be targetable even while a
	# turret is alive somewhere but not currently reachable (LOS-blocked) --
	# this used to be gated on turret COUNT alone (any living turret = base
	# fully blocked, matching a stale assumption about basenode.gd's shield
	# that no longer matches its real, partial-shield behavior), which meant
	# NO zombie ever attacked the base for most of a real match (turrets
	# spawn round 1). A turret that's alive but unreachable must not still
	# lock the base out.
	var blocked_turret := _mock(Vector3(50, 0, 50), 1)   # alive, but LOS-blocked below
	var no_los := Callable(self, "_never_visible")
	var r4 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, true, no_los,
		[], [], [blocked_turret], {}, base)
	_check("base becomes targetable when the only living turret is alive but unreachable (not just when turrets are all dead)",
		r4.target == base and r4.target_type == "base")

	# (d, control) a REACHABLE living turret still wins over the base (turret priority preserved)
	var r5 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[], [], [blocked_turret], {}, base)
	_check("a reachable living turret still takes priority over the base", r5.target_type == "turret")

# ── (d): closer + weaker scoring ────────────────────────────────────────
func _test_closer_weaker_scoring() -> void:
	print("\n-- Closer + weaker scoring --")
	var self_node := _mock(Vector3.ZERO, 2)
	var los := Callable(self, "_always_visible")

	# equal distance, different health -- weaker (lower hp_pct) should win
	var strong := _mock(Vector3(3, 0, 0), 1, 100.0, 100.0)
	var weak := _mock(Vector3(0, 0, 3), 1, 10.0, 100.0)
	var r : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[strong, weak], [], [], {}, null)
	_check("at equal distance, the weaker (lower HP%) player is preferred", r.target == weak)

	# same health, different distance -- closer should win (isolates the
	# distance term the same way the case above isolates the health term)
	var near : Node3D = _mock(Vector3(1, 0, 0), 1, 100.0, 100.0)
	var far : Node3D = _mock(Vector3(15, 0, 0), 1, 100.0, 100.0)
	var r2 : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, Vector3.ZERO, 0.2, false, los,
		[near, far], [], [], {}, null)
	_check("at equal health, the closer player is preferred", r2.target == near)

# ── (e): cone gating ─────────────────────────────────────────────────────
func _test_cone_gating() -> void:
	print("\n-- Cone gating --")
	var self_node := _mock(Vector3.ZERO, 2)
	var los := Callable(self, "_always_visible")
	var forward := Vector3.FORWARD   # (0,0,-1) in Godot's convention
	var behind_player := _mock(-forward * 3.0, 1)   # directly behind

	var r_cone : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, true, forward, 0.5, false, los,
		[behind_player], [], [], {}, null)
	_check("require_cone=true rejects a candidate directly behind", not is_instance_valid(r_cone.target))

	var r_nocone : Dictionary = TargetPriority.select(
		self_node, 2, false, 20.0, 5.0, false, forward, 0.5, false, los,
		[behind_player], [], [], {}, null)
	_check("require_cone=false accepts the same candidate", r_nocone.target == behind_player)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
