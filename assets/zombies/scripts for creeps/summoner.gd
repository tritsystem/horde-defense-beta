# ============================================================
# SummonerCreep.gd — extends BaseZombie
# Periodically spawns small minions. Hangs back from combat.
# ============================================================
extends BaseZombie
class_name SummonerCreep

@export_group("Summoner")
@export var summon_scene    : PackedScene  # assign a small zombie scene
@export var summon_cooldown : float = 10.0
@export var max_summons     : int   = 4
@export var summon_radius   : float = 3.0
@export var preferred_dist  : float = 12.0  # stays back

var _summon_timer  : float = 0.0
var _active_summons: Array  = []

func _ready() -> void:
	max_health      = 350.0
	move_speed      = 1.9
	damage          = 8.0
	attack_range    = 2.0
	attack_cooldown = 2.0
	gold_reward     = 85
	armor_physical  = 4.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_summon_timer = randf_range(2.0, summon_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	# Clean up dead summons
	_active_summons = _active_summons.filter(func(s): return is_instance_valid(s) and not s.get("is_dead"))
	# Stay back from target
	if is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d < preferred_dist - 2.0:
			var flee := (global_position - target.global_position).normalized()
			velocity += flee * move_speed * delta * 60.0
	_summon_timer -= delta
	if _summon_timer <= 0.0:
		_summon_timer = summon_cooldown
		_do_summon()

func _do_summon() -> void:
	if _active_summons.size() >= max_summons: return
	if not is_instance_valid(summon_scene): return
	var offset := Vector3(randf_range(-summon_radius, summon_radius), 0,
						  randf_range(-summon_radius, summon_radius))
	var s := summon_scene.instantiate()
	get_tree().current_scene.add_child(s)
	(s as Node3D).global_position = global_position + offset
	if "team_id" in s: s.set("team_id", team_id)
	_active_summons.append(s)

func die() -> void:
	# Kill all summons on death
	for s in _active_summons:
		if is_instance_valid(s) and s.has_method("die"): s.die()
	super.die()
