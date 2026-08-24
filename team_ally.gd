# ============================================================
# TeamAlly.gd — AI teammates in different classes.
# ============================================================
# Renamed/broadened from base_helper_ally.gd (which only ever did the
# BUILDER role) once the ally system grew a second source (freed from
# broken hives) and two more classes.
#
# Three small, ally-specific classes (deliberately NOT a port of
# player.gd's 14-class system -- that's real player combat kits, this is
# support/utility roles suited to an AI teammate). All three now wear a
# real animated rig (an instanced Player.tscn, puppeted rather than
# player-controlled -- see _build_rig) and carry the same gun a player
# would, and all three are damageable -- once every class can shoot back,
# there's no reason for two of them to be flatly immune anymore:
#   BUILDER — primary job is economy: spends team gold on base HP
#             upgrades. Not proactively aggressive, but fires back if a
#             zombie gets close (_check_self_defense) rather than dying
#             for free while doing its actual job.
#   SCOUT   — primary job is support: periodically reveals minimap area
#             around itself. Same self-defense behavior as Builder.
#   GUARD   — the one proactive combat role: actively seeks out and
#             engages nearby zombies at gun range, holding a defensive
#             position near the base rather than roaming. This is
#             deliberately the "disposable" class -- a freed ally that
#             actively fights is expected to sometimes be lost, unlike
#             the two support roles that only fight when cornered.
#
# Two ways an ally enters the world:
#   - The guaranteed starter: always BUILDER, always present (see
#     game_phase_script.gd's _ensure_team_ally_presence, which now checks
#     every round rather than just round 1, so a lost/dismissed starter
#     gets replaced).
#   - Trapped-in-hive: HiveCluster.gd spawns one of these, trapped=true,
#     at a cleared hive's position, class chosen at random. A trapped
#     ally is caged, immobile, and does nothing until a player stands
#     near it for FREE_HOLD_SECONDS -- auto-frees rather than needing a
#     dedicated "hold key to interact" input, which would need real
#     per-player-slot action-map work (this game's existing world
#     interactions, like HiveCluster's own Hive Heart channel, use a
#     hold-key pattern, but that one is never actually wired to any
#     player input at all -- confirmed by grepping player.gd -- so there
#     was no existing wiring to safely reuse here either).
# ============================================================
extends CharacterBody3D
class_name TeamAlly

enum AllyClass { BUILDER, GUARD, SCOUT }

@export var ally_class : AllyClass = AllyClass.BUILDER
@export var team_id    : int = 1
@export var trapped    : bool = false

const FREE_RADIUS       : float = 3.0
const FREE_HOLD_SECONDS : float = 2.5

# ── Builder tuning (kept in sync with shopui.gd's BASE_UPGRADES/COSTS,
# same duplication precedent as AIPlayer.gd's own separate copy) ──────
const BASE_UPGRADE_TIERS : Array = [
	{"amount": 750, "cost": 800},
	{"amount": 400, "cost": 400},
	{"amount": 200, "cost": 200},
	{"amount": 100, "cost": 100},
]
const DECISION_INTERVAL : float = 6.0

# ── Guard tuning (ranged now -- a real gun, not rat_ally.gd's melee) ───
@export var max_health      : float = 90.0
@export var move_speed      : float = 4.5
@export var attack_range    : float = 25.0
@export var attack_damage   : float = 16.0   # only used by the no-gun melee fallback, see _do_attack
@export var attack_cooldown : float = 1.0
@export var guard_leash     : float = 30.0   # won't chase further than this from spawn

# ── Scout tuning ────────────────────────────────────────────────────
const SCOUT_REVEAL_RADIUS   : float = 45.0
const SCOUT_REVEAL_INTERVAL : float = 8.0

var health       : float = 0.0
var is_dead      : bool  = false
var _spawn_pos   : Vector3 = Vector3.ZERO
var _decision_timer : float = 0.0
var _attack_timer   : float = 0.0
var _target          : Node3D = null
var _free_progress   : float = 0.0
var _cage_mesh    : MeshInstance3D = null
var _status_label : Label3D = null

# Personal earnings, tracked per-ally from its own class-specific activity
# (Guard: kill rewards; Scout: a small "found while scouting" trickle;
# Builder: a small cut of its own successful builds) -- not a separate
# spendable pool, since that would cut against the whole point of this
# system (helps the team, never buys its own power). Earnings are donated
# to the TEAM's shared gold immediately via award_gold/add_gold, same as
# any other kill/income source in this game -- personal_gold_earned is
# purely a running record of what THIS ally specifically contributed, for
# UI/flavor ("Guard has earned 340g for the team") rather than a wallet.
var personal_gold_earned : int = 0

