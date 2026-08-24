# ============================================================
# RatAlly.gd — player-summoned ally (quest reward: "Call of the Wild")
# Identity: fast, scrappy, bonus damage, SCAVENGES bonus gold from nearby
# kills. This game has no physical ground-loot pickup system (checked --
# gold/crystals are all granted directly via award_gold()/add_crystal(),
# nothing to walk over), so "scavenging" is implemented honestly as a real
# passive gold bonus from kills near the rat, not a fictional pickup loop.
# ============================================================
extends CharacterBody3D
class_name RatAlly

@export var max_health      : float = 60.0
@export var move_speed      : float = 6.0       # faster than bats -- scrappy and quick
@export var follow_distance : float = 2.5
@export var attack_range    : float = 2.2
@export var attack_damage   : float = 14.0      # higher than bat -- "does more damage"
@export var attack_cooldown : float = 0.8
@export var scavenge_radius : float = 8.0
@export var scavenge_bonus_pct : float = 0.35   # +35% bonus gold on nearby kills

var health      : float = 60.0
var team_id     : int   = 1
var owner_player: Node3D = null
var is_dead     : bool  = false

var _attack_timer : float = 0.0
var _target        : Node3D = null
var _mesh          : MeshInstance3D = null

signal died


func _ready() -> void:
	health = max_health
	add_to_group("minions")
	add_to_group("units")
	add_to_group("rat_allies")
	_build_visual()
	# Passive scavenging: listen for ANY zombie's death and grant a bonus if
	# it died near this rat. Zombies don't emit a shared "died" signal (per
	# zombie.gd -- death is handled internally, not a signal), so poll
	# nearby zombie health each tick instead of trying to hook a signal
	# that doesn't exist.
	set_physics_process(true)


func _build_visual() -> void:
	# No real rat model sourced for this -- a simple placeholder capsule so
	# the ally is visible and functional now; swap in real art later.
	_mesh = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.18; cap.height = 0.5
	_mesh.mesh = cap
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.35, 0.28)
	mat.roughness = 0.8
	_mesh.material_override = mat
	add_child(_mesh)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.18; shape.height = 0.5
	col.shape = shape
	add_child(col)


func _physics_process(delta: float) -> void:
	if is_dead: return
	_attack_timer -= delta

	if not is_instance_valid(owner_player):
		return

	_find_target()
	if is_instance_valid(_target):
		var dist : float = global_position.distance_to(_target.global_position)
		if dist <= attack_range:
			velocity = Vector3.ZERO
			if _attack_timer <= 0.0:
				_attack_timer = attack_cooldown
				_do_attack()
		else:
			_seek(_target.global_position, delta)
	else:
		_follow_owner(delta)

	move_and_slide()
	_scavenge_check()


func _find_target() -> void:
	if is_instance_valid(_target):
		if not is_instance_valid(_target) or ("is_dead" in _target and _target.get("is_dead")):
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


func _seek(pos: Vector3, _delta: float) -> void:
	var dir := (pos - global_position); dir.y = 0.0
	if dir.length_squared() > 0.01:
		dir = dir.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	if not is_on_floor():
		velocity.y -= 9.8 * _delta


func _follow_owner(delta: float) -> void:
	var to_owner := owner_player.global_position - global_position
	to_owner.y = 0.0
	if to_owner.length() > follow_distance:
		_seek(owner_player.global_position, delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 4.0)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 4.0)
		if not is_on_floor(): velocity.y -= 9.8 * delta


func _do_attack() -> void:
	if not is_instance_valid(_target): return
	if _target.has_method("take_damage"):
		_target.take_damage(attack_damage, self)


func _scavenge_check() -> void:
	# No death signal exists on zombies to hook -- honest passive
	# implementation: whenever ANY nearby zombie's health crosses to <= 0
	# on a tick this rat is near it, grant a scavenge bonus once.
	for z in get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(z) or not (z is Node3D): continue
		if not ("health" in z) or not ("is_dead" in z): continue
		if not z.get("is_dead"): continue
		if z.get_meta("_rat_scavenged", false): continue
		var d := global_position.distance_to((z as Node3D).global_position)
		if d > scavenge_radius: continue
		z.set_meta("_rat_scavenged", true)
		var base_reward : int = int(z.get("gold_reward")) if "gold_reward" in z else 0
		var bonus : int = int(round(base_reward * scavenge_bonus_pct))
		if bonus > 0:
			var gm := get_tree().get_first_node_in_group("game_manager")
			if is_instance_valid(gm) and gm.has_method("award_gold"):
				gm.award_gold(team_id, bonus)


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
