class_name Egg
extends Node3D
# Destructible egg that hatches a wave of creeps at its world position.
#
# Performance design:
#   - _process is DISABLED by default; a SceneTreeTimer loop re-enables it
#     only when the camera is within LOD_HALF (150 m).
#   - Hatch countdown runs via SceneTreeTimer, not _process — zero cost when
#     the egg is off-screen.
#   - Proximity activation: hatch timer only starts when the camera enters
#     _activation_dist (tier-dependent; tier 1 ~210 m, tier 5 ~90 m). This
#     keeps far/strong eggs dormant until the player pushes deep.
#
# Unit cap: never spawns more than MAX_HIVE_UNITS total live hive units.
#
# EGG TYPES:
#   NORMAL  — standard egg
#   GAS     — releases a slowing cloud on hatch
#   MIMIC   — disguised as a pickup item until damaged
#   QUEEN   — hatches faster, calls reinforcement wave after hatch

@export var tier       : int   = 1
@export var max_hp     : float = 80.0
@export var hatch_time : float = 60.0

enum EggType { NORMAL, GAS, MIMIC, QUEEN }
@export var egg_type : EggType = EggType.NORMAL

# Set by HiveCluster before adding to tree
var wave_size     : int    = 4
var attack_target : Node3D = null
var creep_ids     : Array  = ["zombie"]

signal hatched(egg: Node3D)
signal egg_destroyed(egg: Node3D)
signal tier_evolved(egg: Node3D, new_tier: int)

var health : float = 0.0

# Tier evolution — eggs automatically upgrade every TIER_EVOLVE_INTERVAL seconds
const TIER_EVOLVE_INTERVAL : float = 45.0
const MAX_EVOLVED_TIER     : int   = 3
var _tier_evolve_elapsed   : float = 0.0
var _mimic_revealed        : bool  = false

var _mat            : StandardMaterial3D = null
var _done           : bool  = false
var _hatch_started  : bool  = false
var _hatch_at_time  : float = -1.0   # OS time (secs) when hatch fires
var _lod_level      : int   = 2      # start dormant; poll loop changes this
var _activation_dist: float = 150.0  # computed from tier in _ready

var _hp_bar_root : Node3D          = null
var _hp_fill_mat : StandardMaterial3D = null
var _hp_fill_mi  : MeshInstance3D  = null
var _hp_label    : Label3D         = null

const HATCH_SCENE    : String = "res://zombie/zombie.tscn"
const LOD_FULL       : float  = 60.0
const LOD_HALF       : float  = 150.0
const MAX_HIVE_UNITS : int    = 100

const CREEP_PROFILES : Dictionary = {
	"zombie":      {"hp": 1.0,  "spd": 1.0,  "dmg": 1.0},
	"leaper":      {"hp": 0.7,  "spd": 1.6,  "dmg": 0.9},
	"berserker":   {"hp": 1.4,  "spd": 1.2,  "dmg": 1.5},
	"ghost":       {"hp": 0.8,  "spd": 1.4,  "dmg": 1.2},
	"assassin":    {"hp": 0.9,  "spd": 1.8,  "dmg": 1.6},
	"titan":       {"hp": 4.0,  "spd": 0.7,  "dmg": 3.0},
	"necromancer": {"hp": 1.2,  "spd": 0.9,  "dmg": 1.4},
}


func _ready() -> void:
	health = max_hp
	# tier 1 (near player) activates at 210 m; tier 5 (deep) at 90 m
	_activation_dist = 240.0 - float(tier) * 30.0
	_build_visual()
	_build_collision()
	_build_hp_bar()
	add_to_group("eggs")
	set_process(false)
	_schedule_poll()
	_apply_egg_type_visual()


func _schedule_poll() -> void:
	get_tree().create_timer(1.5).timeout.connect(_lod_poll)


