# ============================================================
# GlowingZombie.gd — Rare glowing zombie (easter egg)
# ============================================================
# Extends the base zombie with a bright emissive glow.
# Drops a sword_recharge pickup on death.
# 1% spawn chance — injected by LaneSpawner at wave spawn.
#
# Usage: instantiate like any zombie; swap script on existing node
#        OR use as a separate scene extending zombie.tscn.
# ============================================================
extends Node   # will be set_script-injected onto a zombie node


const GLOW_COLOR : Color = Color(0.2, 1.0, 0.5)

func _apply_glow(zombie: Node) -> void:
	if not (zombie is Node3D): return
	# Override all mesh materials to glow
	for mi in (zombie as Node3D).find_children("*", "MeshInstance3D", true, false):
		if not (mi is MeshInstance3D): continue
		var mat := (mi as MeshInstance3D).get_active_material(0)
		if mat is StandardMaterial3D:
			var gmat := mat.duplicate() as StandardMaterial3D
			gmat.emission_enabled = true
			gmat.emission         = GLOW_COLOR * 1.5
			(mi as MeshInstance3D).material_override = gmat
	# Scale up slightly
	(zombie as Node3D).scale = Vector3.ONE * 1.15


static func make_glowing(zombie: Node) -> void:
	zombie.add_to_group("glowing_zombie")
	zombie.set_meta("is_glowing", true)
	# Boost stats
	if "max_health" in zombie: zombie.set("max_health", float(zombie.get("max_health")) * 2.5)
	if "health"     in zombie: zombie.set("health",     float(zombie.get("health"))     * 2.5)
	if "damage"     in zombie: zombie.set("damage",     float(zombie.get("damage"))     * 1.5)
	if "gold_reward" in zombie: zombie.set("gold_reward", int(zombie.get("gold_reward")) * 3)
	# Connect death signal to drop sword charge
	if zombie.has_signal("died"):
		zombie.died.connect(func(): _on_glowing_died(zombie))
	elif zombie.has_signal("tree_exiting"):
		zombie.tree_exiting.connect(func(): _on_glowing_died(zombie))


static func _on_glowing_died(zombie: Node) -> void:
	if not is_instance_valid(zombie): return
	var pos : Vector3 = zombie.global_position if zombie is Node3D else Vector3.ZERO
	# Recharge nearest player's sword
	var closest_player : Node = null
	var closest_dist   : float = 30.0
	for player in zombie.get_tree().get_nodes_in_group("players"):
		if player is Node3D:
			var d := pos.distance_to((player as Node3D).global_position)
			if d < closest_dist:
				closest_dist   = d
				closest_player = player
	if is_instance_valid(closest_player) and closest_player.has_method("recharge_sword"):
		closest_player.recharge_sword(50.0)
	# Also give ult charge
	if is_instance_valid(closest_player) and "ult_charge" in closest_player:
		closest_player.set("ult_charge", minf(
			float(closest_player.get("ult_charge")) + 40.0,
			float(closest_player.get("ult_charge_max"))))
	# HUD announcement
	for hud in zombie.get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("✨ Rare zombie! Sword recharged!", Color(0.3, 1.0, 0.6))
	print("[GlowingZombie] Rare zombie killed — sword recharged for nearest player")
