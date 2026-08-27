class_name HiveCluster
extends Node3D
# ============================================================
# HiveCluster.gd — one nest: hive structure + patrol guards + eggs.
#
# Performance design:
#   - _process is removed entirely. Guard LOD runs every 2 s via a
#     SceneTreeTimer chain — no per-frame cost for 8-12 clusters.
#   - Guards use PROCESS_MODE_DISABLED when >LOD_GUARD_DIST from camera.
#
# Wave mechanism: eggs ARE the wave source. On hatch they spawn creeps
# at their world position. The hive spawns a fresh egg after a delay.
# ============================================================

@export var tier              : int   = 1
@export var hive_hp           : float = 500.0
@export var patrol_count      : int   = 2
@export var max_eggs          : int   = 2
@export var egg_spawn_interval: float = 60.0
@export var egg_hatch_time    : float = 60.0
@export var egg_wave_size     : int   = 6
@export var patrol_radius     : float = 16.0
# REAL FEATURE ADD (2026-07-21): "higher tier eggs should have higher level
# turrets defending them" -- turret_count/turret_level, set per-tier by
# HiveNestManager, same pattern as patrol_count/hive_hp above.
@export var turret_count      : int   = 0
@export var turret_level      : int   = 1

# Set by HiveNestManager before adding to tree
var attack_target : Node3D = null
var creep_pool    : Array  = ["zombie"]

signal cluster_cleared

var health : float = 0.0

var _cleared       : bool  = false
# REAL BUG FIX: "can't kill hive, each hit after 0 health spawns more" --
# take_damage()'s only re-entry guard was `if _cleared: return`, but
# _cleared only becomes true once _check_cleared() ALSO sees the
# cluster's eggs empty (see that function). A hive with health<=0 but a
# still-alive/hatching egg would hit take_damage() again on every further
# shot and re-run the FULL _on_hive_killed() retaliation burst every
# single time -- an ever-growing flood of zombies instead of the nest
# being dead. This flag gates the kill-transition itself, independent of
# whether eggs happen to still be around.
var _hive_killed   : bool  = false
var _patrol_units  : Array = []
var _eggs          : Array = []
var _hive_mat      : StandardMaterial3D = null

var _hp_bar_root : Node3D             = null
var _hp_fill_mi  : MeshInstance3D     = null
var _hp_fill_mat : StandardMaterial3D = null
var _hp_label    : Label3D            = null

const GUARD_SCENE  := "res://zombie/zombie.tscn"

# REAL BUG FIX (2026-07-25): "eggs and nests spawning in air" -- every
# ground raycast in this file masks to collision layer 1 expecting it to be
# terrain-only, but basenode.gd's procedural castle walls/towers never set
# an explicit collision_layer, so they land on that SAME default layer 1
# (the identical conflict already fixed for zombie ground-snap/LaneSpawner).
# Cache every base's structure body RIDs once and exclude them from every
# raycast below so they actually find real ground instead of a wall/tower top.
var _structure_exclude : Array[RID] = []

func _build_structure_exclude() -> void:
	_structure_exclude.clear()
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b):
			_collect_body_rids_recursive(b, _structure_exclude)

func _collect_body_rids_recursive(node: Node, rids: Array[RID]) -> void:
	if node is PhysicsBody3D:
		rids.append((node as PhysicsBody3D).get_rid())
	for c in node.get_children():
		_collect_body_rids_recursive(c, rids)


func _ready() -> void:
	health = hive_hp
	_build_hive_structure()
	add_to_group("hive_clusters")
	call_deferred("_deferred_init")


func _deferred_init() -> void:
	_build_structure_exclude()
	_snap_to_ground()
	# Phase 4 of the multiplayer plan: on a non-host client this HiveCluster
	# is itself a replicated mirror (spawned via HiveNestManager's
	# spawn_function -- see HiveNestManager.gd's _spawn_cluster_from_data).
	# Guards/turrets/eggs must only ever be created once, by the server, and
	# reach clients via their own replication -- a client independently
	# running this same spawning logic on its local mirror would create a
	# second, divergent set nobody else sees. Structure/heart stay
	# unconditional: both are pure local visuals, deterministic from `tier`
	# alone, safe (and necessary) to build identically on every peer.
	if not (NetworkManager.is_networked and not multiplayer.is_server()):
		_spawn_initial_eggs()
		_spawn_patrol_guards()
		_spawn_defense_turrets()
	_spawn_hive_heart()