# ── Rig / weapon (real player skin+gun, not a procedural placeholder) ──
# Player.tscn's own root is itself a CharacterBody3D -- instancing it as a
# child of this (also CharacterBody3D) node would create a second, nested
# physics body if left alone, so its own processing and collision are
# stripped entirely on _ready(): this node's own CollisionShape3D (see
# _build_collision) stays the sole physics presence, and the rig becomes a
# pure puppet -- its AnimationTree/WeaponsManager are driven directly by
# this script's own AI state, mirroring how zombie.gd drives its
# AnimationTree from AI-computed velocity with no input polling at all
# (there is no existing precedent in this codebase for a non-player body
# wearing the player's rig -- confirmed via a full search of AIPlayer.gd,
# which only reads a real player's weapon stats, never instances Player.tscn
# itself).
const PLAYER_RIG_SCENE : String = "res://scenes/Player.tscn"
var _rig            : Node3D = null
var _anim_tree       : AnimationTree = null
var _blend_param     : String = ""   # cached once found, see _find_blend_param
var _weapon_manager  : Node = null
var _aim_camera      : Camera3D = null
const BLEND_PARAMS : Array = [
	"parameters/move_blend/blend_position",
	"parameters/Locomotion/blend_position",
	"parameters/blend/blend_position",
]
const SHOOT_ANIM_PARAMS : Array = [
	"parameters/shoot_shot/request",
	"parameters/attack_shot/request",
]

signal freed
signal died


func _ready() -> void:
	add_to_group("team_allies")
	health = max_health
	_spawn_pos = global_position
	_build_collision()
	_build_rig()
	_build_status_label()
	if trapped:
		_build_cage()
	set_physics_process(true)


func _class_name_str() -> String:
	match ally_class:
		AllyClass.BUILDER: return "Builder"
		AllyClass.GUARD:   return "Guard"
		AllyClass.SCOUT:   return "Scout"
	return "Ally"


func _class_color() -> Color:
	match ally_class:
		AllyClass.BUILDER: return Color(0.95, 0.78, 0.15)   # hardhat yellow
		AllyClass.GUARD:   return Color(0.55, 0.75, 0.95)   # steel blue
		AllyClass.SCOUT:   return Color(0.45, 0.9, 0.45)    # scout green
	return Color.WHITE


func _class_icon() -> String:
	match ally_class:
		AllyClass.BUILDER: return "🔨"
		AllyClass.GUARD:   return "🛡"
		AllyClass.SCOUT:   return "🔭"
	return "🙂"


func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.32; shape.height = 1.1
	col.shape = shape
	col.position.y = 0.55
	add_child(col)


func _build_status_label() -> void:
	_status_label = Label3D.new()
	_status_label.text = "%s %s" % [_class_icon(), _class_name_str()]
	_status_label.font_size = 20
	_status_label.modulate = _class_color()
	_status_label.position.y = 2.0
	_status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status_label.no_depth_test = true
	add_child(_status_label)


func _build_rig() -> void:
	if not ResourceLoader.exists(PLAYER_RIG_SCENE):
		return
	var packed : PackedScene = load(PLAYER_RIG_SCENE)
	if not is_instance_valid(packed):
		return
	_rig = packed.instantiate()
	add_child(_rig)

	# Strip the rig's own top-level input/camera/movement processing --
	# this node's own _physics_process (below) is the only thing that
	# should ever move this ally. Child nodes (AnimationTree,
	# WeaponsManager) keep their own independent _process callbacks and
	# are unaffected by disabling the rig root's.
	_rig.set_physics_process(false)
	_rig.set_process(false)
	_rig.set_process_input(false)
	_rig.set_process_unhandled_input(false)

	# Disable (not remove) the rig's own collision -- it's a second
	# CharacterBody3D nested under this one; leaving its capsule live
	# would create a conflicting second physics presence alongside this
	# node's own CollisionShape3D (see _build_collision).
	var rig_col := _rig.get_node_or_null("CollisionShape3D")
	if is_instance_valid(rig_col) and rig_col is CollisionShape3D:
		(rig_col as CollisionShape3D).disabled = true

	# Tint the visible body mesh per class so allies still read apart at a
	# glance despite sharing the player's exact rig -- real per-class
	# skins are a further step, not done here.
	var body_mesh := _rig.get_node_or_null("Skeleton3D/Ch15")
	if is_instance_valid(body_mesh) and body_mesh is MeshInstance3D:
		(body_mesh as MeshInstance3D).material_overlay = _tint_material()

	_anim_tree = _rig.get_node_or_null("AnimationTree") as AnimationTree
	if is_instance_valid(_anim_tree):
		_anim_tree.active = true

	_weapon_manager = _rig.get_node_or_null("CameraRoot/FPSPivot/Camera3D/WeaponsManager")
	_aim_camera = _rig.get_node_or_null("CameraRoot/FPSPivot/Camera3D") as Camera3D
	if is_instance_valid(_weapon_manager) and _weapon_manager.has_method("bind_player") and is_instance_valid(_aim_camera):
		# bind_player's first arg only matters as a fallback source for
		# get_shoot_origin()/get_shoot_direction() (basegun.gd checks
		# has_method before calling either) -- this script implements
		# neither, so basegun.gd's own camera-forward fallback is what
		# actually aims every shot, driven by _aim_camera's orientation.
		_weapon_manager.call("bind_player", self, _aim_camera)


