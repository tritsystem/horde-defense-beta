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

# REAL BUG FIX: "picking bats surrounds me with purple orbs and I can't
# move". With no target, every bat in the pack computed the exact same
# desired_pos (owner_player.global_position + Vector3(0, fly_height, 0))
# -- all 3 tried to occupy the identical point right at the player's own
# head height every frame, and the resulting mutual collision-resolution
# fight (3 real SphereShape3D bodies + the player's own capsule, all
# fighting over one spot) is what actually trapped the player in place.
# rat_ally.gd doesn't have this bug -- it only seeks when farther than
# follow_distance, so rats naturally settle at different points instead
# of converging. ally_choice_ui.gd sets this per-bat before add_child()
# so each bat holds a distinct position around the player instead.
var hover_offset : Vector3 = Vector3.ZERO

var _attack_timer : float = 0.0
var _target        : Node3D = null
var _bob_t         : float = 0.0

# ── Real animated model (2026-08-24) ────────────────────────────────────
# Replaces the earlier "no real bat model sourced, simple placeholder"
# sphere. Source: Quaternius (CC0/Public Domain) via poly.pizza -- see
# assets/allies/LICENSE_SOURCES.txt for the exact URLs/license. Real rig
# with 5 clips (Bat_Attack, Bat_Attack2, Bat_Death, Bat_Flying, Bat_Hit),
# confirmed by directly parsing the .glb's own glTF JSON animation list
# (not assumed from the product page, which didn't enumerate them).
const MODEL_SCENE : String = "res://assets/allies/bat/bat.glb"
# REAL MEASUREMENT (2026-08-24, headless AABB check): the imported model's
# combined mesh AABB came out to ~(2.7, 5.3, 4.3) units -- a 5-meter-tall
# bat, roughly 10x too large for this game's scale (the old placeholder
# sphere was ~0.32 diameter). The glTF's own compensating "x100" scale
# node (Blender-cm-to-m export artifact) doesn't collapse cleanly through
# Godot's importer. This constant corrects it back down to a real-world
# small-creature size (~0.2-0.4 units) -- re-measure if the source model
# is ever swapped for a different one.
const MODEL_SCALE : float = 0.08
var _model        : Node3D = null
var _anim_player  : AnimationPlayer = null
var _anim_fly     : StringName = &""
var _anim_attacks : Array = []
var _anim_death   : StringName = &""
var _anim_hit     : StringName = &""
var _is_dying     : bool = false
var _anim_lock_timer : float = 0.0   # while > 0, a one-shot anim (attack/hit) owns playback

signal died


func _ready() -> void:
	health = max_health
	add_to_group("minions")
	add_to_group("units")
	add_to_group("bat_allies")
	_build_visual()
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
			if _anim_fly != &"":
				_play_anim(_anim_fly)

	# REAL MEASUREMENT (2026-08-24, headless AABB check against the actual
	# post-MODEL_SCALE mesh): combined mesh AABB center is ~(0.007, 0.054,
	# -0.069), not the origin -- this sphere was centered at (0, 0.05, 0),
	# matching Y closely but missing the real ~0.07-unit Z offset (the
	# model's geometric center sits behind the node origin), which read as
	# "collision doesn't align with the skin". Centered on the real
	# measured mesh center instead of assuming it's at the origin.
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.22
	col.shape = shape
	col.position = Vector3(0.0, 0.05, -0.07)
	add_child(col)

	if not is_instance_valid(_model):
		# Fallback: model failed to load (missing/corrupt file) -- keep the
		# ally visible and functional rather than an invisible capsule.
		var mesh_inst := MeshInstance3D.new()
		var body := SphereMesh.new()
		body.radius = 0.16; body.height = 0.32
		mesh_inst.mesh = body
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.20, 0.05, 0.28)
		mat.emission_enabled = true
		mat.emission = Color(0.5, 0.1, 0.6)
		mat.emission_energy_multiplier = 0.8
		mesh_inst.material_override = mat
		add_child(mesh_inst)


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
## assuming one exact string (same reasoning zombie.gd/team_ally.gd already
## use for their own multi-candidate blend-param probing).
func _cache_animation_names() -> void:
	if not is_instance_valid(_anim_player): return
	for anim_name in _anim_player.get_animation_list():
		var n := String(anim_name)
		if n.findn("Fly") >= 0:
			_anim_fly = anim_name
		elif n.findn("Attack") >= 0:
			_anim_attacks.append(anim_name)
		elif n.findn("Death") >= 0:
			_anim_death = anim_name
		elif n.findn("Hit") >= 0:
			_anim_hit = anim_name