func _get_camera_pos() -> Vector3:
	var vp := get_viewport()
	if vp:
		var cam := vp.get_camera_3d()
		if is_instance_valid(cam): return cam.global_position
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node3D: return (p as Node3D).global_position
	return global_position


# ── Ground-snapping ──────────────────────────────────────────
func _snap_to_ground() -> void:
	var space := get_world_3d().direct_space_state
	var ray   := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 120.0,
		global_position + Vector3.DOWN * 60.0)
	ray.collision_mask = 1
	ray.exclude = _structure_exclude
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		global_position.y = hit.position.y


# ── Hive structure ───────────────────────────────────────────
func _build_hive_structure() -> void:
	var r : float = 2.0 + tier * 0.55

	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = r; mesh.height = r * 1.35
	mi.mesh = mesh
	_hive_mat = StandardMaterial3D.new()
	_hive_mat.albedo_color = Color(0.08, 0.42, 0.08).lerp(Color(0.26, 0.04, 0.30), float(tier - 1) / 4.0)
	_hive_mat.roughness    = 0.88
	mi.material_override   = _hive_mat
	mi.position.y          = r * 0.5
	add_child(mi)

	var body  := StaticBody3D.new()
	var coll  := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius    = r
	coll.shape      = shape
	body.position.y = r * 0.5
	body.add_child(coll)
	add_child(body)
	body.add_to_group("hive_structures")

	_build_glow_ring(r)
	_build_tier_label(tier, r)
	_build_hp_display(r)


func _build_glow_ring(r: float) -> void:
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = r + 0.15
	mesh.outer_radius = r + 0.60
	ring.mesh = mesh
	var mat := StandardMaterial3D.new()
	var col  : Color = Color(0.2, 1.0, 0.2).lerp(Color(0.8, 0.0, 1.0), float(tier - 1) / 4.0)
	mat.albedo_color     = Color(col.r, col.g, col.b, 0.55)
	mat.emission_enabled = true
	mat.emission         = col * 0.9
	mat.transparency     = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = mat
	ring.position.y      = 0.06
	# REAL PERF FIX (2026-07-23): alpha-blended emissive rings casting
	# shadows is both wasted GPU cost and visually wrong (a glow ring
	# shouldn't occlude light) -- with up to 8 clusters active this adds up.
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)


func _build_tier_label(t: int, r: float) -> void:
	var label := Label3D.new()
	label.text          = "T%d" % t
	label.font_size     = 48
	label.modulate      = Color(1.0, 0.9, 0.3)
	label.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position.y    = r * 1.4 + 1.2
	add_child(label)


func _build_hp_display(r: float) -> void:
	var bar_y : float = r * 1.4 + 2.6

	_hp_bar_root = Node3D.new()
	_hp_bar_root.position.y = bar_y
	add_child(_hp_bar_root)

	# HP number
	_hp_label = Label3D.new()
	_hp_label.text         = "%d / %d" % [int(hive_hp), int(hive_hp)]
	_hp_label.font_size    = 28
	_hp_label.modulate     = Color(1.0, 0.85, 0.85, 1.0)
	_hp_label.billboard    = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.no_depth_test = true
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.position.y   = 0.38
	_hp_bar_root.add_child(_hp_label)

	var bar_w : float = 2.2
	var bar_h : float = 0.18

	# Background
	var bg_mi   := MeshInstance3D.new()
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(bar_w, bar_h)
	bg_mi.mesh = bg_mesh
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color   = Color(0.1, 0.1, 0.1, 0.9)
	bg_mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.no_depth_test  = true
	bg_mi.material_override = bg_mat
	bg_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hp_bar_root.add_child(bg_mi)

	# Fill
	_hp_fill_mi       = MeshInstance3D.new()
	var fill_mesh     := QuadMesh.new()
	fill_mesh.size     = Vector2(bar_w, bar_h)
	_hp_fill_mi.mesh   = fill_mesh
	_hp_fill_mat       = StandardMaterial3D.new()
	_hp_fill_mat.albedo_color   = Color(0.2, 0.8, 0.2)
	_hp_fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hp_fill_mat.no_depth_test  = true
	_hp_fill_mi.material_override = _hp_fill_mat
	_hp_fill_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hp_bar_root.add_child(_hp_fill_mi)


