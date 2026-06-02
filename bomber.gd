# ============================================================
# BomberCreep.gd — extends BaseZombie AAA
# Suicide bomber. Explodes on death or when close to target.
# Also throws periodic explosive charges.
# ============================================================
extends BaseZombie
class_name BomberCreep

@export_group("Bomber")
@export var explosion_radius   : float = 4.5
@export var explosion_damage   : float = 80.0
@export var charge_cooldown    : float = 8.0
@export var charge_radius      : float = 3.0
@export var charge_damage      : float = 40.0
@export var detonate_range     : float = 2.5
@export var explosion_sounds   : Array[AudioStream] = []

var _charge_timer  : float = 0.0
var _detonated     : bool  = false

func _ready() -> void:
	max_health      = 180.0
	move_speed      = 3.8
	damage          = 12.0
	attack_range    = 1.8
	attack_cooldown = 1.2
	gold_reward     = 60
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_charge_timer = randf_range(3.0, charge_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_charge_timer -= delta
	if _charge_timer <= 0.0:
		_charge_timer = charge_cooldown
		_do_charge_explosion()
	# Auto-detonate when very close to any enemy
	if not _detonated and is_instance_valid(target):
		if global_position.distance_to(target.global_position) <= detonate_range:
			_explode()

func _do_charge_explosion() -> void:
	# Smaller targeted explosion at nearby enemies
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if global_position.distance_to((u as Node3D).global_position) > charge_radius: continue
		if u.has_method("take_damage"): u.take_damage(charge_damage, self)
		var dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(charge_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 1, false)
	_play_sound(explosion_sounds, 7.0)
	_spawn_explosion_vfx(global_position, charge_radius * 0.6)

func _explode() -> void:
	if _detonated: return
	_detonated = true
	_play_sound(explosion_sounds, 9.0)
	_spawn_explosion_vfx(global_position, explosion_radius)
	# Full explosion damage in radius
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var d := global_position.distance_to((u as Node3D).global_position)
		if d > explosion_radius: continue
		var falloff := 1.0 - (d / explosion_radius)
		var dmg := explosion_damage * falloff
		if u.has_method("take_damage"): u.take_damage(dmg, self)
		if u is CharacterBody3D:
			var kb := ((u as Node3D).global_position - global_position).normalized()
			kb.y = 0.4
			(u as CharacterBody3D).velocity += kb * 10.0 * falloff
		var dn := get_tree().get_first_node_in_group("damage_numbers")
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(dmg, (u as Node3D).global_position + Vector3(0,1.5,0), 1, false)
	# Die after exploding
	_die()

# Override _die to trigger explosion if not already detonated
func _die() -> void:
	if not _detonated:
		_detonated = true
		_spawn_explosion_vfx(global_position, explosion_radius * 0.7)
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			if global_position.distance_to((u as Node3D).global_position) > explosion_radius * 0.7: continue
			if u.has_method("take_damage"): u.take_damage(explosion_damage * 0.6, self)
	super._die()

func _spawn_explosion_vfx(pos: Vector3, radius: float) -> void:
	# Procedural sphere flash
	var root := Node3D.new()
	get_tree().current_scene.add_child(root)
	root.global_position = pos
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius * 0.4; sm.height = radius * 0.8
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.5, 0.1, 0.7)
	mat.emission_enabled = true; mat.emission = Color(1.0, 0.3, 0.0)
	mat.emission_energy_multiplier = 8.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	root.add_child(mi)
	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.5, 0.1)
	lt.light_energy = 6.0; lt.omni_range = radius * 2.5; lt.shadow_enabled = false
	root.add_child(lt)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3.ONE * 2.0, 0.15).set_trans(Tween.TRANS_EXPO)
	tw.tween_property(mi, "material_override:albedo_color:a", 0.0, 0.25)
	tw.tween_callback(func(): root.queue_free())