func _tint_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _class_color()
	mat.albedo_color.a = 0.35
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return mat


func _build_cage() -> void:
	_cage_mesh = MeshInstance3D.new()
	var bars := CylinderMesh.new()
	bars.top_radius = 0.55; bars.bottom_radius = 0.55; bars.height = 1.6
	_cage_mesh.mesh = bars
	_cage_mesh.position.y = 0.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.18, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.1, 0.1) * 0.4
	_cage_mesh.material_override = mat
	add_child(_cage_mesh)
	if is_instance_valid(_status_label):
		_status_label.text = "🔒 Trapped Ally\nApproach to free"


func _physics_process(delta: float) -> void:
	if is_dead: return

	if trapped:
		_tick_trapped(delta)
		return

	if not is_on_floor():
		velocity.y -= 9.8 * delta

	match ally_class:
		AllyClass.BUILDER:
			_tick_builder(delta)
		AllyClass.GUARD:
			_tick_guard(delta)
		AllyClass.SCOUT:
			_tick_scout(delta)

	move_and_slide()
	_update_rig_animation()


## Mirrors zombie.gd's _update_animation(): drives the move-blend param
## from this node's own AI-computed velocity every physics tick, with no
# input polling at all. Player.tscn's blend param is a Vector2 (2D blend
# space, forward/back + strafe); zombie.tscn's is a plain float -- probe
# for whichever this rig actually has rather than assume one, same
## reasoning zombie.gd's own multi-candidate probing already documents
## (this project's various rigs don't share one blend-tree convention).
func _update_rig_animation() -> void:
	if not is_instance_valid(_anim_tree) or not _anim_tree.active: return
	var speed : float = Vector2(velocity.x, velocity.z).length()
	var blend : float = clampf(speed / maxf(move_speed, 0.01), 0.0, 1.0)
	var param := _find_blend_param()
	if param == "": return
	var cur = _anim_tree.get(param)
	if cur is Vector2: _anim_tree.set(param, Vector2(0.0, blend))
	else:              _anim_tree.set(param, blend)


func _find_blend_param() -> String:
	if _blend_param != "": return _blend_param
	if not is_instance_valid(_anim_tree): return ""
	for p in BLEND_PARAMS:
		if _anim_tree.get(p) != null:
			_blend_param = p
			return p
	return ""


# ── Trapped / freeing ────────────────────────────────────────────────
func _tick_trapped(delta: float) -> void:
	var near := false
	for p in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(p) and p is Node3D:
			if global_position.distance_to((p as Node3D).global_position) <= FREE_RADIUS:
				near = true
				break
	if near:
		_free_progress += delta
		if is_instance_valid(_status_label):
			var pct := int((_free_progress / FREE_HOLD_SECONDS) * 100.0)
			_status_label.text = "🔒 Freeing… %d%%" % pct
		if _free_progress >= FREE_HOLD_SECONDS:
			_free()
	else:
		_free_progress = maxf(0.0, _free_progress - delta * 0.5)
		if is_instance_valid(_status_label):
			_status_label.text = "🔒 Trapped Ally\nApproach to free"


func _free() -> void:
	trapped = false
	_free_progress = 0.0
	if is_instance_valid(_cage_mesh):
		_cage_mesh.queue_free()
		_cage_mesh = null
	if is_instance_valid(_status_label):
		_status_label.text = "%s %s\nFreed!" % [_class_icon(), _class_name_str()]
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("%s %s freed!" % [_class_icon(), _class_name_str()], _class_color())
	freed.emit()