func _update_hp_display() -> void:
	if not is_instance_valid(_hp_label): return
	var h   : float = maxf(0.0, health)
	var pct : float = clampf(h / hive_hp, 0.0, 1.0)
	_hp_label.text = "%d / %d" % [int(h), int(hive_hp)]
	if is_instance_valid(_hp_fill_mi):
		_hp_fill_mi.scale.x    = pct
		_hp_fill_mi.position.x = (pct - 1.0) * 1.1
	if is_instance_valid(_hp_fill_mat):
		_hp_fill_mat.albedo_color = (
			Color(0.2, 0.8, 0.2).lerp(Color(0.9, 0.8, 0.0), (1.0 - pct) * 2.0)
			if pct > 0.5 else
			Color(0.9, 0.8, 0.0).lerp(Color(0.85, 0.1, 0.05), (0.5 - pct) * 2.0)
		)


# ── Eggs ─────────────────────────────────────────────────────
func _spawn_initial_eggs() -> void:
	for _i in max_eggs:
		_spawn_single_egg()


func _spawn_single_egg() -> void:
	if _cleared: return
	if _eggs.size() >= max_eggs: return

	var space := get_world_3d().direct_space_state
	var angle : float   = randf() * TAU
	var dist  : float   = patrol_radius * 0.42 + randf() * 3.5
	var wpos  : Vector3 = global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)

	var ray := PhysicsRayQueryParameters3D.create(
		wpos + Vector3.UP * 60.0, wpos + Vector3.DOWN * 30.0)
	ray.collision_mask = 1
	ray.exclude = _structure_exclude
	var hit := space.intersect_ray(ray)
	if not hit.is_empty(): wpos.y = hit.position.y

	# REAL BUG FIX (2026-08-24): "make build up of zombies more gradual" --
	# _spawn_initial_eggs() creates every one of this hive's max_eggs eggs
	# in the SAME frame, and every egg got the exact same, unjittered
	# egg_hatch_time -- so all of them hatch (and dump a full wave each) at
	# EXACTLY the same moment, every time. With multiple hives active at
	# once (a whole tier's worth, see game_phase_script.gd::_activate_tier),
	# that's several synchronized bursts landing simultaneously, which is
	# what actually reads as "sudden"/"steep" rather than gradual -- not
	# the total zombie count over time, just how it's clumped in time.
	# Staggering each egg's own hatch moment spreads the identical total
	# out into a real ramp instead of a burst, without touching any of the
	# tier/wave-size/unit-cap balancing elsewhere.
	var jittered_hatch_time : float = egg_hatch_time + randf_range(0.0, egg_hatch_time * 0.6)

	# Networked: only ever reached on the server (see _deferred_init's gate),
	# since a client's own local HiveCluster mirror never calls this. Route
	# through HiveNestManager's replicated egg spawner instead of
	# constructing locally, so every peer gets the same Egg at the same
	# position -- see HiveNestManager.gd's spawn_networked_egg/
	# _spawn_egg_from_data, which calls back into _on_networked_egg_spawned
	# below (on every peer) to finish wiring this cluster's own bookkeeping.
	if NetworkManager.is_networked:
		var hnm := get_tree().get_first_node_in_group("hive_nest_manager")
		if is_instance_valid(hnm):
			hnm.spawn_networked_egg({
				"tier": tier, "max_hp": 55.0 + tier * 22.0, "hatch_time": jittered_hatch_time,
				"wave_size": egg_wave_size, "creep_ids": creep_pool.duplicate(),
				"position": wpos, "owner_cluster_path": get_path(),
			})
		return

	var egg := Egg.new()
	egg.tier          = tier
	egg.max_hp        = 55.0 + tier * 22.0
	egg.hatch_time    = jittered_hatch_time
	egg.wave_size     = egg_wave_size
	egg.attack_target = attack_target
	egg.creep_ids     = creep_pool.duplicate()
	get_tree().current_scene.add_child(egg)
	egg.global_position = wpos
	egg.hatched.connect(_on_egg_gone)
	egg.egg_destroyed.connect(_on_egg_gone)
	_eggs.append(egg)


## Called by HiveNestManager._spawn_egg_from_data on every peer once a
## networked egg (requested via _spawn_single_egg's networked branch above)
## has been constructed -- finishes the same bookkeeping the local path
## does inline (_eggs tracking, hatched/egg_destroyed signal wiring).
func _on_networked_egg_spawned(egg: Egg) -> void:
	if not is_instance_valid(egg): return
	egg.hatched.connect(_on_egg_gone)
	egg.egg_destroyed.connect(_on_egg_gone)
	_eggs.append(egg)