func _lod_poll() -> void:
	if _done: return
	var dist : float = _cam_dist()
	# Update LOD level and toggle _process
	if dist < LOD_FULL:
		_lod_level = 0
		set_process(true)
	elif dist < LOD_HALF:
		_lod_level = 1
		set_process(true)
	else:
		_lod_level = 2
		set_process(false)
	# HP bar visible only within LOD range
	if is_instance_valid(_hp_bar_root):
		_hp_bar_root.visible = (_lod_level < 2)
	# Start hatch timer once when player enters activation range
	if not _hatch_started and dist < _activation_dist:
		_hatch_started  = true
		_hatch_at_time  = Time.get_ticks_msec() / 1000.0 + hatch_time
		get_tree().create_timer(hatch_time).timeout.connect(_do_hatch)
	_schedule_poll()


func _cam_dist() -> float:
	var vp := get_viewport()
	if not vp: return 9999.0
	var cam := vp.get_camera_3d()
	if not is_instance_valid(cam): return 9999.0
	return global_position.distance_to(cam.global_position)


# ── Visual mesh ──────────────────────────────────────────────
func _build_visual() -> void:
	var mi   := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.60 + tier * 0.08
	mesh.height = mesh.radius * 1.55
	mi.mesh = mesh
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.10, 0.30, 0.07)
	_mat.roughness    = 0.88
	mi.material_override = _mat
	mi.position.y = mesh.height * 0.5
	add_child(mi)


func _build_hp_bar() -> void:
	var egg_height : float = (0.60 + tier * 0.08) * 1.55 + 0.3
	_hp_bar_root = Node3D.new()
	_hp_bar_root.position.y = egg_height + 0.35
	add_child(_hp_bar_root)

	var bar_w : float = 1.0
	var bar_h : float = 0.13

	# Background (dark grey)
	var bg_mi   := MeshInstance3D.new()
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(bar_w, bar_h)
	bg_mi.mesh   = bg_mesh
	var bg_mat   := StandardMaterial3D.new()
	bg_mat.albedo_color         = Color(0.15, 0.15, 0.15, 0.85)
	bg_mat.transparency         = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.billboard_mode       = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.shading_mode         = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.no_depth_test        = true
	bg_mi.material_override     = bg_mat
	_hp_bar_root.add_child(bg_mi)

	# Fill (coloured; scaled on x)
	_hp_fill_mi            = MeshInstance3D.new()
	var fill_mesh          := QuadMesh.new()
	fill_mesh.size          = Vector2(bar_w, bar_h)
	_hp_fill_mi.mesh        = fill_mesh
	_hp_fill_mat            = StandardMaterial3D.new()
	_hp_fill_mat.albedo_color   = Color(0.18, 0.75, 0.18)
	_hp_fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hp_fill_mat.no_depth_test  = true
	_hp_fill_mi.material_override = _hp_fill_mat
	_hp_bar_root.add_child(_hp_fill_mi)

	# Numeric label
	_hp_label              = Label3D.new()
	_hp_label.text         = "%d" % int(max_hp)
	_hp_label.font_size    = 18
	_hp_label.modulate     = Color(1, 1, 1, 0.95)
	_hp_label.position.y   = bar_h + 0.12
	_hp_label.billboard    = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.no_depth_test = true
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_bar_root.add_child(_hp_label)


func _build_collision() -> void:
	var body  := StaticBody3D.new()
	var coll  := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius    = 0.70 + tier * 0.05
	coll.shape      = shape
	body.position.y = shape.radius
	body.add_child(coll)
	add_child(body)


# ── _process: visual only, only runs when LOD level < 2 ──────
func _process(delta: float) -> void:
	if _done or not is_instance_valid(_mat): return
	var ratio : float = 0.0
	if _hatch_at_time > 0.0:
		var remaining : float = _hatch_at_time - Time.get_ticks_msec() / 1000.0
		ratio = clampf(1.0 - remaining / hatch_time, 0.0, 1.0)

	# Tier evolution — only while hatch timer is running
	if _hatch_started and tier < MAX_EVOLVED_TIER:
		_tier_evolve_elapsed += delta
		if _tier_evolve_elapsed >= TIER_EVOLVE_INTERVAL:
			_tier_evolve_elapsed = 0.0
			_evolve_tier()

	_mat.albedo_color = Color(0.10, 0.30, 0.07).lerp(Color(0.65, 0.15, 0.02), ratio)

	if _lod_level == 0:
		_mat.emission_enabled = ratio > 0.5
		if ratio > 0.5:
			var pulse : float = sin(Time.get_ticks_msec() * 0.006) * 0.15
			_mat.emission = Color(1.0, 0.25, 0.0) * ((ratio - 0.5) * 0.7 + pulse)
		if ratio > 0.80:
			scale = Vector3.ONE * (1.0 + sin(Time.get_ticks_msec() * 0.009) * 0.06)

	# HP bar: visible when within LOD range
	_update_hp_bar()


