extends Node
# ============================================================
# HiveNestManager.gd
# ============================================================
# Add as a node in your game scene (NOT an autoload).
# Scatters HiveClusters tier 1 (near player) → tier 5 (deep).
#
# Wave progression: eggs activate only when the player pushes
# within their activation radius (tier 1 ~210 m, tier 5 ~90 m),
# so the player naturally fights weak units first.
#
# Global cap: never more than 100 live hive units at once.
# ============================================================

@export var cluster_count       : int   = 8
@export var min_cluster_spacing : float = 26.0
@export var map_length_override : float = 0.0
# REAL BUG FIX (2026-07-25): min_cluster_spacing (26.0) only guarded the
# CLUSTER CENTER's distance from the player base -- it didn't account for the
# player's own castle radius (basenode.gd's _half = 14.0) or a tier-1
# cluster's own defense turrets, which spawn up to patrol_radius*0.85 (~11.9
# for tier 1) out from that center IN ANY DIRECTION, including straight back
# toward the player. Worst case, a cluster placed at exactly 26.0 could drop
# a turret ~0.1 units outside the player's castle wall -- effectively right
# on top of it. Enforce a much wider minimum specifically against the
# player's base so nest turrets always land a real, noticeable distance away.
@export var min_player_base_spacing : float = 45.0

signal all_clusters_cleared

# ── Per-tier config ──────────────────────────────────────────
const TIER_CREEP_POOLS : Dictionary = {
	1: ["zombie",    "zombie",    "leaper"],
	2: ["zombie",    "leaper",    "berserker"],
	3: ["berserker", "ghost",     "assassin"],
	4: ["titan",     "necromancer","assassin"],
	5: ["titan",     "titan",     "necromancer"],
}
# Guards per cluster — kept low; ZombieHordeManager already handles crowd LOD
const TIER_GUARD_COUNTS  : Dictionary = {1:1,      2:1,      3:2,      4:3,      5:4}
const TIER_HIVE_HP       : Dictionary = {1:8000.0, 2:25000.0, 3:70000.0, 4:140000.0, 5:200000.0}
const TIER_PATROL_RADII  : Dictionary = {1:14.0,   2:16.0,   3:18.0,   4:20.0,   5:23.0}
# Egg limits — low cap keeps active unit count manageable
const TIER_MAX_EGGS      : Dictionary = {1:1,      2:1,      3:2,      4:2,      5:3}
const TIER_EGG_SPAWN_INT : Dictionary = {1:70.0,   2:60.0,   3:50.0,   4:40.0,   5:30.0}
# Tier-1 hatch pushed 90 -> 110 for more early-game setup runway.
const TIER_EGG_HATCH_TIME: Dictionary = {1:110.0,  2:75.0,   3:60.0,   4:45.0,   5:30.0}
# Wave sizes are capped by the 100-unit global limit in Egg.gd.
# Early tiers cut (1: 5->3, 2: 7->5) -- opening was too punishing; tiers 3-5 unchanged.
const TIER_EGG_WAVE_SIZE : Dictionary = {1:3,      2:5,      3:10,     4:14,     5:18}
# REAL FEATURE ADD (2026-07-21): "the higher the tier eggs the higher level
# turrets it should have defending it as well as zombies" -- tier 1 nests
# get no turrets at all (an easy first fight), scaling up to 3 max-tier
# turrets guarding a tier-5 nest. Turret level uses FireTurret's own real
# upgrade() scaling, not a separate stat table.
const TIER_TURRET_COUNTS : Dictionary = {1:0,      2:1,      3:1,      4:2,      5:3}
const TIER_TURRET_LEVEL  : Dictionary = {1:1,      2:2,      3:3,      4:4,      5:5}

# Tier N spans from TIER_DEPTH[N-1] to TIER_DEPTH[N]
const TIER_DEPTH : Array = [0.0, 0.30, 0.48, 0.62, 0.78, 1.0]

var _player_base : Node3D = null
var _clusters    : Array  = []
var _alive_count : int    = 0

# ============================================================
# NETWORKED REPLICATION — Phase 4 of the multiplayer plan.
# HiveCluster and Egg are both code-constructed (.new(), not a
# PackedScene), so MultiplayerSpawner.add_spawnable_scene() can't
# register them -- they need spawn_function instead. This node is a
# single, well-known scene child (unlike HiveCluster/Egg instances
# themselves, which are dynamically created and can't host their own
# spawner registration identically on every peer), so it's the right
# place for both spawners. Set up unconditionally in _ready() (not
# gated to server) so a client has the spawner ready to receive
# replicated spawns even though it never runs _boot()'s placement.
# ============================================================
var _cluster_spawn_root : Node3D
var _cluster_spawner     : MultiplayerSpawner
var _egg_spawn_root      : Node3D
var _egg_spawner         : MultiplayerSpawner


