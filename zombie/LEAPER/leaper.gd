# ============================================================
# LeaperCreep.gd — extends BaseZombie AAA
# Jumps to targets, slows on landing.
# ============================================================
extends "res://assets/weapons/resources/Player/zombie.gd"
class_name LeaperCreep

@export_group("Leaper")
@export var leap_range      : float = 12.0
@export var leap_min_range  : float = 2.5
@export var leap_cooldown   : float = 6.0
@export var leap_arc_height : float = 7.0
@export var slow_factor     : float = 0.45
@export var slow_duration   : float = 2.5
@export var leap_sounds     : Array[AudioStream] = []
@export var land_sounds     : Array[AudioStream] = []

var _leap_timer   : float  = 0.0
var _is_leaping   : bool   = false
var _leap_origin  : Vector3 = Vector3.ZERO
var _leap_dest    : Vector3 = Vector3.ZERO
var _leap_elapsed : float  = 0.0
var _leap_dur     : float  = 0.0

func _ready() -> void:
	max_health      = 160.0
	move_speed      = 5.5
	damage          = 20.0
	attack_range    = 1.8
	attack_cooldown = 1.0
	gold_reward     = 40
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")  # enables enchant + ZHM systems
	_leap_timer = randf_range(1.0, leap_cooldown)

func _physics_process(delta: float) -> void:
	if is_dead: return
	if _is_leaping:
		_tick_leap(delta)
		move_and_slide()
		return
	super._physics_process(delta)
	_leap_timer -= delta
	if _leap_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d >= leap_min_range and d <= leap_range:
			_start_leap(target.global_position)

func _start_leap(dest: Vector3) -> void:
	_is_leaping   = true
	_leap_origin  = global_position
	_leap_dest    = dest
	_leap_elapsed = 0.0
	var dist      := _leap_origin.distance_to(_leap_dest)
	_leap_dur     = dist / 18.0
	_leap_timer   = leap_cooldown
	_play_sound(leap_sounds, 6.0)

func _tick_leap(delta: float) -> void:
	_leap_elapsed += delta
	var t := clampf(_leap_elapsed / maxf(_leap_dur, 0.01), 0.0, 1.0)
	var flat := _leap_origin.lerp(_leap_dest, t)
	var arc  := sin(t * PI) * leap_arc_height
	global_position = Vector3(flat.x, flat.y + arc, flat.z)
	velocity        = Vector3.ZERO
	if t >= 1.0:
		_is_leaping = false
		_play_sound(land_sounds, 5.0)
		# Slow all enemies near landing zone
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			if u.global_position.distance_to(_leap_dest) > 2.5: continue
			if u.has_method("apply_status"):
				u.apply_status(StatusType.SLOW, slow_duration, slow_factor)
			if u.has_method("take_damage"):
				u.take_damage(damage * 1.5, self)
