extends Node
# Headless test for Pillar 1 (Game Feel & Juice) batch 1 (2026-07-20):
# Screenshake.gd existed fully built but was never called anywhere.
# Proves zombie attacks landing on the player now actually trigger it.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_juice_screenshake.tscn --quit

func _ready() -> void:
	print("=".repeat(60))
	print("  JUICE -- Screenshake wired into zombie attacks landing")
	print("=".repeat(60))

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	z.global_position = Vector3(9500, 2, 9500)
	z.set("team_id", 1)

	var player := Node3D.new()
	player.set_script(_fake_player_script())
	add_child(player)
	player.global_position = Vector3(9500, 2, 9501)

	# Screenshake has no observable state without a bound camera; verify via
	# the actual internal state it sets (_timer > 0 after a shake() call)
	var before: float = Screenshake._timer
	z.call("_try_attack", player)
	var after: float = Screenshake._timer

	print("  Screenshake._timer before: %.3f  after player hit landed: %.3f" % [before, after])
	var ok: bool = after > before
	print("\n  %s -- a zombie attack landing on the player triggers a real screenshake" % ("ok  " if ok else "FAIL"))
	print("\n" + "-".repeat(42))
	print("  %s" % ("PASS" if ok else "FAIL"))
	print("-".repeat(42) + "\n")
	get_tree().quit(0 if ok else 1)

func _fake_player_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node3D\nvar team_id: int = 2\nvar health: float = 100.0\nvar max_health: float = 100.0\nfunc _ready():\n\tadd_to_group(\"players\")\nfunc take_damage(amount, instigator=null):\n\thealth -= amount\n"
	s.reload()
	return s
