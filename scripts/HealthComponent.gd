# ============================================================
# HealthComponent.gd
# Owns health, damage, death, respawn
# ============================================================
extends ActorComponent
class_name HealthComponent

@export var max_health     : float = 100.0
@export var gold_on_death  : int   = 100
@export var respawn_delay  : float = 3.0

var health   : float = 100.0
var is_dead  : bool  = false

signal health_changed(current: float, maximum: float)
signal died
signal respawned

func _ready() -> void:
	initialize(get_parent() as CharacterBody3D)
	health = max_health
	health_changed.emit(health, max_health)


func take_damage(amount: float, instigator: Node = null) -> void:
	if is_dead: return
	if is_instance_valid(instigator) and "team_id" in instigator:
		var team_id : int = actor.get("team_id") if actor and "team_id" in actor else -1
		if int(instigator.get("team_id")) == team_id: return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0: _die(instigator)

func heal(amount: float) -> void:
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)

func set_max_health(new_max: float, also_heal: bool = true) -> void:
	var delta := new_max - max_health
	max_health = new_max
	if also_heal: health = minf(health + delta, max_health)
	health_changed.emit(health, max_health)

func _die(instigator: Node = null) -> void:
	if is_dead: return
	is_dead = true
	died.emit()
	_award_kill_gold(instigator)
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn)

func _respawn() -> void:
	is_dead   = false
	health    = max_health
	health_changed.emit(health, max_health)
	# Move to friendly base
	if is_instance_valid(actor):
		var team_id : int = actor.get("team_id") if "team_id" in actor else 1
		for b in actor.get_tree().get_nodes_in_group("bases"):
			if "team_id" in b and int(b.get("team_id")) == team_id and b is Node3D:
				actor.global_position = (b as Node3D).global_position + Vector3(0, 1.5, 0)
				break
		actor.velocity = Vector3.ZERO
	respawned.emit()

func _award_kill_gold(instigator: Node) -> void:
	var gm := actor.get_tree().get_first_node_in_group("game_manager") if actor else null
	if not is_instance_valid(gm) or not gm.has_method("add_gold"): return
	if not is_instance_valid(instigator) or not ("team_id" in instigator): return
	var enemy_team := int(instigator.get("team_id"))
	gm.add_gold(enemy_team, gold_on_death)

func get_health_ratio() -> float:
	return health / maxf(max_health, 0.001)
func is_shielded() -> bool: return false  # overridden by AbilityComponent