func _ready() -> void:
	add_to_group("hive_nest_manager")
	_setup_networked_spawners()
	await get_tree().process_frame
	await get_tree().process_frame
	_boot()


func _setup_networked_spawners() -> void:
	_cluster_spawn_root = Node3D.new()
	_cluster_spawn_root.name = "HiveClusterRoot"
	add_child(_cluster_spawn_root)
	_cluster_spawner = MultiplayerSpawner.new()
	_cluster_spawner.name = "HiveClusterSpawner"
	_cluster_spawner.spawn_path = _cluster_spawn_root.get_path()
	_cluster_spawner.spawn_function = _spawn_cluster_from_data
	add_child(_cluster_spawner)

	_egg_spawn_root = Node3D.new()
	_egg_spawn_root.name = "HiveEggRoot"
	add_child(_egg_spawn_root)
	_egg_spawner = MultiplayerSpawner.new()
	_egg_spawner.name = "HiveEggSpawner"
	_egg_spawner.spawn_path = _egg_spawn_root.get_path()
	_egg_spawner.spawn_function = _spawn_egg_from_data
	add_child(_egg_spawner)


## Called by _spawn_cluster() below (server-only). data carries everything
## needed to reconstruct an identical HiveCluster on every peer -- position
## isn't part of the export vars HiveCluster reads from itself, so it's
## applied here before the spawner parents the returned node.
func _spawn_cluster_from_data(data: Dictionary) -> HiveCluster:
	var cluster := HiveCluster.new()
	cluster.tier               = data.get("tier", 1)
	cluster.hive_hp            = TIER_HIVE_HP[cluster.tier]
	cluster.patrol_count       = TIER_GUARD_COUNTS[cluster.tier]
	cluster.max_eggs           = TIER_MAX_EGGS[cluster.tier]
	cluster.egg_spawn_interval = TIER_EGG_SPAWN_INT[cluster.tier]
	cluster.egg_hatch_time     = TIER_EGG_HATCH_TIME[cluster.tier]
	cluster.egg_wave_size      = TIER_EGG_WAVE_SIZE[cluster.tier]
	cluster.patrol_radius      = TIER_PATROL_RADII[cluster.tier]
	cluster.turret_count       = TIER_TURRET_COUNTS[cluster.tier]
	cluster.turret_level       = TIER_TURRET_LEVEL[cluster.tier]
	cluster.attack_target      = _player_base
	cluster.creep_pool         = TIER_CREEP_POOLS[cluster.tier].duplicate()
	cluster.position           = data.get("position", Vector3.ZERO)
	if multiplayer.is_server():
		cluster.cluster_cleared.connect(_on_cluster_cleared)
	return cluster


## Called by HiveCluster (server-only) when it wants to spawn a real,
## networked egg instead of constructing one locally -- see Egg.gd's
## _spawn_single_egg() for the networked branch that calls this.
func spawn_networked_egg(egg_data: Dictionary) -> void:
	if not multiplayer.is_server(): return
	_egg_spawner.spawn(egg_data)


func _spawn_egg_from_data(data: Dictionary) -> Egg:
	var egg := Egg.new()
	egg.tier          = data.get("tier", 1)
	egg.max_hp        = data.get("max_hp", 80.0)
	egg.hatch_time    = data.get("hatch_time", 60.0)
	egg.wave_size     = data.get("wave_size", 4)
	egg.creep_ids     = data.get("creep_ids", ["zombie"])
	egg.attack_target = _player_base
	egg.position       = data.get("position", Vector3.ZERO)
	var owner_path : NodePath = data.get("owner_cluster_path", NodePath())
	if not owner_path.is_empty():
		var owner_cluster := get_node_or_null(owner_path)
		if is_instance_valid(owner_cluster) and owner_cluster.has_method("_on_networked_egg_spawned"):
			owner_cluster._on_networked_egg_spawned(egg)
	return egg


func _boot() -> void:
	# Phase 4 of the multiplayer plan: hive/egg/wave simulation is
	# server-only. A non-host client must not run its own independent
	# placement pass -- it would diverge from the server's nests (and,
	# once HiveCluster/Egg gain MultiplayerSpawner.spawn_function
	# registration, would also conflict with the server's replicated
	# spawns). Local/offline play (NetworkManager.is_networked == false)
	# is completely untouched.
	if NetworkManager.is_networked and not multiplayer.is_server():
		return
	_find_player_base()
	if not is_instance_valid(_player_base):
		await get_tree().create_timer(0.5).timeout
		_find_player_base()
	if not is_instance_valid(_player_base):
		push_error("[HiveNestManager] No team-1 base in 'bases' group — cannot place nests")
		return
	_place_all_clusters()


