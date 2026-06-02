# ============================================================
# LaneSpawner.gd — AUTOLOAD
# ============================================================
extends Node

signal wave_spawned(team_id: int, lane: int, count: int)

@export var creep_scene_team1 : PackedScene = null
@export var creep_scene_team2 : PackedScene = null
@export var wave_size         : int   = 8   # base wave size (scales with wave number)
@export var wave_interval     : float = 60.0
@export var spawn_stagger     : float = 0.3
@export var lane_width_offset : float = 0.55  # increased: wider lane separation reduces crowding
# Layer 1 = terrain/ground. Trees/props should be on a DIFFERENT layer (e.g. layer 2+).
# Set this to the physics layer your ground/terrain uses so the spawn raycast
# only lands on ground and ignores tree trunks and other props above it.
@export_flags_3d_physics var ground_layer : int = 1

const LANE_COUNT   := 3
const SCENE_PATH_1 := "res://zombie/zombie.tscn"
const SCENE_PATH_2 := "res://zombie/zombie.tscn"

var _base1  : Node3D = null
var _base2  : Node3D = null
var _ready_to_spawn : bool = false
var _wave_timer     : float = 0.0
var _wave_number    : int   = 0
var _lane_paths : Array = [[], [], []]


func _ready() -> void:
	# Singleton guard — only one LaneSpawner should run
	var existing := get_tree().get_nodes_in_group("lane_spawner")
	if existing.size() > 0 and existing[0] != self:
		push_warning("[LaneSpawner] Duplicate detected (%s). Removing." % name)
		queue_free(); return
	add_to_group("lane_spawner")
	set_process(false)
	# Wait for bases to be added to scene — retry up to 5 seconds
	_find_bases_retry()

func _find_bases_retry() -> void:
	for _attempt in range(50):   # 50 x 0.1s = 5 seconds max
		await get_tree().create_timer(0.1).timeout
		var found1 := false; var found2 := false
		for b in get_tree().get_nodes_in_group("bases"):
			if not is_instance_valid(b) or not ("team_id" in b): continue
			if int(b.get("team_id")) == 1: found1 = true
			if int(b.get("team_id")) == 2: found2 = true
		if found1 and found2:
			_find_bases()
			return
	push_error("[LaneSpawner] Could not find both bases after 5s!")


func _find_bases() -> void:
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b): continue
		if int(b.get("team_id")) == 1: _base1 = b as Node3D
		else:                           _base2 = b as Node3D

	if not is_instance_valid(_base1) or not is_instance_valid(_base2):
		push_error("[LaneSpawner] bases still missing after retry — check 'bases' group and team_id.")
		return
	print("[LaneSpawner] _find_bases OK | base1=%s pos=%s | base2=%s pos=%s" % [
		_base1.name, str(_base1.global_position.snapped(Vector3.ONE)),
		_base2.name, str(_base2.global_position.snapped(Vector3.ONE))])
	# Rebake navmesh so castle walls are included in pathfinding
	_rebake_navmesh()

	_compute_lane_paths()
	# Don't override process state if start() already called
	if not _ready_to_spawn:
		set_process(false)

	if not is_instance_valid(creep_scene_team1):
		push_error("[LaneSpawner] creep_scene_team1 is NULL — assign in Inspector!")
	if not is_instance_valid(creep_scene_team2):
		push_error("[LaneSpawner] creep_scene_team2 is NULL — assign in Inspector!")

	print("[LaneSpawner] Ready. Base1=%s(team%s) Base2=%s(team%s)" % [
		_base1.name, str(_base1.get("team_id") if "team_id" in _base1 else "?"),
		_base2.name, str(_base2.get("team_id") if "team_id" in _base2 else "?")])



func _rebake_navmesh() -> void:
	# Find NavigationRegion3D in scene and rebake so castle walls are included
	var nav_region := get_tree().root.find_child("NavigationRegion3D", true, false)
	if not is_instance_valid(nav_region):
		# Try common names
		for nm in ["NavRegion", "Navigation", "NavMesh", "World_Nav", "Terrain_Nav"]:
			nav_region = get_tree().root.find_child(nm, true, false)
			if is_instance_valid(nav_region): break
	if is_instance_valid(nav_region) and nav_region.has_method("bake_navigation_mesh"):
		print("[LaneSpawner] Rebaking navmesh after castle spawn...")
		nav_region.bake_navigation_mesh(false)  # false = don't clear cache
		print("[LaneSpawner] Navmesh rebake complete")
	else:
		print("[LaneSpawner] No NavigationRegion3D found — zombies using raycast avoidance")

