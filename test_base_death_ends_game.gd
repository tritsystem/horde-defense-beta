extends Node
# Headless behavioral test for "base being dead should auto end game"
# (2026-08-24, 10th session): basenode.gd::_on_destroyed() has always
# called gm._on_base_died(team_id), but that method was never implemented
# ANYWHERE in the codebase (confirmed via repo-wide grep before fixing) --
# a base hitting 0 HP just... did nothing. Also fixed the lookup itself:
# it used the "game_manager" group, the SAME ambiguous group
# game_phase_script.gd's own _ready() comment already documents as
# unreliable (a second, unrelated legacy node shares it -- wrong node
# picked in 2 of 3 runs when an earlier session measured it) -- switched
# to "economy_controller", the dedicated unambiguous group that already
# exists for this exact reason.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_base_death_ends_game.tscn --quit-after 400

var _pass := 0
var _fail := 0
var _game_over_winner : int = -1

func _ready() -> void:
	print("=".repeat(60))
	print("  BASE DEATH -> GAME OVER WIRING")
	print("=".repeat(60))

	var gpc_scene := load("res://scenes/game_phase_script.tscn") as PackedScene
	_check("game_phase_script.tscn loaded", is_instance_valid(gpc_scene))
	if not is_instance_valid(gpc_scene):
		_finish(); return

	var gpc : Node = gpc_scene.instantiate()
	add_child(gpc)
	if gpc.has_signal("game_over"):
		gpc.connect("game_over", _on_game_over)

	await get_tree().physics_frame
	await get_tree().physics_frame

	_check("GamePhaseController joined 'economy_controller' (the unambiguous group basenode.gd now uses)",
		gpc.is_in_group("economy_controller"))
	_check("GamePhaseController implements _on_base_died (was missing everywhere before this fix)",
		gpc.has_method("_on_base_died"))

	# A real base, team 1 (the player's side) -- killing it should end the
	# match with team 2 as the winner.
	var base_script := load("res://scripts/basenode.gd")
	var base := Node3D.new()
	base.set_script(base_script)
	base.set("team_id", 1)
	add_child(base)
	await get_tree().physics_frame

	_check("base starts alive", not bool(base.call("is_dead")))

	base.call("take_damage", 999999.0, null)

	_check("base is now dead", bool(base.call("is_dead")))
	_check("game_over signal fired", _game_over_winner != -1)
	_check("winner is team 2 (team 1's base died)", _game_over_winner == 2)
	_check("GamePhaseController's own phase transitioned to 'done'",
		gpc.call("get_current_phase") == "done" if gpc.has_method("get_current_phase") else true)

	_finish()

func _on_game_over(winner: int) -> void:
	_game_over_winner = winner

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
