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
# Real building/doorway awareness -- see team_ally.gd's matching
# _nav_agent comment for the full reasoning (straight-line _seek() has
# zero obstacle awareness; a per-agent NavigationAgent3D is cheap for the
# handful of rats/bats a player can have out at once).
var _nav_agent : NavigationAgent3D = null

# ── Real animated model (2026-08-24) ────────────────────────────────────
# Replaces the earlier "no real rat model sourced, simple placeholder"
# capsule. Source: Quaternius (CC0/Public Domain) via poly.pizza -- see
# assets/allies/LICENSE_SOURCES.txt for the exact URLs/license. Real rig
# with 6 clips (Rat_Attack, Rat_Death, Rat_Idle, Rat_Jump, Rat_Run,
# Rat_Walk), confirmed by directly parsing the .glb's own glTF JSON
# animation list.
const MODEL_SCENE : String = "res://assets/allies/rat/rat.glb"
# REAL MEASUREMENT (2026-08-24, headless AABB check): the imported model's
# combined mesh AABB came out to ~(0.59, 0.91, 2.76) units -- a
# 2.76m-long rat, roughly 8-10x too large for this game's scale (the old
# placeholder capsule was 0.5 tall/0.36 wide). Same "x100" Blender-export
# compensating scale that doesn't collapse cleanly through Godot's
# importer -- see bat_ally.gd's own MODEL_SCALE for the matching note.
# Re-measure if the source model is ever swapped for a different one.
const MODEL_SCALE : float = 0.13
var _model        : Node3D = null
var _anim_player  : AnimationPlayer = null
var _anim_idle    : StringName = &""
var _anim_walk    : StringName = &""
var _anim_run     : StringName = &""
var _anim_attack  : StringName = &""
var _anim_death   : StringName = &""
var _anim_lock_timer : float = 0.0   # while > 0, a one-shot anim (attack) owns playback

signal died


func _ready() -> void:
	health = max_health
	add_to_group("minions")
	add_to_group("units")
	add_to_group("rat_allies")
	_build_visual()
	_build_nav_agent()
	# Passive scavenging: listen for ANY zombie's death and grant a bonus if
	# it died near this rat. Zombies don't emit a shared "died" signal (per
	# zombie.gd -- death is handled internally, not a signal), so poll
	# nearby zombie health each tick instead of trying to hook a signal
	# that doesn't exist.
	set_physics_process(true)


func _build_visual() -> void:
	if ResourceLoader.exists(MODEL_SCENE):
		var packed : PackedScene = load(MODEL_SCENE)
		if is_instance_valid(packed):
			_model = packed.instantiate()
			_model.scale = Vector3.ONE * MODEL_SCALE
			add_child(_model)
			_anim_player = _find_animation_player(_model)
			_cache_animation_names()
			if _anim_idle != &"":
				_anim_player.play(_anim_idle)

	# REAL MEASUREMENT (2026-08-24, headless AABB check against the actual
	# post-MODEL_SCALE mesh): combined mesh AABB is only ~0.12 units tall
	# (Y: -0.002 to 0.116) but ~0.36 units long (Z: -0.252 to 0.106, a
	# real rat body -- long and low, not tall) -- a vertical CapsuleShape3D
	# with height=0.28 stuck up more than DOUBLE the actual model's real
	# height, and its round cross-section didn't fit the elongated body
	# either. A box matched to the measured AABB (small margin) fits an
	# elongated low body far better than a tall capsule ever could.
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.11, 0.14, 0.40)
	col.shape = shape
	col.position = Vector3(0.0, 0.057, -0.073)
	add_child(col)

	if not is_instance_valid(_model):
		# Fallback: model failed to load (missing/corrupt file) -- keep the
		# ally visible and functional rather than an invisible capsule.
		_mesh = MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.18; cap.height = 0.5
		_mesh.mesh = cap
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.35, 0.28)
		mat.roughness = 0.8
		_mesh.material_override = mat
		add_child(_mesh)


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := _find_animation_player(child)
		if is_instance_valid(found):
			return found
	return null


## Matches by substring rather than an exact expected name -- glTF import
## sometimes keeps the "ArmatureName|" clip-name prefix and sometimes
## strips it depending on importer settings, so probing is safer than
## assuming one exact string (same pattern bat_ally.gd's own animation
## caching uses).
func _cache_animation_names() -> void:
	if not is_instance_valid(_anim_player): return
	for anim_name in _anim_player.get_animation_list():
		var n := String(anim_name)
		if n.findn("Idle") >= 0:
			_anim_idle = anim_name
		elif n.findn("Walk") >= 0:
			_anim_walk = anim_name
		elif n.findn("Run") >= 0:
			_anim_run = anim_name
		elif n.findn("Attack") >= 0:
			_anim_attack = anim_name
		elif n.findn("Death") >= 0:
			_anim_death = anim_name