func _compute_lane_paths() -> void:
	# Team 1 base (spawns here, marches toward team 2 base)
	var t1_start : Vector3 = _base1.global_position
	# Team 2 base (spawns here, marches toward team 1 base)
	var t2_start : Vector3 = _base2.global_position

	var axis    := (t2_start - t1_start); axis.y = 0.0
	var length  := axis.length()
	var forward := axis.normalized()
	var perp    := Vector3(-forward.z, 0.0, forward.x).normalized()
	var offsets : Array = [-1.0, 0.0, 1.0]

	# team_idx=0: team1 spawns at t1_start, marches to t2_start
	# team_idx=1: team2 spawns at t2_start, marches to t1_start
	var starts : Array = [t1_start, t2_start]
	var ends   : Array = [t2_start, t1_start]

	for team_idx in 2:
		_lane_paths[team_idx] = []
		var s : Vector3 = starts[team_idx]
		var e : Vector3 = ends[team_idx]
		for lane in LANE_COUNT:
			var off_amount : float = offsets[lane] * length * lane_width_offset
			var bulge_mid  : Vector3 = s.lerp(e, 0.5) + perp * off_amount
			# Build a 3-control-point bezier for smoother curves (start → quarter-bulge → mid → three-quarter → end)
			# More waypoints = smoother path = fewer zombies getting stuck on corners
			const WP_COUNT : int = 11
			var pts : Array = []
			for i in range(WP_COUNT):
				var t : float = float(i) / float(WP_COUNT - 1)
				var p0 := s.lerp(bulge_mid, t)
				var p1 := bulge_mid.lerp(e, t)
				var wp : Vector3 = p0.lerp(p1, t)
				wp.y = 0.5   # normalize Y — zombie handles exact ground height
				pts.append(wp)
			# Pin endpoints OUTSIDE castle walls (offset 16 units from each base)
			var _fwd : Vector3 = (e - s); _fwd.y = 0.0
			if _fwd.length_squared() > 0.01: _fwd = _fwd.normalized()
			pts[0]              = Vector3(s.x, 0.5, s.z) + _fwd * 16.0
			pts[pts.size() - 1] = Vector3(e.x, 0.5, e.z) - _fwd * 16.0
			_lane_paths[team_idx].append(pts)

	print("[LaneSpawner] Lane paths computed. Offset scale=%.1f" % (length * lane_width_offset))


func _process(delta: float) -> void:
	if not _ready_to_spawn: return
	_wave_timer -= delta
	if _wave_timer <= 0.0:
		_wave_timer = wave_interval
		_wave_number += 1
		# Track endless wave in GameSettings
		if Engine.has_singleton("GameSettings"):
			var gs := Engine.get_singleton("GameSettings")
			if gs.get("game_mode") == "endless":
				gs.set("endless_wave", _wave_number)
		# Endless: escalate wave size every 5 waves
		if Engine.has_singleton("GameSettings"):
			var gs := Engine.get_singleton("GameSettings")
			if gs.get("game_mode") == "endless" and _wave_number % 5 == 0:
				wave_size = mini(wave_size + 2, 40)
		# Use call_deferred so the async _spawn_all_lanes doesn't block _process
		_spawn_all_lanes.call_deferred()


func _spawn_all_lanes() -> void:
	_announce_wave()
	# Non-async: spawn all at once, stagger via individual timers
	for lane in LANE_COUNT:
		var delay1 := lane * 0.3
		var delay2 := lane * 0.3 + 0.15
		get_tree().create_timer(delay1).timeout.connect(func(): _spawn_lane_wave(1, lane), CONNECT_ONE_SHOT)
		get_tree().create_timer(delay2).timeout.connect(func(): _spawn_lane_wave(2, lane), CONNECT_ONE_SHOT)


func _announce_wave() -> void:
	var msgs : Array = [
		"Wave %d incoming…",
		"⚠ Wave %d — hold the line!",
		"The horde grows — Wave %d!",
		"🔥 Wave %d — brace yourself!",
	]
	var egg_msgs : Array = [
		"🥚 Egg wave %d — destroy the nests!",
		"⚠ Eggs hatching! Wave %d incoming!",
	]
	# Every 5th wave is an egg focus wave
	var is_egg_wave := (_wave_number % 5 == 0)
	var pool : Array = egg_msgs if is_egg_wave else msgs
	var text : String = pool[_wave_number % pool.size()] % _wave_number
	var col  : Color  = Color(1.0, 0.35, 0.1) if is_egg_wave else Color(0.95, 0.85, 0.2)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(text, col)


