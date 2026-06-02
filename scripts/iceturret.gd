# ============================================================
# IceTurret.gd
# ============================================================
extends BaseTurret
class_name IceTurret

@export var range            : float = 14.0
@export var fire_rate        : float = 0.7
@export var base_damage      : float = 8.0
@export var projectile_scene : PackedScene
@export var slow_amount      : float = 0.4
@export var slow_duration    : float = 1.5
@export var freeze_chance    : float = 0.15

var damage     : float = 0.0
var target     : Node3D = null
var fire_timer : float = 0.0

@onready var muzzle : Node3D = $Muzzle


func _ready() -> void:
	_base_ready()
	damage = base_damage
	# Ice turret — tankiest, slowest
	max_health = 280.0
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
	var p := projectile_scene.instantiate()
	get_tree().current_scene.add_child(p)
	p.global_position = muzzle.global_position
	var dir : Vector3 = (target.global_position - muzzle.global_position).normalized()
	p.direction    = dir
	p.damage       = damage
	p.team_id      = team_id
	p.slow_amount  = slow_amount
	p.slow_duration = slow_duration
	p.freeze       = randf() < freeze_chance


func _face_target() -> void:
	if not is_instance_valid(target): return
	var look_pos : Vector3 = target.global_position
	look_pos.y = global_position.y
	look_at(look_pos, Vector3.UP)


func upgrade() -> void:
	if level >= max_level:
		push_warning("[IceTurret] Max level reached.")
		return
	level        += 1
	damage        = base_damage * _dmg_scale()
	fire_rate     = maxf(0.3, 0.7 * _rate_scale())
	range        += _range_bonus() / float(max_level - 1)
	slow_amount   = minf(0.80, slow_amount + 0.06)
	slow_duration += 0.25
	freeze_chance = minf(0.55, freeze_chance + 0.06)
	var new_max : float = 280.0 * _health_scale()
	health      = health * (new_max / max_health)
	max_health   = new_max
	armor        = (level - 1) * 4.0   # ice turret is the tankiest
	health_changed.emit(health, max_health)
	turret_upgraded.emit(self)


func get_upgrade_cost() -> int: return int(60 * pow(level, 1.5))
func get_cost()         -> int: return get_upgrade_cost()
func interact()               -> void: turret_selected.emit(self)