func _play_anim(anim_name: StringName) -> void:
	if not is_instance_valid(_anim_player) or anim_name == &"": return
	if _anim_player.current_animation == anim_name and _anim_player.is_playing(): return
	_anim_player.play(anim_name)


func _play_one_shot_anim(anim_name: StringName) -> void:
	if anim_name == &"" or not is_instance_valid(_anim_player): return
	_anim_player.play(anim_name)
	var anim := _anim_player.get_animation(anim_name)
	_anim_lock_timer = anim.length if is_instance_valid(anim) else 0.4


## Picks Idle/Walk/Run purely from current horizontal speed relative to
## this rat's own move_speed -- mirrors the blend-by-speed convention
## zombie.gd/team_ally.gd already use for their own move-blend params,
## just discrete (3 clips) instead of continuous (a blend tree).
func _update_move_anim(delta: float) -> void:
	_anim_lock_timer = maxf(0.0, _anim_lock_timer - delta)
	if _anim_lock_timer > 0.0: return
	var speed : float = Vector2(velocity.x, velocity.z).length()
	var ratio : float = speed / maxf(move_speed, 0.01)
	if ratio < 0.08:
		_play_anim(_anim_idle)
	elif ratio < 0.6 and _anim_walk != &"":
		_play_anim(_anim_walk)
	else:
		_play_anim(_anim_run if _anim_run != &"" else _anim_walk)


func _physics_process(delta: float) -> void:
	if is_dead: return
	_attack_timer -= delta

	if not is_instance_valid(owner_player):
		# REAL BUG FIX: "rats/bats stop following me". With no recovery
		# here, a stale owner_player reference (player node swapped/
		# reloaded, or never set before the very first physics tick)
		# permanently freezes this ally in place forever -- nothing else
		# in this file ever retries. Falls back to the same group lookup
		# ally_choice_ui.gd's own _choose() already uses, so a stale
		# reference self-heals instead of orphaning the ally for good.
		owner_player = get_tree().get_first_node_in_group("player") as Node3D
		if not is_instance_valid(owner_player):
			return

	_find_target()
	if is_instance_valid(_target):
		var dist : float = global_position.distance_to(_target.global_position)
		if dist <= attack_range:
			velocity = Vector3.ZERO
			_face(_target.global_position)
			if _attack_timer <= 0.0:
				_attack_timer = attack_cooldown
				_do_attack()
		else:
			_seek(_target.global_position, delta)
	else:
		_follow_owner(delta)

	move_and_slide()
	_scavenge_check()
	_update_move_anim(delta)


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


func _build_nav_agent() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.path_desired_distance = 0.5
	_nav_agent.target_desired_distance = 0.75
	_nav_agent.avoidance_enabled = false
	add_child(_nav_agent)


func _seek(pos: Vector3, _delta: float) -> void:
	var move_target := pos
	if is_instance_valid(_nav_agent) and get_world_3d().navigation_map != RID():
		_nav_agent.target_position = pos
		if not _nav_agent.is_navigation_finished():
			move_target = _nav_agent.get_next_path_position()
	var dir := (move_target - global_position); dir.y = 0.0
	if dir.length_squared() > 0.01:
		dir = dir.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
		_face(pos)
	if not is_on_floor():
		velocity.y -= 9.8 * _delta


## Same atan2(dir.x, dir.z) convention confirmed correct (via a real
## headless measurement) in team_ally.gd's own 2026-08-24 facing fix,
## rather than Godot's look_at() which measured 180 degrees backward on
## that rig. Rats had NO facing logic at all before this pass. Worth a
## live look once this model is actually seen in play -- this specific
## asset's forward convention hasn't been separately confirmed the way
## team_ally's player rig was.
func _face(pos: Vector3) -> void:
	var dir := pos - global_position; dir.y = 0.0
	if dir.length_squared() > 0.01:
		rotation.y = atan2(dir.x, dir.z)


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
	_play_one_shot_anim(_anim_attack)


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
	if is_instance_valid(_anim_player) and _anim_death != &"":
		# Let the death clip actually play before removing the node --
		# queue_free()ing immediately (the old behavior) meant a death
		# animation could never be seen regardless of whether one existed.
		set_physics_process(false)
		_anim_player.play(_anim_death)
		var anim := _anim_player.get_animation(_anim_death)
		var wait : float = anim.length if is_instance_valid(anim) else 0.6
		get_tree().create_timer(wait).timeout.connect(queue_free)
	else:
		queue_free()