func _spawn_lane_wave(team: int, lane: int) -> void:
	var scene : PackedScene = _get_scene(team)
	if not is_instance_valid(scene):
		push_error("[LaneSpawner] MISSING SCENE for team %d — assign creep_scene_team%d in Inspector!" % [team, team])
		return

	var team_idx : int = 0 if team == 1 else 1
	var paths    : Array = _lane_paths[team_idx]
	if paths.is_empty():
		push_error("[LaneSpawner] T%d lane paths EMPTY — _compute_lane_paths failed" % team); return
	if lane >= paths.size(): return
	var waypoints : Array = paths[lane]
	if waypoints.is_empty(): return

	# Skip waypoints that are still inside the castle walls (radius ~16 units).
	# Castle _W=28 so half=14 + 2m margin = 16 units minimum spawn distance.
	const CASTLE_EXCLUSION_RADIUS : float = 16.0
	var base_origin : Vector3 = waypoints[0]
	var spawn_wp_idx : int = 1
	for _wi in range(1, waypoints.size()):
		var wp : Vector3 = waypoints[_wi]
		if base_origin.distance_to(wp) >= CASTLE_EXCLUSION_RADIUS:
			spawn_wp_idx = _wi; break
	var spawn_pos : Vector3 = waypoints[spawn_wp_idx]
	var march_wps : Array   = waypoints.slice(spawn_wp_idx)

	var enemy_base : Node3D = _base2 if team == 1 else _base1
	var friendly   : Node3D = _base1 if team == 1 else _base2

	var spawned := [0]  # use array so lambda can capture by ref
	# Scale wave size with wave number — gets progressively harder
	var scaled_size : int = wave_size + _wave_number  # +1 per wave not +2
	for i in range(scaled_size):
		get_tree().create_timer(spawn_stagger * i).timeout.connect(
			func():
				if not is_inside_tree(): return
				var creep := _spawn_creep(scene, team, spawn_pos, march_wps, enemy_base, friendly, spawned[0], lane)
				if is_instance_valid(creep): spawned[0] += 1
				if spawned[0] >= scaled_size:
					wave_spawned.emit(team, lane, spawned[0])
					print("[LaneSpawner] ✓ T%d Lane%d Wave#%d — %d creeps (base:%d)" % [team, lane, _wave_number, spawned[0], wave_size]),
			CONNECT_ONE_SHOT)


func _spawn_creep(
		scene          : PackedScene,
		team           : int,
		pos            : Vector3,
		waypoints      : Array,
		enemy_base     : Node3D,
		friendly       : Node3D,
		slot           : int,
		lane           : int = 0
) -> Node3D:
	if not is_instance_valid(scene): return null
	var creep := scene.instantiate()
	if not is_instance_valid(creep): return null
	# Apply override script BEFORE add_child so _ready() runs with correct type

	# Set identity BEFORE add_child so _ready() sees correct values
	if "team_id"       in creep: creep.set("team_id",       team)
	if "enemy_base"    in creep: creep.set("enemy_base",    enemy_base)
	if "friendly_base" in creep: creep.set("friendly_base", friendly)
	if "lane_id"       in creep: creep.set("lane_id",       lane)
	if "owner_id"      in creep: creep.set("owner_id",      -1)

	get_tree().current_scene.add_child(creep)

	# RE-APPLY after _ready() — guards against _find_bases() overwriting
	if "team_id"       in creep: creep.set("team_id",       team)
	if "enemy_base"    in creep: creep.set("enemy_base",    enemy_base)
	if "friendly_base" in creep: creep.set("friendly_base", friendly)
	if "lane_id"       in creep: creep.set("lane_id",       lane)

	# Position with stagger — raycast to find actual ground Y
	# Spread radius scales with wave size so zombies don't stack.
	# Minimum 2.0m between zombies; ring radius grows for larger waves.
	var spawn_radius : float = maxf(2.0, wave_size * 0.4)
	var angle  : float   = float(slot) / float(maxi(wave_size, 1)) * TAU
	var offset : Vector3 = Vector3(cos(angle), 0.0, sin(angle)) * spawn_radius
	# Defense creeps: spawn outside castle walls, not at waypoint[1]
	# Push them 8-12 units away from base in a spread arc
	var is_defense : bool = false
	if "ai_mode" in creep: is_defense = int(creep.get("ai_mode")) == 2  # AIMode.DEFEND
	if "squad_order" in creep: is_defense = is_defense or int(creep.get("squad_order")) == 1  # DEFEND
	var base_for_spawn : Node3D = friendly if is_instance_valid(friendly) else null
	var spawn : Vector3
	if is_defense and is_instance_valid(base_for_spawn):
		# Push toward enemy base so spawn is outside castle walls, not inside
		var _enemy : Node3D = _base2 if is_instance_valid(_base1) and base_for_spawn == _base1 else _base1
		var _push_dir : Vector3 = Vector3.FORWARD
		if is_instance_valid(_enemy):
			_push_dir = _enemy.global_position - base_for_spawn.global_position
			_push_dir.y = 0.0
			if _push_dir.length_squared() > 0.01: _push_dir = _push_dir.normalized()
		var _arc := float(slot % 5) / 5.0 * TAU * 0.33 - PI / 3.0
		var _spread := _push_dir.rotated(Vector3.UP, _arc)
		var _radius := 16.0 + float(slot % 3) * 1.5
		spawn = base_for_spawn.global_position + _spread * _radius
	else:
		spawn = pos + offset
	spawn.y = 200.0  # always start ray from high up regardless of base Y
	var space  := get_tree().root.get_world_3d().direct_space_state if is_inside_tree() else null
	if is_instance_valid(space):
		# Pass 1: ground layer only — ignores tree trunks and prop colliders
		var ray := PhysicsRayQueryParameters3D.create(
			Vector3(spawn.x, 200.0, spawn.z),
			Vector3(spawn.x, -50.0, spawn.z))
		ray.collision_mask = ground_layer
		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			spawn.y = hit.position.y + 0.3
		else:
			# Pass 2: fallback to all layers — but filter out hits too high up
			# (a hit above Y=10 is almost certainly a tree trunk, skip it)
			ray.collision_mask = 0xFFFFFFFF
			hit = space.intersect_ray(ray)
			if not hit.is_empty() and (hit.position as Vector3).y < 10.0:
				spawn.y = (hit.position as Vector3).y + 0.3
			else:
				spawn.y = 1.0  # flat fallback
	else:
		spawn.y = 1.0
	creep.global_position = spawn

	creep.add_to_group("units")
	creep.add_to_group("minions")

	# Fade minion in through fog patch
	var fse := get_tree().get_first_node_in_group("fog_spawn_effect")
	if is_instance_valid(fse) and fse.has_method("fade_in_minion"):
		fse.fade_in_minion(creep as Node3D)

	# Legacy waypoint support (old zombie.gd)
	if creep.has_method("set_lane"):
		var march_wps := waypoints.slice(1) if waypoints.size() > 1 else waypoints
		creep.call("set_lane", march_wps, lane)

	# Patch take_damage to emit damage numbers if creep doesn't already do it
	_patch_damage_numbers(creep)
	# Register with HordeManager (new system)
	var hm := get_tree().get_first_node_in_group("horde_manager")
	if is_instance_valid(hm) and hm.has_method("register"):
		hm.call("register", creep)

	# Legacy ZombieHordeManager support
	var zhm := get_tree().get_first_node_in_group("zombie_horde_manager")
	if is_instance_valid(zhm) and zhm.has_method("register_zombie"):
		zhm.register_zombie(creep, team)

	# 1% chance: make this a rare glowing zombie
	if randf() < 0.01:
		var glow_script := load("res://zombie/GlowingZombie.gd")
		if is_instance_valid(glow_script):
			GlowingZombie.make_glowing(creep)

	return creep as Node3D



