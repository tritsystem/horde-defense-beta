# ============================================================
# MagnetCreep.gd — extends BaseZombie
# Pulls enemies toward it. Disarms ranged units (cancels attacks).
# ============================================================
extends BaseZombie
class_name MagnetCreep

@export_group("Magnet")
@export var pull_radius    : float = 9.0
@export var pull_force     : float = 12.0
@export var pull_cooldown  : float = 6.0
@export var disarm_range   : float = 11.0
@export var disarm_duration: float = 3.0
@export var disarm_cooldown: float = 10.0
@export var pulse_radius   : float = 4.0
@export var pulse_damage   : float = 25.0
@export var pulse_cooldown : float = 5.0

var _pull_timer   : float = 0.0
var _disarm_timer : float = 0.0
var _pulse_timer  : float = 0.0

func _ready() -> void:
	max_health      = 550.0
	move_speed      = 1.9
	damage          = 20.0
	attack_range    = 2.2
	attack_cooldown = 1.4
	gold_reward     = 70
	armor_physical  = 8.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_pull_timer   = randf_range(1.0, pull_cooldown)
	_disarm_timer = randf_range(3.0, disarm_cooldown)
	_pulse_timer  = randf_range(2.0, pulse_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_pull_timer   -= delta
	_disarm_timer -= delta
	_pulse_timer  -= delta
	if _pull_timer <= 0.0:
		_pull_timer = pull_cooldown
		_do_pull()
	if _disarm_timer <= 0.0:
		_disarm_timer = disarm_cooldown
		_do_disarm()
	if _pulse_timer <= 0.0:
		_pulse_timer = pulse_cooldown
		_do_pulse()

func _do_pull() -> void:
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var d := (u as Node3D).global_position.distance_to(global_position)
		if d > pull_radius or d < 1.5: continue
		var pull_dir := (global_position - (u as Node3D).global_position).normalized()
		if u is CharacterBody3D:
			(u as CharacterBody3D).velocity += pull_dir * pull_force
		elif "move_speed" in u:
			# Fallback: teleport nudge
			(u as Node3D).global_position += pull_dir * 1.5

func _do_disarm() -> void:
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > disarm_range: continue
		# Force attack cooldown to max — effectively disarms
		if "attack_cooldown_remaining" in u:
			u.set("attack_cooldown_remaining", disarm_duration)
		elif "attack_cooldown" in u:
			var orig : float = u.get("attack_cooldown")
			u.set("attack_cooldown", orig + disarm_duration)
			get_tree().create_timer(disarm_duration).timeout.connect(
				func(): if is_instance_valid(u): u.set("attack_cooldown", orig), CONNECT_ONE_SHOT)

func _do_pulse() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > pulse_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(pulse_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(pulse_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
