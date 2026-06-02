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
const TIER_EGG_HATCH_TIME: Dictionary = {1:90.0,   2:75.0,   3:60.0,   4:45.0,   5:30.0}
# Wave sizes are capped by the 100-unit global limit in Egg.gd
const TIER_EGG_WAVE_SIZE : Dictionary = {1:5,      2:7,      3:10,     4:14,     5:18}

# Tier N spans from TIER_DEPTH[N-1] to TIER_DEPTH[N]
const TIER_DEPTH : Array = [0.0, 0.30, 0.48, 0.62, 0.78, 1.0]

var _player_base : Node3D = null
var _clusters    : Array  = []
var _alive_count : int    = 0


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_boot()


func _boot() -> void:
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
		if pos.distance_to(p1) < min_cluster_spacing: continue

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
	var cluster := HiveCluster.new()
	cluster.tier               = tier
	cluster.hive_hp            = TIER_HIVE_HP[tier]
	cluster.patrol_count       = TIER_GUARD_COUNTS[tier]
	cluster.max_eggs           = TIER_MAX_EGGS[tier]
	cluster.egg_spawn_interval = TIER_EGG_SPAWN_INT[tier]
	cluster.egg_hatch_time     = TIER_EGG_HATCH_TIME[tier]
	cluster.egg_wave_size      = TIER_EGG_WAVE_SIZE[tier]
	cluster.patrol_radius      = TIER_PATROL_RADII[tier]
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