func _patch_damage_numbers(creep: Node) -> void:
	# If creep already spawns damage numbers (e.g. BaseZombie), skip
	if creep.has_meta("dmg_num_patched"): return
	creep.set_meta("dmg_num_patched", true)
	# We can't override take_damage in GDScript at runtime,
	# so connect a signal if available, otherwise do nothing
	# (BaseZombie handles this; TankCreep etc need manual call at hit site)
	# Instead: add a lightweight monitor that watches health and spawns numbers
	_monitor_damage(creep, float(creep.get("health") if "health" in creep else 100.0))

func _monitor_damage(creep: Node, last_hp: float) -> void:
	if not is_instance_valid(creep): return
	var cur_hp : float = float(creep.get("health") if "health" in creep else last_hp)
	if cur_hp < last_hp - 0.5:
		var dmg : float = last_hp - cur_hp
		var dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(dn) and dn.has_method("spawn_number") and creep is Node3D:
			dn.spawn_number(dmg, (creep as Node3D).global_position + Vector3(0, 2.0, 0), 0, false)
	if creep.has_method("is_dead") and creep.is_dead(): return
	get_tree().create_timer(0.1).timeout.connect(
		func(): _monitor_damage(creep, cur_hp), CONNECT_ONE_SHOT)

func _get_scene(team: int) -> PackedScene:
	# 1. Inspector-assigned export (most explicit — set these in the Inspector)
	if team == 1 and is_instance_valid(creep_scene_team1): return creep_scene_team1
	if team == 2 and is_instance_valid(creep_scene_team2): return creep_scene_team2

	# 2. Steal scene from an existing CreepSpawner that matches this team.
	#    This means zero Inspector setup — LaneSpawner piggybacks on whatever
	#    the CreepSpawners already have assigned.
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if not is_instance_valid(s): continue
		var s_team : int = int(s.get("team_id") if "team_id" in s else -1)
		if s_team != team: continue
		var sc = s.get("creep_scene") if "creep_scene" in s else null
		if is_instance_valid(sc): return sc as PackedScene
		# Also check attack_creep_scenes array (shop-style spawner)
		if "attack_creep_scenes" in s:
			var arr : Array = s.get("attack_creep_scenes")
			if not arr.is_empty() and is_instance_valid(arr[0]): return arr[0] as PackedScene

	# 3. Hardcoded fallback paths (edit SCENE_PATH_1/2 at top if yours differs)
	if team == 1 and ResourceLoader.exists(SCENE_PATH_1): return load(SCENE_PATH_1)
	if team == 2 and ResourceLoader.exists(SCENE_PATH_2): return load(SCENE_PATH_2)

	# 4. CreepDeckManager
	var cdm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(cdm) and cdm.has_method("get_scene_for_creep"):
		var s2 : PackedScene = cdm.get_scene_for_creep("zombie")
		if is_instance_valid(s2): return s2

	# 5. Scan common paths
	for path in ["res://scenes/zombie.tscn", "res://zombie.tscn",
			"res://characters/zombie.tscn", "res://enemies/zombie.tscn",
			"res://scenes/Zombie.tscn", "res://Zombie.tscn"]:
		if ResourceLoader.exists(path): return load(path)

	# Last resort: use the OTHER team's scene (both teams use same zombie type)
	var other_team : int = 2 if team == 1 else 1
	var other_scene : PackedScene = _get_scene_for_team_only(other_team)
	if is_instance_valid(other_scene): return other_scene

	push_error("[LaneSpawner] _get_scene: No zombie scene found for team %d. " % team +
		"Assign creep_scene_team%d in Inspector, OR ensure a CreepSpawner " % team +
		"with matching team_id and creep_scene exists in the scene.")
	return null