# ── Patrol guards ─────────────────────────────────────────────
const PATROL_RETRY_INTERVAL : float = 4.0
const PATROL_RETRY_MAX      : int   = 15   # ~1 min of retrying before giving up
var _patrol_retry_count : int = 0

func _spawn_patrol_guards() -> void:
	_spawn_patrol_guards_batch(patrol_count)


## REAL BUG FIX: "LOD logic overrides zombies and disables far spawns".
## Previously this loop just `break`d the instant ZombieHordeManager's
## Zone-1 cap (ZONE1_MAX) was full and never tried again -- since this
## only ever ran once from _deferred_init(), a hive that happened to
## initialize while the player was already fighting 60 zombies elsewhere
## lost its patrol guards PERMANENTLY, with zero guards ever spawning at
## that hive again. The cap itself is a deliberate, measured perf limit
## (see register_z1's own note) and shouldn't be raised -- what was
## actually missing is a retry: spawn however many slots are free now,
## and reschedule the remainder for when slots open back up.
func _spawn_patrol_guards_batch(remaining: int) -> void:
	if remaining <= 0: return
	if not is_instance_valid(self) or not is_inside_tree(): return
	if not ResourceLoader.exists(GUARD_SCENE):
		push_warning("[HiveCluster] Guard scene not found: %s" % GUARD_SCENE)
		return

	var packed : PackedScene      = load(GUARD_SCENE)
	var circle : Array[Vector3]   = _patrol_circle(global_position, patrol_radius, max(8, patrol_count * 2))
	var space                     := get_world_3d().direct_space_state
	var zhm                       := get_node_or_null("/root/ZombieHordeManager")
	var spawned_this_batch : int  = 0
	var already_spawned : int     = _patrol_units.size()   # offset so retries continue the same evenly-spaced circle

	for i in remaining:
		if is_instance_valid(zhm) and zhm.has_method("can_register_z1") and not zhm.can_register_z1():
			break
		# Angle divides by the ORIGINAL patrol_count (not `remaining`), offset
		# by how many already spawned in earlier batches -- otherwise each
		# retry batch would recompute its own fresh 0..TAU spacing and guards
		# from different batches would clump instead of ringing the hive evenly.
		var angle     : float   = (float(already_spawned + spawned_this_batch) / float(patrol_count)) * TAU
		var spawn_pos : Vector3 = global_position + Vector3(
			cos(angle) * patrol_radius * 0.6, 0.5, sin(angle) * patrol_radius * 0.6)

		var ray := PhysicsRayQueryParameters3D.create(
			spawn_pos + Vector3.UP * 30.0, spawn_pos + Vector3.DOWN * 15.0)
		ray.collision_mask = 1
		ray.exclude = _structure_exclude
		var hit := space.intersect_ray(ray)
		if not hit.is_empty(): spawn_pos.y = hit.position.y + 0.3

		var guard : Node = packed.instantiate()
		if not is_instance_valid(guard): continue

		if "team_id"        in guard: guard.set("team_id",        2)
		if "max_health"     in guard: guard.set("max_health",     180.0 + tier * 90.0)
		if "health"         in guard: guard.set("health",         180.0 + tier * 90.0)
		if "move_speed"     in guard: guard.set("move_speed",     2.8   + tier * 0.3)
		if "damage"         in guard: guard.set("damage",         12.0  + tier * 9.0)
		if "gold_reward"    in guard: guard.set("gold_reward",    15    + tier * 8)
		if "detection_range" in guard: guard.set("detection_range", 30.0 + tier * 3.0)
		if "patrol_points"  in guard: guard.set("patrol_points",  circle)
		# REAL BUG FIX: "patrol guards run the opposite way off spawn and
		# never settle down". Every guard at this hive shares the exact
		# same `circle` array, but zombie.gd's own _patrol_idx always
		# defaults to 0 -- so regardless of which angle a given guard
		# actually spawned at (each gets a different one, see `angle`
		# above), it beelines for circle[0] first, then just oscillates
		# near that one shared point forever instead of patrolling its
		# own local arc. Start each guard at whichever point is actually
		# closest to where it spawned.
		if "_patrol_idx" in guard and not circle.is_empty():
			var nearest_idx : int = 0
			var nearest_d2  : float = INF
			for ci in circle.size():
				var d2 : float = spawn_pos.distance_squared_to(circle[ci])
				if d2 < nearest_d2: nearest_d2 = d2; nearest_idx = ci
			guard.set("_patrol_idx", nearest_idx)
		if is_instance_valid(attack_target):
			if "enemy_base"   in guard: guard.set("enemy_base",   attack_target)
			if "friendly_base" in guard: guard.set("friendly_base", self)

		# Networked: only ever reached on the server (see _deferred_init's
		# gate). Route through PurchaseRelay's own replicated spawn root
		# instead of current_scene -- it's the same generic "server spawns a
		# real PackedScene, MultiplayerSpawner replicates it" mechanism
		# purchased creeps/turrets already use, reused here rather than
		# standing up a parallel spawner just for hive guards.
		if NetworkManager.is_networked:
			PurchaseRelay.register_scene(packed)
			PurchaseRelay.spawn_root().add_child(guard, true)
		else:
			get_tree().current_scene.add_child(guard)
		guard.global_position = spawn_pos

		# REAL BUG FIX (2026-07-25): setting ai_mode directly has no effect --
		# the zombie's own _tick_full() only dispatches on ai_mode when a real
		# squad_order is active; with none, every guard just fell through to
		# the default LANE_PUSH march and left the hive instead of patrolling.
		# command_patrol() sets both squad_order and ai_mode together, and
		# marks it persistent so it doesn't expire after 1s like a normal
		# player-issued order.
		if guard.has_method("command_patrol"): guard.call("command_patrol", true)

		# Register with ZHM for LOD + player/neighbor push
		if is_instance_valid(zhm) and guard is CharacterBody3D:
			zhm.register_z1(guard as CharacterBody3D)

		_patrol_units.append(guard)
		spawned_this_batch += 1

	var still_missing : int = patrol_count - _patrol_units.size()
	if still_missing > 0 and _patrol_retry_count < PATROL_RETRY_MAX:
		_patrol_retry_count += 1
		get_tree().create_timer(PATROL_RETRY_INTERVAL).timeout.connect(
			_spawn_patrol_guards_batch.bind(still_missing))