# ── Builder ──────────────────────────────────────────────────────────
func _tick_builder(delta: float) -> void:
	velocity.x = 0.0; velocity.z = 0.0
	if _check_self_defense(delta): return
	_decision_timer -= delta
	if _decision_timer > 0.0: return
	_decision_timer = DECISION_INTERVAL
	_try_spend_gold()


## Builder/Scout aren't proactive attackers (Guard already covers that
## role), but they now carry a real gun and are damageable, so standing
## still doing nothing while a zombie walks up and kills them for free
## would be a worse outcome than a Guard being lost in a fair fight. Fires
## back at anything that gets uncomfortably close, then resumes its real
## job -- doesn't chase, doesn't leave its post. Returns true while
## defending, so callers skip their normal per-tick behavior that frame.
const SELF_DEFENSE_RADIUS : float = 9.0

func _check_self_defense(delta: float) -> bool:
	_check_kill_credit()
	var threat : Node3D = null
	var best_d := SELF_DEFENSE_RADIUS
	for z in get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(z) or not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		if "is_dead" in z and z.get("is_dead"): continue
		var d := global_position.distance_to((z as Node3D).global_position)
		if d < best_d:
			best_d = d; threat = z as Node3D
	if not is_instance_valid(threat):
		return false
	_target = threat
	_face(threat.global_position)
	_attack_timer -= delta
	if _attack_timer <= 0.0:
		_attack_timer = attack_cooldown
		_do_attack()
	return true


func _economy_controller() -> Node:
	# "economy_controller", not the shared "game_manager" group -- main.tscn
	# has a second, unrelated node also in "game_manager" that doesn't
	# implement get_gold/rpc_request_base_upgrade. See
	# game_phase_script.gd's _ready() for the full explanation.
	return get_tree().get_first_node_in_group("economy_controller")


func _try_spend_gold() -> void:
	var econ := _economy_controller()
	if not is_instance_valid(econ): return

	var gold : int = int(econ.get_gold(team_id))
	var tier : Dictionary = {}
	for t in BASE_UPGRADE_TIERS:
		if gold >= int(t["cost"]):
			tier = t
			break
	if tier.is_empty():
		if is_instance_valid(_status_label):
			_status_label.text = "🔨 Builder\nSaving… (%d🪙)" % gold
		print("[TeamAlly] Builder T%d saving, gold=%d" % [team_id, gold])
		return

	var amount : int = int(tier["amount"])
	var cost   : int = int(tier["cost"])

	if NetworkManager.is_networked:
		econ.rpc_request_base_upgrade.rpc_id(1, team_id, amount, cost)
		print("[TeamAlly] Builder T%d requested base +%d HP for %d gold (networked)" % [team_id, amount, cost])
	else:
		if not econ.spend_gold(team_id, cost):
			return   # another spender (player, AIPlayer) beat it to the gold this tick
		var applied := false
		for b in get_tree().get_nodes_in_group("bases"):
			if "team_id" in b and int(b.get("team_id")) == team_id:
				if b.has_method("add_health"): b.add_health(amount)
				elif "health" in b:
					b.health += amount
					if "health_value" in b: b.health_value = b.health
				applied = true
				break
		print("[TeamAlly] Builder T%d spent %d gold for +%d base HP (applied=%s)" % [team_id, cost, amount, str(applied)])

	# Builder's "earned from own play" is a record of value built, not a
	# fresh income stream like Guard's kills/Scout's finds -- it just
	# spent this same team gold, so donating a cut of it back would be
	# circular. Tracked directly rather than through _award_personal_gold.
	personal_gold_earned += amount

	if is_instance_valid(_status_label):
		_status_label.text = "🔨 Builder\n+%d HP built!" % amount


# ── Guard ────────────────────────────────────────────────────────────
func _tick_guard(delta: float) -> void:
	_attack_timer -= delta
	_check_kill_credit()
	_find_target()
	if is_instance_valid(_target):
		var dist := global_position.distance_to(_target.global_position)
		if dist <= attack_range:
			# Ranged now (a real gun, not melee) -- hold position and aim
			# rather than closing distance, same as a player standing and
			# shooting. Face the target so the rig's forward-facing weapon
			# points the right way.
			velocity.x = 0.0; velocity.z = 0.0
			_face(_target.global_position)
			if _attack_timer <= 0.0:
				_attack_timer = attack_cooldown
				_do_attack()
		else:
			_seek(_target.global_position)
	else:
		# Return toward spawn/base rather than wandering off
		var to_home := _spawn_pos - global_position; to_home.y = 0.0
		if to_home.length() > 2.0:
			_seek(_spawn_pos)
		else:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 4.0)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 4.0)