func reset() -> void:
	_ready_to_spawn = false
	_wave_timer     = 0.0
	_wave_number    = 0
	_base1          = null
	_base2          = null
	_lane_paths     = [[], [], []]
	_player_queue.clear()
	set_process(false)
	# Restart base discovery for the new scene
	_find_bases_retry()
	print("[LaneSpawner] reset")


func start() -> void:
	if _ready_to_spawn: return  # already started — ignore duplicate call
	_ready_to_spawn = true
	_wave_timer = 8.0
	set_process(true)
	# Disable legacy CreepSpawners so we don't get double waves.
	# LaneSpawner takes over all wave management.
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if is_instance_valid(s) and "active" in s:
			s.set("active", false)
			print("[LaneSpawner] Disabled legacy CreepSpawner: ", s.name)
	print("[LaneSpawner] Match started — first wave in 8s")

func stop() -> void:
	set_process(false)


# Called by GamePhaseController each wave of a round
# Distributes `count` units across all 3 lanes for the given team


func _get_scene_for_team_only(team: int) -> PackedScene:
	if team == 1 and is_instance_valid(creep_scene_team1): return creep_scene_team1
	if team == 2 and is_instance_valid(creep_scene_team2): return creep_scene_team2
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if not is_instance_valid(s): continue
		if int(s.get("team_id") if "team_id" in s else -1) != team: continue
		var sc = s.get("creep_scene") if "creep_scene" in s else null
		if is_instance_valid(sc): return sc as PackedScene
	return null


func _resolve_scene_for_id(creep_id: String, team: int) -> PackedScene:
	# Always go through CreepDeckManager — it handles both .tscn and .gd paths.
	# For .gd scripts it builds a proper CharacterBody3D scene so we never
	# end up with a base-zombie mesh wearing a TankCreep script.
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("get_scene_for_creep"):
		var sc : PackedScene = dm.get_scene_for_creep(creep_id)
		if is_instance_valid(sc):
			print("[LaneSpawner] Resolved '%s' via CreepDeckManager" % creep_id)
			return sc
	# Fallback only if CDM returns nothing — use team base zombie
	push_warning("[LaneSpawner] No scene for '%s' — using base zombie" % creep_id)
	return _get_scene(team)



# Spawn a wave where each unit uses a specific creep ID from the list.
# creep_ids: Array of String IDs — one per unit to spawn.

# ── Creep stat profiles — applied at spawn time ───────────────────────────────
# Each entry: {hp_mult, dmg_mult, spd_mult, difficulty_pct}
# difficulty_pct fills the red icon (0=basic zombie, 1=elite)
const CREEP_PROFILES : Dictionary = {
	"zombie":     {"hp": 1.0,  "dmg": 1.0,  "spd": 1.0,  "diff": 0.0 },
	"leaper":     {"hp": 0.7,  "dmg": 0.8,  "spd": 1.6,  "diff": 0.25},
	"berserker":  {"hp": 1.2,  "dmg": 1.8,  "spd": 1.3,  "diff": 0.5 },
	"tank":       {"hp": 3.5,  "dmg": 1.2,  "spd": 0.7,  "diff": 0.75},
	"bomber":     {"hp": 0.8,  "dmg": 3.0,  "spd": 1.1,  "diff": 0.85},
	"ghost":      {"hp": 0.6,  "dmg": 1.0,  "spd": 1.4,  "diff": 0.4 },
	"assassin":   {"hp": 0.8,  "dmg": 2.5,  "spd": 1.8,  "diff": 0.7 },
	"titan":      {"hp": 5.0,  "dmg": 1.5,  "spd": 0.5,  "diff": 1.0 },
	"necromancer":{"hp": 1.0,  "dmg": 1.0,  "spd": 0.9,  "diff": 0.8 },
}

