# ============================================================
# SniperCreep.gd — extends BaseZombie
# Extreme range. Slow fire. Huge damage. Armor-piercing shot.
# ============================================================
extends BaseZombie
class_name SniperCreep

@export_group("Sniper")
@export var snipe_range    : float = 22.0
@export var snipe_damage   : float = 120.0
@export var snipe_cooldown : float = 4.5
@export var armor_pierce   : float = 0.6    # ignores this fraction of armor
@export var headshot_chance: float = 0.15   # instant 2x damage

var _snipe_timer : float = 0.0

func _ready() -> void:
	max_health      = 180.0
	move_speed      = 1.8
	damage          = 8.0
	attack_range    = snipe_range
	attack_cooldown = snipe_cooldown
	gold_reward     = 65
	armor_physical  = 1.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_snipe_timer = randf_range(1.0, snipe_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_snipe_timer -= delta
	if _snipe_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= snipe_range:
			_snipe_timer = snipe_cooldown
			_fire_snipe()

func _fire_snipe() -> void:
	if not is_instance_valid(target): return
	var dn  := get_tree().get_first_node_in_group("damage_numbers")
	var dmg := snipe_damage
	var headshot := randf() < headshot_chance
	if headshot: dmg *= 2.0
	# Apply with armor pierce: temporarily reduce target armor
	if "armor_physical" in target:
		var orig_armor : float = target.get("armor_physical")
		target.set("armor_physical", orig_armor * (1.0 - armor_pierce))
		if target.has_method("take_damage"):
			target.take_damage(dmg, self)
		target.set("armor_physical", orig_armor)
	elif target.has_method("take_damage"):
		target.take_damage(dmg, self)
	if is_instance_valid(dn) and dn.has_method("spawn_number"):
		dn.spawn_number(dmg, target.global_position + Vector3(0,2.0,0), 0, headshot)