func _update_hp_bar() -> void:
	if not is_instance_valid(_hp_fill_mi): return
	var pct : float = clampf(health / max_hp, 0.0, 1.0)
	# Scale fill on X axis; offset so it grows from left edge
	_hp_fill_mi.scale.x    = pct
	_hp_fill_mi.position.x = (pct - 1.0) * 0.5   # keep left-aligned
	# Colour: green → yellow → red
	if is_instance_valid(_hp_fill_mat):
		if pct > 0.5:
			_hp_fill_mat.albedo_color = Color(0.18, 0.75, 0.18).lerp(Color(0.9, 0.8, 0.0), (1.0 - pct) * 2.0)
		else:
			_hp_fill_mat.albedo_color = Color(0.9, 0.8, 0.0).lerp(Color(0.85, 0.1, 0.05), (0.5 - pct) * 2.0)


# ── Damage ────────────────────────────────────────────────────
func take_damage(amount: float, _source = null) -> void:
	if _done: return
	if egg_type == EggType.MIMIC: _reveal_mimic()
	health -= amount
	if is_instance_valid(_hp_label):
		_hp_label.text = "%d" % maxi(0, int(health))
	_update_hp_bar()
	if health <= 0.0:
		_done = true
		_reveal_on_map(35.0)
		egg_destroyed.emit(self)
		queue_free()


func _reveal_on_map(radius: float) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("reveal_minimap_area"):
			hud.call("reveal_minimap_area", global_position, radius)


# ── Hatch ─────────────────────────────────────────────────────
func _do_hatch() -> void:
	if _done: return   # take_damage may have already destroyed it
	_done = true
	_spawn_wave()
	match egg_type:
		EggType.GAS:   _on_gas_hatch()
		EggType.QUEEN: _on_queen_hatch()
	hatched.emit(self)
	queue_free()


func _spawn_wave() -> void:
	if not ResourceLoader.exists(HATCH_SCENE): return
	var packed : PackedScene = load(HATCH_SCENE) as PackedScene
	if not is_instance_valid(packed): return

	var current_count : int = get_tree().get_nodes_in_group("hive_unit").size()
	var can_spawn     : int = maxi(0, MAX_HIVE_UNITS - current_count)
	if can_spawn == 0:
		print("[Egg T%d] Unit cap reached — wave skipped" % tier)
		return

	var actual_wave : int   = mini(wave_size, can_spawn)
	# Tier 1 = base stats (1.0×), scales to 1.8× at tier 5 — gradual progression
	var tier_mult   : float = 1.0 + float(tier - 1) * 0.20

	for _i in actual_wave:
		var id   : String     = creep_ids[randi() % creep_ids.size()]
		var prof : Dictionary = CREEP_PROFILES.get(id, CREEP_PROFILES["zombie"])
		var creep : Node = packed.instantiate()
		if not is_instance_valid(creep): continue

		if "team_id"    in creep: creep.set("team_id", 2)
		if "enemy_base" in creep and is_instance_valid(attack_target):
			creep.set("enemy_base", attack_target)

		var base_hp  : float = float(creep.get("max_health")) if "max_health" in creep else 100.0
		var base_spd : float = float(creep.get("move_speed")) if "move_speed"  in creep else 2.5
		var base_dmg : float = float(creep.get("damage"))     if "damage"      in creep else 10.0

		if "max_health" in creep: creep.set("max_health", base_hp  * prof["hp"]  * tier_mult)
		if "health"     in creep: creep.set("health",     base_hp  * prof["hp"]  * tier_mult)
		if "move_speed" in creep: creep.set("move_speed", base_spd * prof["spd"])
		if "damage"     in creep: creep.set("damage",     base_dmg * prof["dmg"] * tier_mult)

		creep.add_to_group("hive_unit")
		get_tree().current_scene.add_child(creep)
		if creep is Node3D:
			var spread : Vector3 = Vector3(randf_range(-2.5, 2.5), 0.2, randf_range(-2.5, 2.5))
			(creep as Node3D).global_position = global_position + spread

	print("[Egg T%d] Hatched — %d units (cap: %d/%d)" % [tier, actual_wave, current_count + actual_wave, MAX_HIVE_UNITS])