# ── Defense turrets (higher tier = more, stronger) ────────────
const TURRET_SCENE := "res://scenes/fire_turret.tscn"

func _spawn_defense_turrets() -> void:
	if turret_count <= 0: return
	if not ResourceLoader.exists(TURRET_SCENE):
		push_warning("[HiveCluster] Turret scene not found: %s" % TURRET_SCENE)
		return

	var packed : PackedScene = load(TURRET_SCENE)
	var space  := get_world_3d().direct_space_state

	for i in turret_count:
		var angle     : float   = (float(i) / float(turret_count)) * TAU + (TAU / (turret_count * 2.0))
		var spawn_pos : Vector3 = global_position + Vector3(
			cos(angle) * patrol_radius * 0.85, 0.5, sin(angle) * patrol_radius * 0.85)

		var ray := PhysicsRayQueryParameters3D.create(
			spawn_pos + Vector3.UP * 30.0, spawn_pos + Vector3.DOWN * 15.0)
		ray.collision_mask = 1
		ray.exclude = _structure_exclude
		var hit := space.intersect_ray(ray)
		if not hit.is_empty(): spawn_pos.y = hit.position.y

		var turret : Node = packed.instantiate()
		if not is_instance_valid(turret): continue

		if "team_id" in turret: turret.set("team_id", 2)
		if "hostile_to_players" in turret: turret.set("hostile_to_players", true)

		# Networked: same PurchaseRelay-spawn-root reuse as guards above.
		if NetworkManager.is_networked:
			PurchaseRelay.register_scene(packed)
			PurchaseRelay.spawn_root().add_child(turret, true)
		else:
			get_tree().current_scene.add_child(turret)
		if turret is Node3D: (turret as Node3D).global_position = spawn_pos

		# Scale it to turret_level via the turret's own real upgrade() path
		# (same stat scaling player-owned turrets use), not a stat hack.
		if turret.has_method("upgrade"):
			for _lvl in range(turret_level - 1):
				turret.call("upgrade")


func _patrol_circle(center: Vector3, radius: float, points: int) -> Array[Vector3]:
	var result : Array[Vector3] = []
	for i in points:
		var a : float = (float(i) / float(points)) * TAU
		result.append(center + Vector3(cos(a) * radius, 0.0, sin(a) * radius))
	return result