func _find_player_base() -> void:
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == 1:
			_player_base = b as Node3D
			return


# ── Placement ────────────────────────────────────────────────
func _place_all_clusters() -> void:
	var p1 : Vector3 = _player_base.global_position

	var map_center : Vector3 = p1
	var base_count : int     = 0
	for b in get_tree().get_nodes_in_group("bases"):
		if is_instance_valid(b) and b is Node3D:
			map_center += (b as Node3D).global_position
			base_count += 1
	if base_count > 1: map_center /= float(base_count)

	var axis    : Vector3 = (map_center - p1); axis.y = 0.0
	var map_len : float   = map_length_override if map_length_override > 0.0 else max(axis.length() * 2.0, 100.0)
	var forward : Vector3 = axis.normalized() if axis.length() > 1.0 else Vector3.FORWARD
	var perp    : Vector3 = Vector3(-forward.z, 0.0, forward.x)
	var half_w  : float   = map_len * 0.38

	var placed : Array[Vector3] = []
	var tries  : int = 0

	while placed.size() < cluster_count and tries < cluster_count * 10:
		tries += 1
		var t       : float   = _random_depth_biased()
		var lateral : float   = randf_range(-half_w, half_w)
		var pos     : Vector3 = p1 + forward * (map_len * t) + perp * lateral
		pos.y = 0.5

		var too_close : bool = false
		for ep : Vector3 in placed:
			if pos.distance_to(ep) < min_cluster_spacing:
				too_close = true; break
		if too_close: continue
		if pos.distance_to(p1) < min_player_base_spacing: continue

		placed.append(pos)
		_spawn_cluster(pos, _depth_to_tier(t))

	_alive_count = _clusters.size()
	print("[HiveNestManager] Placed %d clusters (tried %d times)" % [_clusters.size(), tries])


func _random_depth_biased() -> float:
	var r : float = randf()
	return 0.12 + r * r * 0.84


func _depth_to_tier(t: float) -> int:
	for i in range(TIER_DEPTH.size() - 1):
		if t < TIER_DEPTH[i + 1]:
			return i + 1
	return 5


func _spawn_cluster(world_pos: Vector3, tier: int) -> void:
	# Networked: only ever reached on the server (see _boot()'s gate), so
	# routing through the spawn_function-registered spawner replicates an
	# identical HiveCluster to every peer instead of only existing locally.
	if NetworkManager.is_networked:
		var cluster_net : HiveCluster = _cluster_spawner.spawn({"tier": tier, "position": world_pos})
		if is_instance_valid(cluster_net):
			_clusters.append(cluster_net)
			print("[HiveNestManager] Tier %d cluster at %s (networked)" % [tier, str(world_pos.snapped(Vector3.ONE))])
		return

	var cluster := HiveCluster.new()
	cluster.tier               = tier
	cluster.hive_hp            = TIER_HIVE_HP[tier]
	cluster.patrol_count       = TIER_GUARD_COUNTS[tier]
	cluster.max_eggs           = TIER_MAX_EGGS[tier]
	cluster.egg_spawn_interval = TIER_EGG_SPAWN_INT[tier]
	cluster.egg_hatch_time     = TIER_EGG_HATCH_TIME[tier]
	cluster.egg_wave_size      = TIER_EGG_WAVE_SIZE[tier]
	cluster.patrol_radius      = TIER_PATROL_RADII[tier]
	cluster.turret_count       = TIER_TURRET_COUNTS[tier]
	cluster.turret_level       = TIER_TURRET_LEVEL[tier]
	cluster.attack_target      = _player_base
	cluster.creep_pool         = TIER_CREEP_POOLS[tier].duplicate()
	cluster.cluster_cleared.connect(_on_cluster_cleared)

	get_tree().current_scene.add_child(cluster)
	cluster.global_position = world_pos

	_clusters.append(cluster)
	print("[HiveNestManager] Tier %d cluster at %s" % [tier, str(world_pos.snapped(Vector3.ONE))])


# ── Cluster cleared ──────────────────────────────────────────
func _on_cluster_cleared() -> void:
	_alive_count -= 1
	print("[HiveNestManager] %d nests remaining" % _alive_count)
	if _alive_count <= 0:
		print("[HiveNestManager] ★ ALL NESTS DESTROYED — triggering victory!")
		all_clusters_cleared.emit()


# ── Debug helpers ─────────────────────────────────────────────
func get_alive_count() -> int: return _alive_count
func get_cluster_count() -> int: return _clusters.size()
func get_active_unit_count() -> int: return get_tree().get_nodes_in_group("hive_unit").size()