func _play_anim(anim_name: StringName) -> void:
	if not is_instance_valid(_anim_player) or anim_name == &"": return
	if _anim_player.current_animation == anim_name and _anim_player.is_playing(): return
	_anim_player.play(anim_name)


func _physics_process(delta: float) -> void:
	if is_dead: return
	_attack_timer -= delta
	_bob_t += delta

	if not is_instance_valid(owner_player):
		# REAL BUG FIX: "rats/bats stop following me" -- see rat_ally.gd's
		# matching fix for the full story. Same self-healing fallback.
		owner_player = get_tree().get_first_node_in_group("player") as Node3D
		if not is_instance_valid(owner_player):
			return

	_find_target()
	var desired_pos : Vector3
	if is_instance_valid(_target):
		# Same offset applied here too -- multiple bats on the same target
		# would otherwise converge on one point above IT instead, same bug
		# just relocated from the player to whatever they're attacking.
		desired_pos = _target.global_position + hover_offset * 0.5 + Vector3(0, fly_height, 0)
		var dist : float = global_position.distance_to(_target.global_position)
		if dist <= attack_range and _attack_timer <= 0.0:
			_attack_timer = attack_cooldown
			_do_attack()
	else:
		desired_pos = owner_player.global_position + hover_offset + Vector3(0, fly_height, 0)

	# Flies -- no gravity, direct hover-seek with a small vertical bob.
	var to_target := desired_pos - global_position
	if to_target.length() > 0.1:
		velocity = to_target.normalized() * move_speed
	else:
		velocity = Vector3.ZERO
	velocity.y += sin(_bob_t * 2.0) * 0.3

	# Face travel direction -- same atan2(dir.x, dir.z) convention confirmed
	# correct (via a real headless measurement) in team_ally.gd's own
	# 2026-08-24 facing fix, rather than Godot's look_at() which measured
	# 180 degrees backward on that rig. Bats had NO facing logic at all
	# before this pass (the old placeholder sphere had no visible "front"
	# to get wrong); worth a live look once this model is actually seen in
	# play, since this specific asset's forward convention hasn't been
	# separately confirmed the way team_ally's rig was.
	var flat_vel := Vector2(velocity.x, velocity.z)
	if flat_vel.length() > 0.15:
		rotation.y = atan2(velocity.x, velocity.z)

	move_and_slide()

	_anim_lock_timer = maxf(0.0, _anim_lock_timer - delta)
	if _anim_lock_timer <= 0.0:
		_play_anim(_anim_fly)


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
	_play_one_shot_anim(_anim_attacks[randi() % _anim_attacks.size()] if not _anim_attacks.is_empty() else &"")

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
	elif _anim_hit != &"":
		_play_one_shot_anim(_anim_hit)


## Plays a one-shot clip (attack/hit) and locks out the default fly-loop
## auto-play for its real duration, so the loop doesn't stomp it back to
## "Flying" mid-swing/mid-flinch the very next physics tick.
func _play_one_shot_anim(anim_name: StringName) -> void:
	if anim_name == &"" or not is_instance_valid(_anim_player): return
	_anim_player.play(anim_name)
	var anim := _anim_player.get_animation(anim_name)
	_anim_lock_timer = anim.length if is_instance_valid(anim) else 0.5


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
