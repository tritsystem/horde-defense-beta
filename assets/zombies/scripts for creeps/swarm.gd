# ============================================================
# SwarmCreep.gd — extends BaseZombie
# Splits into several smaller SwarmlingCreep on death.
# Swarmlings are weaker and do NOT split again.
# ============================================================
extends BaseZombie
class_name SwarmCreep

@export_group("Swarm")
@export var swarmling_scene : PackedScene
@export var split_count     : int   = 4
@export var is_swarmling    : bool  = false   # set true on spawned children
@export var infect_range    : float = 2.5
@export var infect_damage   : float = 8.0
@export var infect_cooldown : float = 3.0

var _infect_timer : float = 0.0

func _ready() -> void:
	if is_swarmling:
		max_health      = 100.0
		move_speed      = 4.0
		damage          = 10.0
		attack_range    = 1.8
		attack_cooldown = 0.9
		gold_reward     = 10
		armor_physical  = 0.0
	else:
		max_health      = 450.0
		move_speed      = 2.5
		damage          = 18.0
		attack_range    = 2.0
		attack_cooldown = 1.2
		gold_reward     = 55
		armor_physical  = 4.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_infect_timer = randf_range(1.0, infect_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_infect_timer -= delta
	if _infect_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= infect_range:
			_infect_timer = infect_cooldown
			_do_infect()

func _do_infect() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > infect_range: continue
		if u.has_method("take_damage"):
			u.take_damage(infect_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(infect_damage, (u as Node3D).global_position + Vector3(0,1.2,0), 3, false)

func die() -> void:
	if not is_swarmling and is_instance_valid(swarmling_scene):
		for i in split_count:
			var s := swarmling_scene.instantiate() as SwarmCreep
			get_tree().current_scene.add_child(s)
			var angle := (TAU / split_count) * i
			s.global_position = global_position + Vector3(cos(angle), 0, sin(angle)) * 1.2
			if "team_id"      in s: s.set("team_id", team_id)
			if "is_swarmling" in s: s.set("is_swarmling", true)
	super.die()
