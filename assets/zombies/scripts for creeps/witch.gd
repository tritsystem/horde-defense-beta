# ============================================================
# WitchCreep.gd — extends BaseZombie
# Ranged magic user. Fires poison bolts that apply DoT.
# ============================================================
extends BaseZombie
class_name WitchCreep

@export_group("Witch")
@export var bolt_range    : float = 13.0
@export var bolt_damage   : float = 18.0
@export var bolt_cooldown : float = 2.0
@export var poison_dps    : float = 8.0
@export var poison_duration: float = 5.0
@export var curse_chance  : float = 0.3   # chance bolt also reduces armor

var _bolt_timer : float = 0.0

func _ready() -> void:
	max_health      = 220.0
	move_speed      = 2.2
	damage          = 8.0
	attack_range    = bolt_range
	attack_cooldown = bolt_cooldown
	gold_reward     = 60
	armor_physical  = 0.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_bolt_timer = randf_range(0.5, bolt_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_bolt_timer -= delta
	if _bolt_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= bolt_range:
			_bolt_timer = bolt_cooldown
			_fire_bolt()

func _fire_bolt() -> void:
	if not is_instance_valid(target): return
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if target.has_method("take_damage"):
		target.take_damage(bolt_damage, self)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(bolt_damage, target.global_position + Vector3(0,1.5,0), 0, false)
	# Apply poison DoT
	_apply_poison(target)
	# Curse: reduce target armor briefly
	if randf() < curse_chance and "armor_physical" in target:
		var orig : float = target.get("armor_physical")
		target.set("armor_physical", maxf(0.0, orig - 8.0))
		get_tree().create_timer(4.0).timeout.connect(
			func(): if is_instance_valid(target): target.set("armor_physical", orig), CONNECT_ONE_SHOT)

func _apply_poison(u: Node) -> void:
	if u.has_method("apply_dot"):
		u.apply_dot(poison_dps, poison_duration, self)
		return
	# Fallback: manual tick
	var ticks     := int(poison_duration)
	var tick_dmg  := poison_dps
	var dn        := get_tree().get_first_node_in_group("damage_numbers")
	for i in ticks:
		get_tree().create_timer(float(i + 1)).timeout.connect(func():
			if not is_instance_valid(u): return
			if u.has_method("take_damage"):
				u.take_damage(tick_dmg, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(tick_dmg, (u as Node3D).global_position + Vector3(0,1.5,0), 3, false),
			CONNECT_ONE_SHOT)