func _apply_creep_profile(creep: Node, creep_id_str: String, round_num: int,
		enemy_base_node: Node3D = null, march_wps: Array = [], lane_idx: int = 0) -> void:
	# Set creep_id
	if "creep_id" in creep: creep.set("creep_id", creep_id_str)
	# Look up profile
	var profile : Dictionary = CREEP_PROFILES.get(creep_id_str, CREEP_PROFILES["zombie"])
	var diff : float = float(profile.get("diff", 0.0))
	if "difficulty_pct" in creep: creep.set("difficulty_pct", diff)
	# Scale stats by profile × round bonus
	var round_bonus : float = 1.0 + float(round_num - 1) * 0.18
	if "max_health" in creep:
		var new_hp : float = float(creep.get("max_health")) * float(profile["hp"]) * round_bonus
		creep.set("max_health", new_hp); creep.set("health", new_hp)
	if "damage" in creep:
		var new_dmg : float = float(creep.get("damage")) * float(profile["dmg"]) * (1.0 + float(round_num-1)*0.12)
		creep.set("damage", new_dmg)
	if "move_speed" in creep:
		creep.set("move_speed", float(creep.get("move_speed")) * float(profile["spd"]))
	# ── Navigation + target assignment (works for BaseZombie AND TankCreep-style creeps) ──
	if is_instance_valid(enemy_base_node):
		if "enemy_base"     in creep: creep.set("enemy_base",     enemy_base_node)
		if "march_target"   in creep: creep.set("march_target",   enemy_base_node.global_position)
		if "target"         in creep and not is_instance_valid(creep.get("target") if "target" in creep else null):
			creep.set("target", enemy_base_node)
	if march_wps.size() > 0:
		if creep.has_method("set_lane"): creep.call("set_lane", march_wps, lane_idx)
		if "march_waypoints" in creep: creep.set("march_waypoints", march_wps)
		if "waypoints"       in creep: creep.set("waypoints",       march_wps)
	# Health bar + damage numbers injection for creeps that don't have their own
	_ensure_health_bar(creep)
	# Update difficulty icon
	if creep.has_method("_update_difficulty_icon"): creep.call("_update_difficulty_icon")

func _ensure_health_bar(creep: Node) -> void:
	# Skip if creep manages its own health bar (e.g. BaseZombie)
	if creep.has_meta("has_hbar"): return
	# Skip if already has a health bar node
	if creep.find_child("HBar", true, false) != null: return
	if creep.find_child("HealthBar", true, false) != null: return
	if not (creep is Node3D): return
	# Build a floating health bar using a 3D billboard
	var root := Node3D.new(); root.name = "HBar"
	root.position = Vector3(0, 2.2, 0)
	(creep as Node3D).add_child(root)
	# Background bar
	var bg := MeshInstance3D.new()
	var bq  := QuadMesh.new(); bq.size = Vector2(1.1, 0.12)
	bg.mesh = bq
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color    = Color(0.15, 0.15, 0.15, 0.9)
	bmat.billboard_mode  = BaseMaterial3D.BILLBOARD_ENABLED
	bmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	bmat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg.material_override = bmat; bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(bg)
	# Fill bar
	var fill := MeshInstance3D.new(); fill.name = "Fill"
	var fq   := QuadMesh.new(); fq.size = Vector2(1.0, 0.09)
	fill.mesh = fq
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.albedo_color    = Color(0.2, 0.9, 0.2)
	fmat.billboard_mode  = BaseMaterial3D.BILLBOARD_ENABLED
	fmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	fill.material_override = fmat; fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(fill)
	# Connect take_damage / health updates — patch the creep's take_damage to update bar
	if creep.has_signal("health_changed"):
		creep.health_changed.connect(func(hp, mhp):
			_update_health_bar_fill(fill, hp, mhp))
	else:
		# Poll-based fallback — update bar each frame
		var timer := get_tree().create_timer(0.0)
		_poll_health_bar(creep, fill)

func _poll_health_bar(creep: Node, fill: MeshInstance3D) -> void:
	if not is_instance_valid(creep) or not is_instance_valid(fill): return
	var hp  : float = float(creep.get("health")     if "health"     in creep else 0)
	var mhp : float = float(creep.get("max_health") if "max_health" in creep else 1)
	_update_health_bar_fill(fill, hp, mhp)
	get_tree().create_timer(0.1).timeout.connect(func(): _poll_health_bar(creep, fill), CONNECT_ONE_SHOT)