# ── Damage ────────────────────────────────────────────────────
# Phase 4 of the multiplayer plan: CombatRelay only ever calls
# take_damage() on the server's own copy of a target (see basegun.gd's
# authority-gated resolve-locally-or-relay branch) -- this guard is
# defensive insurance matching Phase 3's convention, not a path any
# existing caller currently reaches. Health changes are mirrored to
# every peer's own replicated HiveCluster (same NodePath, kept in sync
# by the spawn_function spawner) via rpc_sync_health, and an early
# death (before _cleared naturally follows on every peer already) via
# rpc_hive_destroyed -- without these, a non-host client's own local
# mirror would never visually react to damage the server resolved.
func take_damage(amount: float, _source = null) -> void:
	if NetworkManager.is_networked and not multiplayer.is_server(): return
	if _cleared: return
	health -= amount
	_apply_damage_visual()
	if NetworkManager.is_networked:
		rpc_sync_health.rpc(health)
	if health <= 0.0 and not _hive_killed:
		_hive_killed = true
		_on_hive_killed()
		if NetworkManager.is_networked:
			rpc_hive_destroyed.rpc()


func _apply_damage_visual() -> void:
	if is_instance_valid(_hive_mat):
		var ratio : float = clampf(health / hive_hp, 0.0, 1.0)
		_hive_mat.albedo_color = _hive_mat.albedo_color.lerp(Color(0.9, 0.08, 0.04), (1.0 - ratio) * 0.55)
	_update_hp_display()


@rpc("authority", "call_remote", "reliable")
func rpc_sync_health(new_health: float) -> void:
	health = new_health
	_apply_damage_visual()


## Client-side mirror of an early (damage) death -- the natural
## cluster_cleared path (health hits 0 with no eggs left) doesn't need
## this since egg state syncs independently, but a hive killed by direct
## damage while eggs are still alive needs an explicit signal so guards
## switch to ATTACK and the retaliation burst plays on every peer, not
## just the server. Skips _spawn_extra_zombies (already server-gated,
## see that function) and re-running gold award (also server-only in
## intent, though currently inert everywhere -- see _award_gold's note).
@rpc("authority", "call_remote", "reliable")
func rpc_hive_destroyed() -> void:
	if _hive_killed: return   # defensive -- see take_damage()'s own guard
	_hive_killed = true
	if health > 0.0: health = 0.0
	_apply_damage_visual()
	for g in _patrol_units:
		if is_instance_valid(g) and "ai_mode" in g:
			g.set("ai_mode", 1)
	_reveal_on_map(60.0)
	_check_cleared()


func _on_hive_killed() -> void:
	print("[Hive T%d] Hive destroyed!" % tier)
	for g in _patrol_units:
		if is_instance_valid(g) and "ai_mode" in g:
			g.set("ai_mode", 1)   # AIMode.ATTACK — guards assault after hive dies
	# REAL FIX (2026-07-25): egg destruction already spawns a retaliation burst
	# (Egg.gd take_damage(), wave_size*3 + (tier-1)*2), but destroying the
	# whole nest/hive itself spawned nothing extra beyond surviving guards
	# switching to ATTACK — killing the nest was a free win with no
	# retaliation at all. Mirror the egg's retaliation scaling here using the
	# same _spawn_extra_zombies() helper the Hive Heart channel already uses.
	var retaliation_count : int = 6 + (tier - 1) * 3
	_spawn_extra_zombies(retaliation_count)
	_reveal_on_map(60.0)
	_check_cleared()


func _reveal_on_map(radius: float) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("reveal_minimap_area"):
			hud.call("reveal_minimap_area", global_position, radius)


func _on_egg_gone(egg: Node3D) -> void:
	_eggs.erase(egg)
	_check_cleared()
	if not _cleared and health > 0.0 and _eggs.size() < max_eggs:
		get_tree().create_timer(egg_spawn_interval).timeout.connect(_try_respawn_egg)


