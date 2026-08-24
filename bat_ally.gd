# ============================================================
# BatAlly.gd — player-summoned ally (quest reward: "Call of the Wild")
# Identity: flies (no gravity), lower damage than the rat, but VAMPIRIC --
# heals itself AND the owning player for a share of damage dealt.
# ============================================================
extends CharacterBody3D
class_name BatAlly

@export var max_health      : float = 45.0      # squishier than the rat
@export var move_speed      : float = 5.0
@export var fly_height      : float = 1.6        # hovers above the player
@export var follow_distance : float = 2.5
@export var attack_range    : float = 3.0        # slightly longer reach (flies over melee)
@export var attack_damage   : float = 9.0        # lower than rat's 14 -- the tradeoff
@export var attack_cooldown : float = 1.0
@export var lifesteal_pct       : float = 0.5    # 50% of damage dealt heals the bat itself
@export var player_heal_pct     : float = 0.2    # 20% of damage dealt also heals the owner

var health       : float = 45.0
var team_id      : int   = 1
var owner_player : Node3D = null
var is_dead      : bool  = false

var _attack_timer : float = 0.0
var _target        : Node3D = null
var _bob_t         : float = 0.0

signal died


func _ready() -> void:
	health = max_health
	add_to_group("minions")
	add_to_group("units")
	add_to_group("bat_allies")
	_build_visual()
	set_physics_process(true)


func _build_visual() -> void:
	# No real bat model sourced for this -- a simple placeholder so the
	# ally is visible and functional now; swap in real art later.
	var mesh_inst := MeshInstance3D.new()
	var body := SphereMesh.new()
	body.radius = 0.16; body.height = 0.32
	mesh_inst.mesh = body
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.05, 0.28)
	mat.roughness = 0.6
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.1, 0.6)
	mat.emission_energy_multiplier = 0.8
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.16
	col.shape = shape
	add_child(col)


func _physics_process(delta: float) -> void:
	if is_dead: return
	_attack_timer -= delta
	_bob_t += delta

	if not is_instance_valid(owner_player):
		return

	_find_target()
	var desired_pos : Vector3
	if is_instance_valid(_target):
		desired_pos = _target.global_position + Vector3(0, fly_height, 0)
		var dist : float = global_position.distance_to(_target.global_position)
		if dist <= attack_range and _attack_timer <= 0.0:
			_attack_timer = attack_cooldown
			_do_attack()
	else:
		desired_pos = owner_player.global_position + Vector3(0, fly_height, 0)

	# Flies -- no gravity, direct hover-seek with a small vertical bob.
	var to_target := desired_pos - global_position
	if to_target.length() > 0.1:
		velocity = to_target.normalized() * move_speed
	else:
		velocity = Vector3.ZERO
	velocity.y += sin(_bob_t * 2.0) * 0.3

	move_and_slide()


func _find_target() -> void:
	if is_instance_valid(_target):
		if ("is_dead" in _target and _target.get("is_dead")):
			_target = null
		elif global_position.distance_to(_target.global_position) > attack_range * 3.0:
			_target = null
	if is_instance_valid(_target):
		return
	var best : Node3D = null
	var best_d := attack_range * 3.0
	for z in get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(z) or not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		if "is_dead" in z and z.get("is_dead"): continue
		var d := global_position.distance_to((z as Node3D).global_position)
		if d < best_d:
			best_d = d; best = z as Node3D
	_target = best


func _do_attack() -> void:
	if not is_instance_valid(_target): return
	if not _target.has_method("take_damage"): return
	_target.take_damage(attack_damage, self)

	# Vampiric: heal self...
	var self_heal : float = attack_damage * lifesteal_pct
	health = minf(health + self_heal, max_health)

	# ...and heal the owning player too, if it has a real health system.
	if is_instance_valid(owner_player) and "health" in owner_player and "max_health" in owner_player:
		var player_heal : float = attack_damage * player_heal_pct
		var new_health : float = minf(float(owner_player.get("health")) + player_heal, float(owner_player.get("max_health")))
		owner_player.set("health", new_health)
		if owner_player.has_signal("health_changed"):
			owner_player.health_changed.emit(new_health, owner_player.get("max_health"))


func take_damage(amount: float, _source = null) -> void:
	if is_dead: return
	health -= amount
	if health <= 0.0:
		die()


func die() -> void:
	if is_dead: return
	is_dead = true
	died.emit()
	queue_free()
