# ============================================================
# NecromancerCreep.gd — extends BaseZombie
# Ranged dark bolts. Raises recently killed enemies as undead.
# ============================================================
extends BaseZombie
class_name NecromancerCreep

@export_group("Necromancer")
@export var bolt_range       : float = 13.0
@export var bolt_damage      : float = 25.0
@export var bolt_cooldown    : float = 2.5
@export var raise_range      : float = 10.0
@export var raise_cooldown   : float = 8.0
@export var raise_health_pct : float = 0.50
@export var max_raised       : int   = 3

var _bolt_timer   : float = 0.0
var _raise_timer  : float = 0.0
var _raised_units : Array  = []

func _ready() -> void:
	max_health      = 320.0
	move_speed      = 2.0
	damage          = 12.0
	attack_range    = bolt_range
	attack_cooldown = bolt_cooldown
	gold_reward     = 90
	armor_physical  = 2.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_bolt_timer  = randf_range(1.0, bolt_cooldown)
	_raise_timer = randf_range(3.0, raise_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_raised_units = _raised_units.filter(func(u): return is_instance_valid(u) and not u.get("is_dead"))
	_bolt_timer  -= delta
	_raise_timer -= delta
	if _bolt_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= bolt_range:
			_bolt_timer = bolt_cooldown
			_fire_bolt()
	if _raise_timer <= 0.0 and _raised_units.size() < max_raised:
		_raise_timer = raise_cooldown
		_try_raise()

func _fire_bolt() -> void:
	if not is_instance_valid(target): return
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if target.has_method("take_damage"):
		target.take_damage(bolt_damage, self)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(bolt_damage, target.global_position + Vector3(0,1.5,0), 3, false)

func _try_raise() -> void:
	# Only raise if owner player is playing Necromancer class.
	# We check the integer value (PlayerClass.NECROMANCER == 1) rather than using
	# get() on a const (which is unreliable in Godot 4).
	if not is_instance_valid(owner_player): return
	if not ("player_class" in owner_player): return
	var pc = owner_player.get("player_class")
	# PlayerClass.NECROMANCER is enum value 1 in player.gd
	if pc == null: return
	var pc_int : int = int(pc)
	if pc_int != 1: return  # 1 == PlayerClass.NECROMANCER
	# Find a dead enemy unit nearby and revive it on our team
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if not ("is_dead" in u) or not u.get("is_dead"): continue
		if (u as Node3D).global_position.distance_to(global_position) > raise_range: continue
		# Revive with partial health on our team
		u.set("team_id", team_id)
		u.set("is_dead", false)
		if "health" in u and "max_health" in u:
			u.set("health", u.get("max_health") * raise_health_pct)
		if u.has_method("_ready"): pass   # don't re-ready; just flip team
		_raised_units.append(u)
		break

func die() -> void:
	for u in _raised_units:
		if is_instance_valid(u) and u.has_method("die"): u.die()
	super.die()