# REAL BUG FIX (2026-08-06): "zombies pool up far away and don't trigger
# until I get close, lots of zombies makes the game lag" -- eggs hatch
# unconditionally now regardless of player proximity (Egg.gd's 2026-07-25
# fix, so no egg stays dormant forever), but this cluster kept manufacturing
# a brand-new egg every egg_spawn_interval FOREVER, with zero regard for
# whether the player was anywhere near this nest. A tier-4/5 cluster the
# player hasn't reached yet would perpetually pump fresh full-cost hive_unit
# waves for the entire match, continuously refilling a far-away pool of
# zombies that just sit there marching toward the player base, unseen,
# eating the shared Zone-1 physics budget the whole time (see MAX_HIVE_UNITS'
# note in Egg.gd). Gate ongoing REGENERATION -- not the first-ever hatch,
# which must stay unconditional -- behind proximity: a distant nest's
# initial egg(s) still always hatch once, but it stops manufacturing new
# ones until the player is actually closing in on it. _get_camera_pos() was
# already defined above for exactly this kind of check but previously unused.
const EGG_RESPAWN_ACTIVATION_DIST : float = 220.0

func _try_respawn_egg() -> void:
	if _cleared or health <= 0.0 or _eggs.size() >= max_eggs:
		return
	if global_position.distance_to(_get_camera_pos()) > EGG_RESPAWN_ACTIVATION_DIST:
		get_tree().create_timer(10.0).timeout.connect(_try_respawn_egg)
		return
	_spawn_single_egg()


func _check_cleared() -> void:
	if _cleared: return
	if health > 0.0: return
	if not _eggs.is_empty(): return
	_cleared = true
	print("[Hive T%d] Cluster CLEARED — awarding gold" % tier)
	_award_gold()
	_spawn_trapped_ally()
	cluster_cleared.emit()
	get_tree().create_timer(3.0).timeout.connect(queue_free)


## Every cleared hive reveals one trapped ally of a random class, at the
## hive's own position, for the player to free by approaching (see
## team_ally.gd's _tick_trapped). Runs on every peer's own local
## _check_cleared() call (server via the normal flow, clients via
## rpc_hive_destroyed's mirror) -- same documented not-yet-networked v1
## scope cut as the starter Builder ally in game_phase_script.gd.
func _spawn_trapped_ally() -> void:
	var econ := get_tree().get_first_node_in_group("economy_controller")
	if not is_instance_valid(econ) or not econ.has_method("_spawn_team_ally"):
		print("[HiveCluster] _spawn_trapped_ally FAIL: econ valid=%s has_method=%s" % [
			str(is_instance_valid(econ)), str(is_instance_valid(econ) and econ.has_method("_spawn_team_ally"))])
		return
	var random_class : int = randi() % 3   # AllyClass.BUILDER/GUARD/SCOUT
	# `=` not `:=` -- econ is statically typed as Node, so calling a method
	# defined only on game_phase_script.gd's class through it is a dynamic/
	# duck-typed call with no statically-inferable return type; `:=` here
	# fails to compile the whole script (confirmed: broke hive placement
	# entirely, cascading into "Nonexistent function 'new' in base
	# 'GDScript'" everywhere HiveCluster.new() is called elsewhere).
	var ally = econ._spawn_team_ally(1, random_class, global_position, true, true)
	print("[HiveCluster] _spawn_trapped_ally: class=%d ally_valid=%s trapped=%s" % [
		random_class, str(is_instance_valid(ally)), str(ally.trapped if is_instance_valid(ally) else "n/a")])


func _award_gold() -> void:
	var gold : int = 40 * tier
	for p in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(p): continue
		if p.has_method("add_gold"):
			p.add_gold(gold)
		elif "gold" in p:
			p.set("gold", int(p.get("gold")) + gold)


# ── Hive Heart objective ─────────────────────────────────────
var _heart_node         : Node3D = null
var _heart_channeling   : bool   = false
var _heart_channel_time : float  = 0.0
const HEART_CHANNEL_DURATION : float = 20.0
const HEART_BUFF_DURATION    : float = 20.0

func _spawn_hive_heart() -> void:
	_heart_node = Node3D.new()
	_heart_node.global_position = global_position + Vector3(0.0, 1.5, 0.0)
	_heart_node.add_to_group("hive_heart")
	_heart_node.set_meta("cluster", self)

	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.55; mesh.height = 1.1
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.65, 0.0, 0.15)
	mat.emission_enabled = true
	mat.emission         = Color(1.0, 0.0, 0.2) * 0.9
	mi.material_override = mat
	_heart_node.add_child(mi)

	var lbl := Label3D.new()
	lbl.text = "❤ HIVE HEART\n[Hold F to channel]"
	lbl.font_size = 18; lbl.position.y = 1.2
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(1.0, 0.4, 0.4)
	_heart_node.add_child(lbl)

	add_child(_heart_node)


