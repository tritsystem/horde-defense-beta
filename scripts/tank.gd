# ============================================================
# TankCreep.gd — extends BaseZombie AAA
# Heavy frontliner. Taunts enemies, ground-slam AoE.
# ============================================================
extends "res://assets/weapons/resources/Player/zombie.gd"

@export_group("Tank")
@export var taunt_radius   : float = 8.0
@export var taunt_cooldown : float = 8.0
@export var taunt_duration : float = 3.5
@export var slam_radius    : float = 3.5
@export var slam_damage    : float = 40.0
@export var slam_cooldown  : float = 6.0

var _taunt_timer : float = 0.0
var _slam_timer  : float = 0.0
var _is_taunting : bool  = false

func _ready() -> void:
	max_health      = 1200.0
	move_speed      = 1.6
	damage          = 22.0
	attack_range    = 2.6
	attack_cooldown = 1.8
	gold_reward     = 75
	armor_physical  = 15.0
	armor_slash     = 10.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_taunt_timer = randf_range(2.0, taunt_cooldown)
	_slam_timer  = randf_range(3.0, slam_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_taunt_timer -= delta
	_slam_timer  -= delta
	if _taunt_timer <= 0.0:
		_taunt_timer = taunt_cooldown
		_do_taunt()
	if _slam_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= slam_radius + 0.5:
			_slam_timer = slam_cooldown
			_do_slam()

func _do_taunt() -> void:
	_is_taunting = true
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if u.global_position.distance_to(global_position) > taunt_radius: continue
		if u.has_method("set_forced_target"):
			u.set_forced_target(self, taunt_duration)
		elif "target" in u:
			u.set("target", self)
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(dn) and dn.has_method("spawn_number"):
		dn.spawn_number(0, global_position + Vector3(0, 2.8, 0), 0, false)
	get_tree().create_timer(taunt_duration).timeout.connect(
		func(): _is_taunting = false, CONNECT_ONE_SHOT)

func _do_slam() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if u.global_position.distance_to(global_position) > slam_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(slam_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(slam_damage, u.global_position + Vector3(0,1.5,0), 0, false)
		var kb_dir : Vector3 = (u as Node3D).global_position - global_position
		kb_dir.y = 0.3
		if u is CharacterBody3D: (u as CharacterBody3D).velocity += kb_dir.normalized() * 8.0
