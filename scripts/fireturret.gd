# ============================================================
# FireTurret.gd
# ============================================================
extends BaseTurret
class_name FireTurret

@export var range            : float = 13.0
@export var fire_rate        : float = 0.25
@export var base_damage      : float = 6.0
@export var projectile_scene : PackedScene
@export var spread           : float = 0.08
@export var burst_count      : int   = 2
@export var projectile_speed : float = 20.0

var damage     : float = 0.0
var target     : Node3D = null
var fire_timer : float = 0.0

# Scene uses "Muzzle2" — try both names so the turret works regardless of scene variant
var muzzle : Node3D = null

# Targeting cache — rebuild every SCAN_RATE seconds instead of every _process frame
var _scan_timer  : float = 0.0
const SCAN_RATE  : float = 0.35


func _ready() -> void:
	_base_ready()
	damage    = base_damage
	max_health = 150.0
	health     = max_health
	# Resolve muzzle node — scene uses "Muzzle2" but guard against either name
	muzzle = get_node_or_null("Muzzle") as Node3D
	if not is_instance_valid(muzzle):
		muzzle = get_node_or_null("Muzzle2") as Node3D
	if not is_instance_valid(muzzle):
		# Last resort: use self as origin so turret still fires
		push_warning("[FireTurret] No Muzzle/Muzzle2 child found — using turret origin")
		muzzle = self


func _process(delta: float) -> void:
	fire_timer  -= delta
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_RATE
		_find_target()
	if is_instance_valid(target):
		if not is_instance_valid(target) or target.get("health") != null \
				and float(target.get("health")) <= 0.0:
			target = null; return
		_face_target()
		if fire_timer <= 0.0:
			_shoot()
			fire_timer = fire_rate


func _find_target() -> void:
	var closest      : Node3D = null
	var closest_dist : float  = range
	# Hive-defense turrets (hostile_to_players) guard eggs against the player
	# instead of defending the base against zombies -- scan players/units.
	var scan_groups : Array = ["players", "units"] if hostile_to_players else ["zombies"]
	for grp in scan_groups:
		for u in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(u) or not (u is Node3D): continue
			if u == self: continue
			if hostile_to_players and (u.is_in_group("turrets") or u.is_in_group("zombies")): continue
			if not ("team_id" in u) or int(u.get("team_id")) == team_id: continue
			var d : float = global_position.distance_to((u as Node3D).global_position)
			if d < closest_dist: closest_dist = d; closest = u as Node3D
	target = closest


func _shoot() -> void:
	if not is_instance_valid(projectile_scene) or not is_instance_valid(target): return
	var origin : Vector3 = muzzle.global_position if is_instance_valid(muzzle) \
		else global_position + Vector3.UP * 1.5
	for _i in range(burst_count):
		var p := projectile_scene.instantiate()
		get_tree().current_scene.add_child(p)
		var dir : Vector3 = (target.global_position - origin).normalized()
		dir.x += randf_range(-spread, spread)
		dir.y += randf_range(-spread * 0.5, spread * 0.5)
		dir.z += randf_range(-spread, spread)
		dir = dir.normalized()
		# FlameProjectile (and similar) requires init() to enable monitoring + physics.
		# Fall back to direct property assignment for generic projectile scenes.
		if p.has_method("init"):
			p.init(origin, dir * projectile_speed, self, team_id)
		else:
			p.global_position = origin
			if "velocity" in p: p.set("velocity", dir * projectile_speed)
			if "damage"   in p: p.set("damage",   damage)
			if "team_id"  in p: p.set("team_id",  team_id)
			if "shooter"  in p: p.set("shooter",  self)


## REAL BUG FIX (2026-07-25): "turret flips upside down when it shoots" -- the
## root node's transform in scenes/fire_turret.tscn had a NEGATIVE X scale
## (a mirrored transform). look_at() can't preserve mirroring -- it reads the
## scale's magnitude only (always positive) and reapplies it after rotating,
## so every call here silently un-mirrored the turret, which reads as a
## flip right as it starts tracking/firing a target. Fixed at the scene
## data level (dropped the negative sign, same scale magnitude) -- if this
## scene is ever re-exported/re-authored, keep all 3 axis scales positive.
func _face_target() -> void:
	var look_pos : Vector3 = target.global_position
	look_pos.y = global_position.y
	look_at(look_pos, Vector3.UP)


func upgrade() -> void:
	if level >= max_level: return
	level      += 1
	damage      = base_damage * _dmg_scale()
	fire_rate   = maxf(0.08, 0.25 * _rate_scale())
	range      += _range_bonus() / float(max_level - 1)
	burst_count = mini(burst_count + 1, 6)
	spread      = maxf(0.02, spread * 0.92)
	var new_max : float = 150.0 * _health_scale()
	health     = health * (new_max / max_health)
	max_health  = new_max
	armor       = (level - 1) * 2.0
	health_changed.emit(health, max_health)
	turret_upgraded.emit(self)


func get_upgrade_cost() -> int: return int(40 * pow(level, 1.5))
func get_cost()         -> int: return get_upgrade_cost()
func interact()               -> void: turret_selected.emit(self)
