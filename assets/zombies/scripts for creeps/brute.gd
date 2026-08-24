# ============================================================
# BruteCreep.gd — extends BaseZombie
# Charges in a straight line, trampling all in its path.
# ============================================================
extends BaseZombie
class_name BruteCreep

@export_group("Brute")
@export var charge_range    : float = 14.0
@export var charge_speed    : float = 18.0
@export var charge_damage   : float = 50.0
@export var charge_cooldown : float = 8.0
@export var charge_width    : float = 1.8
@export var stomp_radius    : float = 3.0
@export var stomp_damage    : float = 35.0
@export var stomp_cooldown  : float = 5.0

var _charge_timer  : float = 0.0
var _stomp_timer   : float = 0.0
var _is_charging   : bool  = false
var _charge_dir    := Vector3.ZERO
var _charge_left   : float = 0.0
var _stagger_timer : float = 0.0

const STAGGER_THRESHOLD : float = 0.10   # fraction of max_health that triggers stagger
const STAGGER_DURATION  : float = 0.08   # seconds of interrupt pause

func _ready() -> void:
	max_health      = 1000.0
	move_speed      = 2.0
	damage          = 30.0
	attack_range    = 2.5
	attack_cooldown = 1.8
	gold_reward     = 80
	armor_physical  = 12.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_charge_timer = randf_range(2.0, charge_cooldown)
	_stomp_timer  = randf_range(2.0, stomp_cooldown)

func _physics_process(delta: float) -> void:
	_stagger_timer = maxf(0.0, _stagger_timer - delta)
	if _stagger_timer > 0.0:
		# Interrupt pause: cancel any active charge, gravity only, bleed off velocity
		_is_charging = false
		if not is_on_floor(): velocity.y -= gravity * delta
		elif velocity.y < 0.0: velocity.y = 0.0
		velocity.x = lerpf(velocity.x, 0.0, 10.0 * delta)
		velocity.z = lerpf(velocity.z, 0.0, 10.0 * delta)
		move_and_slide()
		return
	if _is_charging:
		_do_charge_move(delta)
		return
	super._physics_process(delta)
	if _is_dead: return
	_charge_timer -= delta
	_stomp_timer  -= delta
	if _charge_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= charge_range and d > attack_range:
			_charge_timer = charge_cooldown
			_start_charge()
	if _stomp_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= attack_range + 1.0:
			_stomp_timer = stomp_cooldown
			_do_stomp()

func take_damage(amount: float, source) -> void:
	super.take_damage(amount, source)
	if amount > max_health * STAGGER_THRESHOLD:
		_stagger_timer = STAGGER_DURATION
		if is_instance_valid(_anim_tree):
			for hp: String in ["parameters/hurt_shot/request", "parameters/hit/request"]:
				_anim_tree.set(hp, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

func _start_charge() -> void:
	if not is_instance_valid(target): return
	_is_charging = true
	_charge_dir  = (target.global_position - global_position).normalized()
	_charge_left = charge_range
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var to_u := (u as Node3D).global_position - global_position
		if to_u.length() > charge_range: continue
		if abs(to_u.normalized().dot(_charge_dir)) < 0.8: continue
		if to_u.cross(_charge_dir).length() > charge_width: continue
		if u.has_method("take_damage"):
			u.take_damage(charge_damage, self)
			if u is CharacterBody3D: (u as CharacterBody3D).velocity += _charge_dir * 10.0
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(charge_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)

func _do_charge_move(delta: float) -> void:
	var step := charge_speed * delta
	global_position += _charge_dir * step
	_charge_left    -= step
	if _charge_left <= 0.0: _is_charging = false

func _do_stomp() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > stomp_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(stomp_damage, self)
			if u is CharacterBody3D:
				var kb := ((u as Node3D).global_position - global_position).normalized()
				(u as CharacterBody3D).velocity += kb * 7.0 + Vector3(0, 3.0, 0)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(stomp_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
