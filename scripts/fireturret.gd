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

@onready var muzzle : Node3D = $Muzzle


func _ready() -> void:
	_base_ready()
	damage = base_damage
	# Fire turret is lighter but faster — less base health
	max_health = 150.0
	health     = max_health


func _process(delta: float) -> void:
	fire_timer -= delta
	_find_target()
	if is_instance_valid(target):
		_face_target()
		if fire_timer <= 0.0:
			_shoot()
			fire_timer = fire_rate


func _find_target() -> void:
	var closest : Node3D = null
	var closest_dist : float = range
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or u == self: continue
		if u.is_in_group("bases") or u.is_in_group("towers"): continue
		if not ("team_id" in u) or u.team_id == team_id: continue
		var d : float = global_position.distance_to(u.global_position)
		if d < closest_dist:
			closest_dist = d; closest = u
	target = closest


func _shoot() -> void:
	if not projectile_scene or not is_instance_valid(target): return
	for i in range(burst_count):
		var p := projectile_scene.instantiate()
		get_tree().current_scene.add_child(p)
		p.global_position = muzzle.global_position
		var dir : Vector3 = (target.global_position - muzzle.global_position).normalized()
		dir.x += randf_range(-spread, spread)
		dir.y += randf_range(-spread * 0.5, spread * 0.5)
		dir.z += randf_range(-spread, spread)
		dir = dir.normalized()
		p.velocity = dir * projectile_speed
		p.damage   = damage
		p.team_id  = team_id
		p.shooter  = self


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