func _update_health_bar_fill(fill: MeshInstance3D, hp: float, max_hp: float) -> void:
	if not is_instance_valid(fill): return
	var ratio : float = clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	fill.scale.x = ratio
	fill.position.x = (ratio - 1.0) * 0.5  # slide from left
	var mat := fill.material_override as StandardMaterial3D
	if is_instance_valid(mat):
		mat.albedo_color = Color(ratio * 0.8 + 0.2, ratio * 0.7, 0.1)  # green→red

func spawn_round_wave_mixed(team: int, creep_ids: Array, round_num: int) -> void:
	# Safety checks
	if not is_instance_valid(_base1) or not is_instance_valid(_base2): _find_bases()
	var tidx : int = 0 if team == 1 else 1
	if (_lane_paths[tidx] as Array).is_empty(): _compute_lane_paths()
	var base_sc : PackedScene = _get_scene(team)
	if not is_instance_valid(base_sc): push_error("[LaneSpawner] mixed: no base scene for team %d" % team); return

	# Distribute units round-robin across lanes with stagger
	for i in creep_ids.size():
		var lane      : int    = i % LANE_COUNT
		var creep_id  : String = str(creep_ids[i])
		var delay     : float  = float(lane) * 0.4 + float(i / LANE_COUNT) * spawn_stagger
		get_tree().create_timer(delay).timeout.connect(func():
			if not is_inside_tree(): return
			var paths : Array = _lane_paths[tidx]
			if paths.is_empty() or lane >= paths.size(): return
			var wps       : Array   = paths[lane]
			if wps.is_empty(): return
			const _CR2 : float = 16.0
			var _b02 : Vector3 = wps[0]; var _si2 : int = 1
			for _wi3 in range(1, wps.size()):
				if _b02.distance_to(wps[_wi3]) >= _CR2: _si2 = _wi3; break
			var sp        : Vector3 = wps[_si2]
			var march     : Array   = wps.slice(_si2)
			var en_base   : Node3D  = _base2 if team == 1 else _base1
			var fr_base   : Node3D  = _base1 if team == 1 else _base2
			# Resolve scene + script for this specific creep type
			var sc : PackedScene = _resolve_scene_for_id(creep_id, team)
			if not is_instance_valid(sc): sc = base_sc
			var creep := _spawn_creep(sc, team, sp, march, en_base, fr_base, i, lane)
			if is_instance_valid(creep):
				_apply_creep_profile(creep, creep_id, round_num, en_base, march, lane),
			CONNECT_ONE_SHOT)

func spawn_round_wave(team: int, count: int, round_num: int) -> void:
	# Safety: ensure bases and paths are ready
	if not is_instance_valid(_base1) or not is_instance_valid(_base2):
		_find_bases()
	if _lane_paths[0 if team == 1 else 1] is Array and (_lane_paths[0 if team == 1 else 1] as Array).is_empty():
		_compute_lane_paths()
	var scene : PackedScene = _get_scene(team)
	if not is_instance_valid(scene):
		push_error("[LaneSpawner] spawn_round_wave: no scene for team %d" % team); return
	var per_lane : int = int(ceil(float(count) / float(LANE_COUNT)))
	for lane in LANE_COUNT:
		# Slight stagger between lanes so they don't all arrive simultaneously
		get_tree().create_timer(lane * 0.5).timeout.connect(
			func(): _spawn_lane_wave_count(scene, team, lane, per_lane, round_num),
			CONNECT_ONE_SHOT)


func _spawn_lane_wave_count(scene: PackedScene, team: int, lane: int,
		count: int, round_num: int) -> void:
	var team_idx  : int   = 0 if team == 1 else 1
	var paths     : Array = _lane_paths[team_idx]
	if paths.is_empty() or lane >= paths.size(): return
	var waypoints : Array = paths[lane]
	if waypoints.is_empty(): return
	const _CASTLE_R : float = 16.0
	var _b0 : Vector3 = waypoints[0]
	var _si : int = 1
	for _wi2 in range(1, waypoints.size()):
		if _b0.distance_to(waypoints[_wi2]) >= _CASTLE_R: _si = _wi2; break
	var spawn_pos  : Vector3 = waypoints[_si]
	var march_wps  : Array   = waypoints.slice(_si)
	var enemy_base : Node3D  = _base2 if team == 1 else _base1
	var friendly   : Node3D  = _base1 if team == 1 else _base2
	# Scale damage slightly with round number
	for i in count:
		get_tree().create_timer(spawn_stagger * i).timeout.connect(func():
			if not is_inside_tree(): return
			var creep := _spawn_creep(scene, team, spawn_pos, march_wps,
				enemy_base, friendly, i, lane)
			if is_instance_valid(creep) and round_num > 1:
				# Scale creep stats with round
				var bonus : float = float(round_num - 1) * 0.15
				if "damage"     in creep: creep.set("damage",     float(creep.get("damage"))     * (1.0 + bonus))
				if "max_health" in creep: creep.set("max_health", float(creep.get("max_health")) * (1.0 + bonus * 0.5))
				if "health"     in creep: creep.set("health",     creep.get("max_health")),
			CONNECT_ONE_SHOT)


