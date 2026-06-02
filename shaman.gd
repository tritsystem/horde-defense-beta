# ============================================================
# ShamanCreep.gd — extends BaseZombie AAA
# Heals nearby friendly units. Applies poison aura to enemies.
# ============================================================
extends "res://assets/weapons/resources/Player/zombie.gd"
class_name ShamanCreep

@export_group("Shaman")
@export var heal_radius     : float = 7.0
@export var heal_amount     : float = 50.0
@export var heal_cooldown   : float = 3.5
@export var poison_radius   : float = 5.0
@export var poison_damage   : float = 4.0
@export var poison_duration : float = 5.0
@export var heal_sounds     : Array[AudioStream] = []

var _heal_timer   : float = 0.0
var _poison_timer : float = 0.0

func _ready() -> void:
	max_health      = 220.0
	move_speed      = 2.8
	damage          = 8.0
	attack_range    = 2.0
	attack_cooldown = 1.4
	gold_reward     = 55
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_heal_timer   = randf_range(1.0, heal_cooldown)
	_poison_timer = randf_range(2.0, 5.0)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_heal_timer   -= delta
	_poison_timer -= delta
	if _heal_timer <= 0.0:
		_heal_timer = heal_cooldown
		_do_heal_pulse()
	if _poison_timer <= 0.0:
		_poison_timer = randf_range(4.0, 7.0)
		_do_poison_aura()

func _do_heal_pulse() -> void:
	var healed := 0
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) != team_id: continue
		if u == self: continue
		var d := global_position.distance_to((u as Node3D).global_position)
		if d > heal_radius: continue
		if u.has_method("_heal"):
			u._heal(heal_amount)
		elif "health" in u and "max_health" in u:
			u.set("health", minf(float(u.get("health")) + heal_amount, float(u.get("max_health"))))
		# Green heal number
		var dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(heal_amount, (u as Node3D).global_position + Vector3(0, 2.2, 0), 3, false)
		healed += 1
	if healed > 0:
		_play_sound(heal_sounds, 5.0)

func _do_poison_aura() -> void:
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var d := global_position.distance_to((u as Node3D).global_position)
		if d > poison_radius: continue
		if u.has_method("apply_status"):
			u.apply_status(StatusType.POISON, poison_duration, poison_damage)
		# Poison number
		var dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(poison_damage, (u as Node3D).global_position + Vector3(0,2.0,0), 3, false)