func _face(pos: Vector3) -> void:
	var flat := Vector3(pos.x, global_position.y, pos.z)
	if flat.distance_squared_to(global_position) > 0.01:
		look_at(flat, Vector3.UP)


## Zombies have no death signal to hook (per rat_ally.gd's own note on the
## same limitation) -- poll the currently/just-tracked target each tick
## instead, same honest-passive-implementation approach. Credits gold
## once per kill via a meta flag so a target checked from multiple call
## sites (guard's own tick + self-defense) can't double-pay.
func _award_personal_gold(amount: int) -> void:
	if amount <= 0: return
	personal_gold_earned += amount
	var econ := _economy_controller()
	if is_instance_valid(econ) and econ.has_method("award_gold"):
		econ.award_gold(team_id, amount)
	elif is_instance_valid(econ) and econ.has_method("add_gold"):
		econ.add_gold(team_id, amount)


func _check_kill_credit() -> void:
	if not is_instance_valid(_target): return
	if not ("is_dead" in _target) or not _target.get("is_dead"): return
	if _target.has_meta("_ally_credited"): return
	_target.set_meta("_ally_credited", true)
	var reward : int = int(_target.get("gold_reward")) if "gold_reward" in _target else 10
	_award_personal_gold(reward)
	if is_instance_valid(_status_label):
		_status_label.text = "%s %s\n+%d🪙 earned!" % [_class_icon(), _class_name_str(), reward]


func _seek(pos: Vector3) -> void:
	var dir := pos - global_position; dir.y = 0.0
	if dir.length_squared() > 0.01:
		dir = dir.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed


func _find_target() -> void:
	var search_radius : float = maxf(attack_range, guard_leash)
	if is_instance_valid(_target):
		if ("is_dead" in _target and _target.get("is_dead")) \
				or global_position.distance_to(_target.global_position) > search_radius \
				or _spawn_pos.distance_to(_target.global_position) > guard_leash:
			_target = null
	if is_instance_valid(_target): return
	var best : Node3D = null
	var best_d := search_radius
	for z in get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(z) or not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		if "is_dead" in z and z.get("is_dead"): continue
		if _spawn_pos.distance_to((z as Node3D).global_position) > guard_leash: continue
		var d := global_position.distance_to((z as Node3D).global_position)
		if d < best_d:
			best_d = d; best = z as Node3D
	_target = best


## Fires the rig's currently-equipped gun (aimed via _aim_camera, which
## _face() already pointed at the target) using the exact same
## weapon_manager.try_shoot() -> basegun.gd raycast-and-resolve path a
## real player's shot takes -- damage is computed by whatever weapon is
## equipped, not a flat attack_damage number. Falls back to the original
## direct-damage melee only if no weapon rig is present at all (e.g. the
## rig scene failed to load), so this ally is never a complete no-op.
func _do_attack() -> void:
	if not is_instance_valid(_target): return
	if is_instance_valid(_weapon_manager) and _weapon_manager.has_method("try_shoot"):
		_weapon_manager.call("try_shoot")
		return
	if _target.has_method("take_damage"):
		_target.take_damage(attack_damage, self)


func take_damage(amount: float, _source = null) -> void:
	# Every class is a valid, damageable target now that all three carry a
	# real weapon and can shoot back -- Builder/Scout are no longer flatly
	# immune, just not proactively aggressive (see _check_self_defense).
	if trapped: return   # a caged, not-yet-freed ally can't be meaningfully attacked
	if is_dead: return
	health -= amount
	if health <= 0.0:
		_die()


func _die() -> void:
	if is_dead: return
	is_dead = true
	died.emit()
	queue_free()


# ── Scout ────────────────────────────────────────────────────────────
func _tick_scout(delta: float) -> void:
	velocity.x = 0.0; velocity.z = 0.0
	if _check_self_defense(delta): return
	_decision_timer -= delta
	if _decision_timer > 0.0: return
	_decision_timer = SCOUT_REVEAL_INTERVAL
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("reveal_minimap_area"):
			hud.call("reveal_minimap_area", global_position, SCOUT_REVEAL_RADIUS)
	# A small "found while scouting" trickle each reveal tick -- Scout's
	# own version of "earned from its own play", same donate-to-team-gold
	# pattern as Guard's kill credit.
	const SCOUT_FIND_GOLD : int = 5
	_award_personal_gold(SCOUT_FIND_GOLD)
	if is_instance_valid(_status_label):
		_status_label.text = "🔭 Scout\n+%d🪙 found while scouting" % SCOUT_FIND_GOLD
