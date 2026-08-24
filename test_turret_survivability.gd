extends Node
# Headless combat-simulation test (2026-07-20): "make sure turrets can
# survive the first 5 minutes of play". Simulates real sustained damage
# via the ACTUAL take_damage() function (including its existing
# damage_resistance=0.85 reduction against "units"/"zombies" attackers,
# and armor), at the real zombie attack cadence (damage=15, cooldown=0.9s),
# rather than trusting arithmetic alone.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_turret_survivability.tscn --quit

const SIM_SECONDS := 300.0   # 5 minutes
const ZOMBIE_DAMAGE := 15.0
const ZOMBIE_COOLDOWN := 0.9

func _ready() -> void:
	print("=".repeat(60))
	print("  TURRET SURVIVABILITY -- 5 real minutes of sustained attack")
	print("=".repeat(60))

	for zombie_count in [1, 2, 3, 5]:
		_simulate(zombie_count)

	get_tree().quit()

func _simulate(zombie_count: int) -> void:
	var use_scene := ResourceLoader.exists("res://scenes/turret.tscn")
	var t: Node = (load("res://scenes/turret.tscn") as PackedScene).instantiate() if use_scene else _make_bare_turret()
	add_child(t)
	t.team_id = 1
	if not use_scene:
		t.call("_base_ready")

	# a real "attacker" object with team_id + group membership matching
	# what take_damage() actually checks (units/zombies -> damage_resistance)
	var attacker := Node3D.new()
	attacker.set_script(_fake_attacker_script())
	attacker.set("team_id", 2)
	add_child(attacker)

	var elapsed := 0.0
	var next_hit := 0.0
	while elapsed < SIM_SECONDS and t.health > 0.0:
		if elapsed >= next_hit:
			next_hit += ZOMBIE_COOLDOWN
			for i in range(zombie_count):
				t.take_damage(ZOMBIE_DAMAGE, attacker)
				if t.health <= 0.0:
					break
		elapsed += 0.05   # fine-grained sim step, cheap since no real physics/awaits

	var survived: bool = t.health > 0.0
	print("  %d zombie(s) sustained fire -> %s (health %.0f/%.0f%s)" % [
		zombie_count,
		("SURVIVED the full 5 min" if survived else "died at t=%.1fs" % elapsed),
		t.health, t.max_health,
		"" if survived else ""])

	t.free(); attacker.free()

func _make_bare_turret() -> Node:
	var t := Node3D.new()
	t.set_script(load("res://baseturret.gd"))
	return t

func _fake_attacker_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node3D\nvar team_id: int = 2\nfunc _ready():\n\tadd_to_group(\"units\")\n\tadd_to_group(\"zombies\")\n"
	s.reload()
	return s