# ── Tier evolution ───────────────────────────────────────────
func _evolve_tier() -> void:
	tier += 1
	# Scale HP up with the new tier
	var hp_ratio : float = health / max_hp
	max_hp  = max_hp * 1.35
	health  = max_hp * hp_ratio
	# Rebuild collision shape for new size
	_activation_dist = 240.0 - float(tier) * 30.0
	# Flash orange to signal evolution
	if is_instance_valid(_mat):
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.55, 0.0) * 2.0
		get_tree().create_timer(0.6).timeout.connect(func():
			if is_instance_valid(_mat): _mat.emission = Color.BLACK; _mat.emission_enabled = false)
	tier_evolved.emit(self, tier)
	_announce_evolution()
	print("[Egg] Evolved to Tier %d at pos %s" % [tier, str(global_position.snapped(Vector3.ONE))])


func _announce_evolution() -> void:
	var msg := "⚠ Egg evolved to Tier %d!" % tier
	var col := Color(1.0, 0.6, 0.1) if tier == 2 else Color(1.0, 0.2, 0.1)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(msg, col)


# ── Egg type visuals & behaviours ───────────────────────────
func _apply_egg_type_visual() -> void:
	if not is_instance_valid(_mat): return
	match egg_type:
		EggType.GAS:
			_mat.albedo_color = Color(0.20, 0.55, 0.12)
			_mat.emission_enabled = true
			_mat.emission = Color(0.1, 0.8, 0.1) * 0.3
		EggType.MIMIC:
			# Disguise as a gold coin pile — switch to yellow; hide HP bar
			_mat.albedo_color = Color(0.9, 0.75, 0.1)
			if is_instance_valid(_hp_bar_root): _hp_bar_root.visible = false
		EggType.QUEEN:
			_mat.albedo_color = Color(0.55, 0.05, 0.35)
			_mat.emission_enabled = true
			_mat.emission = Color(0.8, 0.1, 0.6) * 0.4


func _on_gas_hatch() -> void:
	# Spawn a slowing gas cloud (represented as an Area3D that slows nearby players)
	var area := Area3D.new()
	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 6.0
	cshape.shape = sphere
	area.add_child(cshape)
	area.position = global_position
	area.add_to_group("gas_cloud")
	# Metadata for the player to read speed penalty
	area.set_meta("slow_factor", 0.45)
	area.set_meta("lifetime", 12.0)
	get_tree().current_scene.add_child(area)
	# Auto-destroy after lifetime
	get_tree().create_timer(12.0).timeout.connect(area.queue_free)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message("☣ Gas cloud!", Color(0.3, 0.9, 0.3))


func _on_queen_hatch() -> void:
	# Spawn a reinforcement wave 8 seconds after queen hatches
	get_tree().create_timer(8.0).timeout.connect(func():
		if _done:
			_spawn_wave()
			for hud in get_tree().get_nodes_in_group("hud"):
				if hud.has_method("show_message"): hud.show_message("👑 Queen reinforcements!", Color(1.0, 0.2, 0.8)))


# Override take_damage to reveal Mimic on first hit
func _reveal_mimic() -> void:
	if _mimic_revealed: return
	_mimic_revealed = true
	if is_instance_valid(_mat):
		_mat.albedo_color = Color(0.10, 0.30, 0.07)
		_mat.emission_enabled = false
	if is_instance_valid(_hp_bar_root): _hp_bar_root.visible = true
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message("⚠ Mimic Egg revealed!", Color(1.0, 0.85, 0.1))
