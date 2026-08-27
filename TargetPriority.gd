class_name TargetPriority
extends RefCounted

## Single, shared target-priority scorer for zombie.gd. Replaces two
## previously-independent, inconsistently-tuned implementations
## (_find_best_target, used only by squad-order AI modes, and _find_blocker,
## used only by the default lane-march AI) with one rule: players > units
## blocking the path > turrets > base. Pure function -- takes plain data in,
## returns plain data out, no Node-tree/get_tree() coupling -- so any other
## creep script (e.g. bosszombie.gd, which currently has its own separate
## copy of this same logic) could reuse it later without inheriting anything.
##
## Priority-1/2/3 candidates are scored the same way: closer + weaker wins.
## The unit-engage range and LOS requirement are the two places the old
## implementations disagreed with each other (_find_best_target had no LOS
## check and a flat non-hysteresis engage range; _find_blocker had both) --
## this always applies the more complete/correct behavior from whichever
## side had it, for both callers.

static func select(
	self_node: Node3D,
	team_id: int,
	is_boss: bool,
	aggro_range: float,
	engage_range: float,          # BLOCKER_RANGE or BLOCKER_RANGE_EXIT -- caller resolves the hysteresis choice
	require_cone: bool,
	forward_dir: Vector3,
	cone_dot: float,
	require_los: bool,
	los_check: Callable,          # Callable(Node3D) -> bool, e.g. self._has_line_of_sight
	players: Array,
	units: Array,
	turrets: Array,
	unreachable_blacklist: Dictionary,
	enemy_base: Node3D
) -> Dictionary:

	var from_pos : Vector3 = self_node.global_position
	var result := {"target": null, "target_type": ""}

	# ============================================================
	# PRIORITY 1 — PLAYERS
	# ============================================================
	var combat_range : float = aggro_range * (1.4 if is_boss else 1.0)
	var best_player : Node3D = null
	var best_player_score : float = -INF

	for p in players:
		if not is_instance_valid(p) or not (p is Node3D) or p == self_node: continue
		if "team_id" in p and int(p.get("team_id")) == team_id: continue
		if unreachable_blacklist.has(p.get_instance_id()): continue

		var pd : float = from_pos.distance_to((p as Node3D).global_position)
		if pd > combat_range: continue
		if not _passes_cone(from_pos, (p as Node3D).global_position, require_cone, forward_dir, cone_dot):
			continue
		if require_los and los_check.is_valid() and not los_check.call(p):
			continue

		var pscore : float = 10000.0 - pd * 25.0
		if "health" in p and "max_health" in p:
			var hp_pct : float = float(p.get("health")) / maxf(float(p.get("max_health")), 1.0)
			pscore += (1.0 - hp_pct) * 500.0
		if p.has_method("get_target") and p.get_target() == self_node:
			pscore += 250.0

		if pscore > best_player_score:
			best_player_score = pscore
			best_player = p as Node3D

	if is_instance_valid(best_player):
		result.target = best_player
		result.target_type = "player"
		return result

	# ============================================================
	# PRIORITY 2 — UNITS (only ones actually blocking the path; melee-range only)
	# ============================================================
	var best_unit : Node3D = null
	var best_unit_score : float = -INF

	for u in units:
		if not is_instance_valid(u) or not (u is Node3D) or u == self_node: continue
		if "team_id" in u and int(u.get("team_id")) == team_id: continue
		if "is_dead" in u and u.get("is_dead") == true: continue
		if unreachable_blacklist.has(u.get_instance_id()): continue

		var ud : float = from_pos.distance_to((u as Node3D).global_position)
		if ud > engage_range: continue
		if not _passes_cone(from_pos, (u as Node3D).global_position, require_cone, forward_dir, cone_dot):
			continue
		if require_los and los_check.is_valid() and not los_check.call(u):
			continue

		var uscore : float = 3000.0 - ud * 30.0
		if "health" in u and "max_health" in u:
			var uhp_pct : float = float(u.get("health")) / maxf(float(u.get("max_health")), 1.0)
			uscore += (1.0 - uhp_pct) * 300.0
		if u.has_method("get_target") and u.get_target() == self_node:
			uscore += 500.0

		if uscore > best_unit_score:
			best_unit_score = uscore
			best_unit = u as Node3D

	if is_instance_valid(best_unit):
		result.target = best_unit
		result.target_type = "unit"
		return result

	# ============================================================
	# PRIORITY 3 — TURRETS (any living enemy turret, no range cap, LOS-gated
	# so a turret behind a wall isn't committed to before it's reachable)
	# ============================================================
	var best_turret : Node3D = null
	var best_turret_score : float = -INF

	for t in turrets:
		if not is_instance_valid(t) or not (t is Node3D): continue
		if "team_id" in t and int(t.get("team_id")) == team_id: continue
		if "is_dead" in t and t.get("is_dead") == true: continue
		if "health" in t and float(t.get("health")) <= 0.0: continue

		if require_los and los_check.is_valid() and not los_check.call(t):
			continue

		var td : float = from_pos.distance_to((t as Node3D).global_position)
		var tscore : float = 1000.0 - td * 10.0
		if tscore > best_turret_score:
			best_turret_score = tscore
			best_turret = t as Node3D

	if is_instance_valid(best_turret):
		result.target = best_turret
		result.target_type = "turret"
		return result

	# ============================================================
	# PRIORITY 4 — BASE (always reachable once no closer player/unit/turret
	# exists -- NOT gated on turret count)
	#
	# REAL BUG FIX (2026-08-24): this used to fully block base-targeting
	# while ANY friendly turret was alive, on the assumption that
	# basenode.gd's take_damage() gave the base 100% immunity in that case
	# (an OLD, stale assumption inherited unchanged from the original
	# _find_best_target()/_find_blocker() this class replaced -- carried
	# forward without re-checking it). basenode.gd's actual CURRENT
	# take_damage() (already fixed in an earlier session, "Base invulnerable
	# with any turret alive") only applies a PARTIAL, capped shield (20% per
	# living turret, capped at 75% -- see basenode.gd:769-796), never full
	# immunity. Since game_phase_script.gd spawns 4 starting turrets every
	# round 1, the old "any turret alive = fully blocked" gate meant NO
	# zombie ever even tried to attack the base for most of every match --
	# not "turrets make the base tanky", but "zombies can't hurt the base
	# at all" (a real, reported symptom). Base is now always a valid
	# (lowest-priority) target; the damage-side partial shield is where
	# turret-count risk-scaling actually belongs.
	# ============================================================
	if is_instance_valid(enemy_base):
		result.target = enemy_base
		result.target_type = "base"

	return result


static func _passes_cone(from_pos: Vector3, target_pos: Vector3, require_cone: bool, forward_dir: Vector3, cone_dot: float) -> bool:
	if not require_cone: return true
	if forward_dir.length_squared() <= 0.01: return true
	var diff : Vector3 = target_pos - from_pos
	diff.y = 0.0
	if diff.length_squared() <= 0.01: return true
	return diff.normalized().dot(forward_dir) >= cone_dot
