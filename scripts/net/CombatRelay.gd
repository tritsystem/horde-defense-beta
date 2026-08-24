# ============================================================
# CombatRelay.gd — AUTOLOAD
# Phase 2 of the multiplayer plan (see
# C:\Users\gbran\.claude\plans\reactive-sparking-finch.md).
#
# The real gap this closes: basegun.gd/rocket.gd/flamethrower.gd/
# lazerprojectile.gd all gate real damage behind
# "multiplayer.is_server() or not multiplayer.has_multiplayer_peer()"
# but nothing ever relayed a non-host client's hits to the server --
# so a client that isn't the host has always dealt zero damage.
#
# Design: client reports what it hit; server independently re-derives
# whether that's plausible (owns the shooter, not same team, within
# range) and computes damage from its OWN weapon data -- never trusts
# a client-supplied damage number. This is PvE co-op, so the point
# isn't anti-cheat hardening, it's world-state consistency: one true
# zombie/egg/hive HP that all 4 players see identically.
# ============================================================
extends Node

const MAX_RANGE := 60.0  # generous slack over real weapon ranges -- catches wall/teleport bugs, not tight lag comp


@rpc("any_peer", "call_remote", "reliable")
func request_hit(shooter_path: NodePath, target_path: NodePath, weapon_path: NodePath,
				  hit_pos: Vector3, hit_normal: Vector3, limb_id: String) -> void:
	if not multiplayer.is_server(): return
	var sender_id := multiplayer.get_remote_sender_id()

	var shooter := get_node_or_null(shooter_path)
	if not is_instance_valid(shooter):
		push_warning("[CombatRelay] request_hit: shooter not found at %s" % str(shooter_path)); return
	if int(shooter.get_multiplayer_authority()) != sender_id:
		push_warning("[CombatRelay] request_hit: peer %d claimed a hit for a player it doesn't own" % sender_id)
		return

	var target := get_node_or_null(target_path)
	var weapon := get_node_or_null(weapon_path)
	if not is_instance_valid(target) or not is_instance_valid(weapon): return
	if not target.has_method("take_damage"): return

	if "team_id" in target and "team_id" in shooter and int(target.get("team_id")) == int(shooter.get("team_id")):
		return  # friendly fire rejected

	if shooter is Node3D and target is Node3D:
		if (shooter as Node3D).global_position.distance_to((target as Node3D).global_position) > MAX_RANGE:
			push_warning("[CombatRelay] request_hit: peer %d reported a hit beyond MAX_RANGE" % sender_id)
			return

	# Different weapon scripts name their per-hit damage field differently
	# (basegun.gd/rocket.gd/lazerprojectile.gd use "damage",
	# flamethrower.gd uses "damage_per_tick") -- check both rather than
	# rename an existing gameplay-balance field just for this.
	var dmg : float = 10.0
	if "damage" in weapon: dmg = float(weapon.get("damage"))
	elif "damage_per_tick" in weapon: dmg = float(weapon.get("damage_per_tick"))
	if shooter.has_method("get_damage_multiplier"):
		dmg *= float(shooter.get_damage_multiplier())
	if limb_id == "head":
		dmg *= 2.0

	target.take_damage(dmg, shooter)


@rpc("any_peer", "call_remote", "reliable")
func request_explosion(shooter_path: NodePath, weapon_path: NodePath, center: Vector3,
						radius: float) -> void:
	if not multiplayer.is_server(): return
	var sender_id := multiplayer.get_remote_sender_id()

	var shooter := get_node_or_null(shooter_path)
	if not is_instance_valid(shooter):
		push_warning("[CombatRelay] request_explosion: shooter not found at %s" % str(shooter_path)); return
	if int(shooter.get_multiplayer_authority()) != sender_id:
		push_warning("[CombatRelay] request_explosion: peer %d claimed an explosion for a player it doesn't own" % sender_id)
		return

	var weapon := get_node_or_null(weapon_path)
	var base_dmg : float = float(weapon.get("explosion_damage")) if is_instance_valid(weapon) and "explosion_damage" in weapon else 50.0

	# AoE victim list is NOT trusted from the client -- re-derive it server-side.
	var space := get_tree().root.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	q.shape = sphere
	q.transform = Transform3D(Basis(), center)
	q.collide_with_areas = true

	for hit in space.intersect_shape(q, 32):
		var body : Object = hit.collider
		if not (body is Node) or not body.has_method("take_damage"): continue
		if "team_id" in body and "team_id" in shooter and int(body.get("team_id")) == int(shooter.get("team_id")):
			continue
		if not (body is Node3D): continue
		var dist : float = center.distance_to((body as Node3D).global_position)
		var falloff : float = clampf(1.0 - dist / radius, 0.0, 1.0)
		if falloff <= 0.0: continue
		body.take_damage(base_dmg * falloff, shooter)