func try_channel_heart(player: Node, delta: float) -> void:
	if not is_instance_valid(_heart_node): return
	if _cleared: return
	if not (player is Node3D): return
	var dist : float = _heart_node.global_position.distance_to((player as Node3D).global_position)
	if dist > 3.5:
		_heart_channeling = false
		_heart_channel_time = 0.0
		return

	_heart_channeling    = true
	_heart_channel_time += delta

	# Spawn extra zombies every 4s while channeling
	if int(_heart_channel_time) % 4 == 0 and int(_heart_channel_time) > 0:
		_spawn_extra_zombies(2)

	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			var pct := _heart_channel_time / HEART_CHANNEL_DURATION
			if int(pct * 10) % 3 == 0:
				hud.show_message("⚡ Channeling hive heart… %.0f%%" % (pct * 100.0), Color(1.0, 0.7, 0.1))

	if _heart_channel_time >= HEART_CHANNEL_DURATION:
		_activate_heart_buff(player)
		_heart_node.queue_free()
		_heart_node = null


func _activate_heart_buff(player: Node) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("🔥 INFINITE AMMO for 20 seconds!", Color(1.0, 0.85, 0.1))
	# Grant infinite ammo buff to player
	if player.has_method("apply_upgrade"):
		player.set_meta("infinite_ammo", true)
		get_tree().create_timer(HEART_BUFF_DURATION).timeout.connect(func():
			if is_instance_valid(player): player.set_meta("infinite_ammo", false)
			for hud2 in get_tree().get_nodes_in_group("hud"):
				if hud2.has_method("show_message"): hud2.show_message("Infinite ammo expired.", Color(0.7, 0.7, 0.7)))
	print("[HiveCluster] Hive Heart channeled — infinite ammo buff granted")


func _spawn_extra_zombies(count: int) -> void:
	# Networked: server-only, same reasoning as _deferred_init's gate --
	# called from both take_damage()'s death-retaliation (already
	# server-only, see take_damage() below) and try_channel_heart()'s
	# periodic spawns (triggered by whichever peer's local player is
	# channeling -- not itself server-validated; the Hive Heart mechanic's
	# own authority is a known, documented gap this pass doesn't solve).
	# This gate at least prevents a channeling client from independently
	# creating real, unreplicated zombies nobody else sees.
	if NetworkManager.is_networked and not multiplayer.is_server(): return
	if not ResourceLoader.exists(GUARD_SCENE): return
	var packed : PackedScene = load(GUARD_SCENE)
	var space  := get_tree().root.get_world_3d().direct_space_state
	var zhm    := get_node_or_null("/root/ZombieHordeManager")
	for _i in count:
		# REAL BUG FIX (2026-07-24, severe): same uncapped Zone-1 spawn bug
		# as _spawn_patrol_guards -- see that function's note.
		if is_instance_valid(zhm) and zhm.has_method("can_register_z1") and not zhm.can_register_z1():
			break
		var g : Node = packed.instantiate()
		if not is_instance_valid(g): continue
		if "team_id"     in g: g.set("team_id",     2)
		if "ai_mode"     in g: g.set("ai_mode",     1)   # AIMode.ATTACK
		if "enemy_base"  in g: g.set("enemy_base",  attack_target if is_instance_valid(attack_target) else null)
		if "friendly_base" in g: g.set("friendly_base", self)
		var rx    := randf_range(-4.0, 4.0)
		var rz    := randf_range(-4.0, 4.0)
		var spawn := global_position + Vector3(rx, 0.5, rz)
		if is_instance_valid(space):
			var ray := PhysicsRayQueryParameters3D.create(
				Vector3(spawn.x, 200.0, spawn.z), Vector3(spawn.x, -50.0, spawn.z))
			ray.collision_mask = 1
			ray.exclude = _structure_exclude
			var hit := space.intersect_ray(ray)
			if not hit.is_empty(): spawn.y = hit.position.y + 0.5
		if NetworkManager.is_networked:
			PurchaseRelay.register_scene(packed)
			PurchaseRelay.spawn_root().add_child(g, true)
		else:
			get_tree().current_scene.add_child(g)
		if g is Node3D: (g as Node3D).global_position = spawn
		if is_instance_valid(zhm) and g is CharacterBody3D:
			zhm.register_z1(g as CharacterBody3D)