# ── Player creep queue for timed wave deployment ─────────────
# Format: {team: int, scene: PackedScene, wave: int, lane: int}
var _player_queue : Array = []


func get_scene_for_id(creep_id: String, team: int) -> PackedScene:
	# Try CreepDeckManager first, then fall back to team scene
	var dm := get_tree().get_first_node_in_group("creep_deck_manager")
	if is_instance_valid(dm) and dm.has_method("get_scene_for_creep"):
		var sc : PackedScene = dm.get_scene_for_creep(creep_id)
		if is_instance_valid(sc): return sc
	return _get_scene(team)

func queue_player_creep(team: int, scene: PackedScene, wave: int, creep_id: String = "", defend: bool = false) -> void:
	var lane : int = randi_range(0, LANE_COUNT - 1)
	_player_queue.append({"team": team, "scene": scene, "wave": wave, "lane": lane, "id": creep_id, "defend": defend})
	print("[LaneSpawner] Queued %s creep for T%d wave %d lane %d" % ["DEFENSE" if defend else "attack", team, wave, lane])

func get_player_queue_count(team: int) -> int:
	var count := 0
	for q in _player_queue:
		if q["team"] == team: count += 1
	return count

func _deploy_queued_for_wave(wave_num: int) -> void:
	var to_deploy : Array = []
	var remaining : Array = []
	for q in _player_queue:
		if int(q["wave"]) == wave_num: to_deploy.append(q)
		else: remaining.append(q)
	_player_queue = remaining
	for q in to_deploy:
		var scene : PackedScene = q["scene"]
		var team  : int         = q["team"]
		var lane  : int         = q["lane"]
		var creep_id : String = q.get("id", "")
		# Always try ID-based resolution (handles script-only creeps like Tank)
		if creep_id != "":
			var id_scene := _resolve_scene_for_id(creep_id, team)
			if is_instance_valid(id_scene): scene = id_scene
		if not is_instance_valid(scene): continue
		var team_idx : int = 0 if team == 1 else 1
		var paths : Array = _lane_paths[team_idx]
		if paths.is_empty() or lane >= paths.size(): continue
		var waypoints : Array = paths[lane]
		if waypoints.is_empty(): continue
		const _CR3 : float = 16.0
		var _b03 : Vector3 = waypoints[0]; var _si3 : int = 1
		for _wi4 in range(1, waypoints.size()):
			if _b03.distance_to(waypoints[_wi4]) >= _CR3: _si3 = _wi4; break
		var spawn_pos  : Vector3 = waypoints[_si3]
		var march_wps  : Array = waypoints.slice(_si3)
		var enemy_base : Node3D = _base2 if team == 1 else _base1
		var friendly   : Node3D = _base1 if team == 1 else _base2
		# Defense creeps: use base-adjacent spawn position
		var is_def : bool = q.get("defend", false)
		var actual_spawn := spawn_pos
		if is_def and is_instance_valid(friendly):
			var def_angle := randf() * TAU
			actual_spawn = friendly.global_position + Vector3(cos(def_angle), 0, sin(def_angle)) * 10.0
		var creep2 := _spawn_creep(scene, team, actual_spawn, march_wps, enemy_base, friendly, 0, lane)
		if is_instance_valid(creep2):
			_apply_creep_profile(creep2, creep_id if creep_id != "" else "zombie", 1, enemy_base, march_wps, lane)
		print("[LaneSpawner] Deployed queued creep T%d wave%d lane%d id=%s" % [team, wave_num, lane, creep_id])


# Called by GamePhaseController on the player's chosen wave
# Triggers the shop/creep queue to deploy staged units
func deploy_player_wave(team: int) -> void:
	# Notify any queued creeps to launch now
	for shop in get_tree().get_nodes_in_group("shop"):
		if shop.has_method("deploy_staged_units"):
			shop.call("deploy_staged_units", team)
	print("[LaneSpawner] Player team %d deploy triggered" % team)

func set_wave_interval(t: float) -> void:
	wave_interval = t

func get_lane_waypoints(team: int, lane: int) -> Array:
	var idx : int = 0 if team == 1 else 1
	if idx < _lane_paths.size() and lane < _lane_paths[idx].size():
		return _lane_paths[idx][lane]
	return []
