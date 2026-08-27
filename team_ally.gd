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

# ── Stuck detection / recovery ──────────────────────────────────────────
# REAL BUG FIX: "ally stuck against wall, not actively moving". Unlike
# zombie.gd (which has a real _update_stuck()/_unstuck() recovery system),
# team_ally.gd's Builder wander and Guard chase/return-to-spawn were pure
# straight-line _seek() with ZERO obstacle handling -- an ally whose wander
# or return-to-spawn target sits behind any wall/rampart pushes into it
# forever with no recovery. Ports zombie.gd's own nav-checked random-hop
# unstick (same NavigationServer3D-closest-point safety check), but called
# ONLY from the branches where an ally is actually supposed to be moving
# (see call sites in _tick_builder_wander/_tick_guard) rather than globally
# every tick -- Scout and Guard-holding-position are INTENTIONALLY
# stationary, and zombie.gd's own history shows a global stuck-check with an
# attack-timer exception is exactly what falsely fired on a zombie that was
# deliberately standing still to melee (the "sink after attack" bug's root
# cause #2). Scoping the call site avoids needing that exception at all.
const STUCK_TIME     : float = 1.5
const STUCK_DISTANCE : float = 0.4
var stuck_timer          : float = 0.0
var last_position_timer  : float = 0.0
var last_position        : Vector3 = Vector3.ZERO

# ── Navigation (real building/doorway awareness) ────────────────────────
# _seek() used to be pure straight-line movement toward the target with
# ZERO awareness of walls or building geometry -- the direct cause of most
# "stuck against a wall" reports (the _unstuck() system above is a
# recovery for when this fails, not a substitute for actually routing
# around obstacles in the first place). zombie.gd deliberately does NOT
# use NavigationAgent3D (see that file's own _nav_agent comment: dropped
# for performance across hundreds of concurrent zombies, replaced by
# FlowFieldManager's shared crowd field) -- but team_ally.gd only ever has
# a handful of allies alive at once, so a real per-agent NavigationAgent3D
# is cheap here and gives correct navmesh-based pathing (routes through
# doorways, around buildings) that a shared flow field can't give an
# individual, precisely-targeted ally anyway.
var _nav_agent : NavigationAgent3D = null

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
var _fps_pivot       : Node3D = null
const BLEND_PARAMS : Array = [
	"parameters/move_blend/blend_position",
	"parameters/Locomotion/blend_position",
	"parameters/blend/blend_position",
]
const SHOOT_ANIM_PARAMS : Array = [
	"parameters/shoot_shot/request",
	"parameters/attack_shot/request",
]

# ── Spiking neural network brain ───────────────────────────────────────
# Same real, working Spikeling engine (res://spikeling.gd -- a pure
# GDScript LIF/synapse runtime, no external process/IPC) and the same
# proven wiring technique zombie.gd's own _brain_tick() already uses in
# this exact codebase: stimulate neurons from real behavioral signals,
# step() the network, react to which neurons actually fired. Genuinely
# richer than that baseline, not just a copy of it: a 3rd neuron (Alert,
# fed by ambient threat COUNT rather than just the current target) wired
# into Aggro via a real synapse, a damage-triggered Caution reflex, and
# Hebbian reinforcement (brain.learn()) on confirmed kills -- zombie.gd's
# brain never learns and has zero synapses at all.
const SpikelingScript = preload("res://spikeling.gd")
var brain : Spikeling
var _aggro_timer      : float = 0.0
var _caution_timer    : float = 0.0
var _prev_target_dist : float = -1.0
const AGGRO_BURST_MULT          : float = 1.30
const CAUTION_DAMP_MULT         : float = 0.80
const BRAIN_EFFECT_DURATION     : float = 1.0
const CLOSING_STIMULUS_SCALE    : float = 40.0
const ALERT_STIMULUS_PER_THREAT : float = 30.0
const DAMAGE_CAUTION_STIMULUS   : float = 60.0

# ── Ollama combat barks (HordeLLM autoload) ─────────────────────────────
# Cosmetic flavour layer ONLY -- deliberately does not touch movement,
# targeting, or damage. Same separation Tribe's TribeLLM/spikeling split
# uses: the SNN brain above decides what this ally DOES, this decides what
# it occasionally SAYS while doing it. See HordeLLM.gd's own header for why
# an LLM call (2-4s even warm) is unfit for anything tactical.
const CHAT_COOLDOWN : float = 22.0   # per-ally gate so barks can't spam during a firefight
const CHAT_HOLD     : float = 4.5    # seconds a bark stays visible above the ally's head
var _chat_label           : Label3D = null
var _chat_timer           : float = 0.0
var _chat_cooldown_timer  : float = 0.0

# ── Core-memory SSH chain (ally_core_memory.gd) ─────────────────────────
# Port of tribe's npc_core_memory wiring: near-death events get anchored as
# CORE (edge-slot) memories that survive later combat panic; routine scrapes
# go to BULK slots and fade. The most salient surviving memory colours this
# ally's LLM bark persona. Cosmetic layer only -- no movement/combat impact.
const AllyCoreMemoryScript = preload("res://ally_core_memory.gd")
var _core_memory = null   # AllyCoreMemory -- untyped so we don't depend on the global class cache being warm
var _near_death_remembered := false   # one core memory per near-death event, not per hit

func _ensure_core_memory():
	if _core_memory == null:
		_core_memory = AllyCoreMemoryScript.new()
	return _core_memory

## How reliably this ally still recalls a given memory right now (0..1).
func recall_core_memory(tag: String) -> float:
	return _ensure_core_memory().recall(tag)

## The strongest currently-recallable core memory tag, or "" if none survive.
func salient_memory_tag() -> String:
	var best_tag := ""
	var best_c := 0.0   # tribe's threshold too: any surviving recall counts, faded = dropped
	for t in _ensure_core_memory().core_tags():
		var c: float = recall_core_memory(str(t))
		if c > best_c:
			best_c = c
			best_tag = str(t)
	return best_tag

signal freed
signal died


func _ready() -> void:
	add_to_group("team_allies")
	health = max_health
	_spawn_pos = global_position
	_build_collision()
	_build_rig()
	_build_status_label()
	_build_chat_label()
	_build_nav_agent()
	if trapped:
		_build_cage()
	brain = SpikelingScript.new()
	brain.load_from_text(
		"neuron Aggro threshold=100 leak=8\n" +
		"neuron Caution threshold=100 leak=15\n" +
		"neuron Alert threshold=80 leak=10\n" +
		"synapse Alert -> Aggro weight=40\n" +
		"refractory=45\n")
	HordeLLM.line_ready.connect(_on_bark_ready)
	set_physics_process(true)


func _current_speed_mult() -> float:
	var mult := 1.0
	if _aggro_timer > 0.0: mult *= AGGRO_BURST_MULT
	if _caution_timer > 0.0: mult *= CAUTION_DAMP_MULT
	# AIDirector.gd's strategic broadcast -- allies react to the same
	# fleet-wide signal the horde does ("control ALL AI", not just
	# zombies), on top of this ally's own tactical Aggro/Caution state.
	var director := get_node_or_null("/root/AIDirector")
	if is_instance_valid(director) and director.has_method("get_speed_mult"):
		mult *= director.get_speed_mult()
	return mult


## Stimulates Aggro/Caution from the actual closing/losing-ground rate
## against the current target (same technique as zombie.gd), plus Alert
## from how many threats are within self-defense range right now
## regardless of which one is the current target -- an ally surrounded
## by 3 zombies gets keyed-up even before picking one to shoot at. Alert
## primes Aggro through the synapse, so sustained danger makes an ally
## fight harder rather than each signal acting in isolation.
func _brain_tick(delta: float) -> void:
	_aggro_timer   = maxf(0.0, _aggro_timer - delta)
	_caution_timer = maxf(0.0, _caution_timer - delta)

	if is_instance_valid(_target):
		var dist : float = global_position.distance_to(_target.global_position)
		if _prev_target_dist >= 0.0:
			var closing_rate : float = (_prev_target_dist - dist) / maxf(delta, 0.001)
			if closing_rate > 0.0:
				brain.stimulate("Aggro", closing_rate * CLOSING_STIMULUS_SCALE)
			elif closing_rate < 0.0:
				brain.stimulate("Caution", -closing_rate * CLOSING_STIMULUS_SCALE)
		_prev_target_dist = dist
	else:
		_prev_target_dist = -1.0

	var nearby_threats : int = 0
	for z in get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(z) or not (z is Node3D): continue
		if "team_id" in z and int(z.get("team_id")) == team_id: continue
		if "is_dead" in z and z.get("is_dead"): continue
		if global_position.distance_to((z as Node3D).global_position) <= SELF_DEFENSE_RADIUS:
			nearby_threats += 1
	if nearby_threats > 0:
		brain.stimulate("Alert", nearby_threats * ALERT_STIMULUS_PER_THREAT)

	var fired : Array = brain.step()
	if "Aggro" in fired:
		_aggro_timer = BRAIN_EFFECT_DURATION
		if is_instance_valid(_status_label):
			_status_label.text = "%s %s\n⚡ Aggro!" % [_class_icon(), _class_name_str()]
	if "Caution" in fired:
		_caution_timer = BRAIN_EFFECT_DURATION
		if is_instance_valid(_status_label):
			_status_label.text = "%s %s\n😰 Cautious" % [_class_icon(), _class_name_str()]


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


## A separate Label3D from _status_label (rather than fighting it for text)
## so an occasional combat bark doesn't need to out-prioritize the frequent
## gold/aggro/build status updates that already write to _status_label at
## many call sites -- lower-risk than threading a "hold" guard through all
## of them.
func _build_chat_label() -> void:
	_chat_label = Label3D.new()
	_chat_label.text = ""
	_chat_label.visible = false
	_chat_label.font_size = 18
	_chat_label.modulate = Color(1.0, 0.95, 0.75)
	_chat_label.outline_size = 6
	_chat_label.position.y = 2.55   # just above _status_label (y=2.0)
	_chat_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_chat_label.no_depth_test = true
	add_child(_chat_label)


func _on_bark_ready(who: Node, text: String, _tag: String) -> void:
	if who != self: return
	if is_instance_valid(_chat_label):
		_chat_label.text = text
		_chat_label.visible = true
	_chat_timer = CHAT_HOLD
	VoiceboxTTS.speak(self, text, _voice_profile_id())


## Voicebox (local TTS app, res://VoiceboxTTS.gd) profile ids -- one real
## distinct stock voice per class so Builder/Guard/Scout are tellable apart
## by ear, not just by their text-bubble role label. Ids are per-machine
## (created once via the Voicebox REST API, not portable to a fresh
## install) -- if VoiceboxTTS reports the server unreachable, this is simply
## never consumed, same as any other TTS-disabled session.
const VOICE_PROFILE_IDS := {
	AllyClass.BUILDER: "0f488180-bafa-400b-9e0d-ebe148800332",  # AllyBuilder (kokoro am_adam)
	AllyClass.GUARD:   "d702dccb-002b-46c2-8f0c-01a6b82bca9c",  # AllyGuard (kokoro am_fenrir)
	AllyClass.SCOUT:   "9e6961ac-5e44-4237-9213-afa0dd88256a",  # AllyScout (kokoro af_nova)
}
func _voice_profile_id() -> String:
	return str(VOICE_PROFILE_IDS.get(ally_class, ""))


## Persona fed to HordeLLM: this ally's role plus its CURRENT real brain
## state (which Spikeling neuron most recently fired), so a bark said while
## Aggro is active actually reads differently from one said while Caution
## is active -- not a static flavour string.
func _mood_persona() -> String:
	var role := "You are the team's %s." % _class_name_str()
	match ally_class:
		AllyClass.BUILDER: role += " Your job is spending gold on base upgrades; you only fight when cornered."
		AllyClass.GUARD:   role += " Your job is actively hunting and killing zombies near the base."
		AllyClass.SCOUT:   role += " Your job is revealing the map; you only fight when cornered."
	var mood := "You feel steady and focused right now."
	if _aggro_timer > 0.0:
		mood = "You feel pumped up and aggressive right now."
	elif _caution_timer > 0.0:
		mood = "You feel rattled and on edge right now."
	# A surviving core memory (e.g. a near-death scrape) colours the persona
	# only while its recall confidence is actually high -- after enough panic
	# it fades and the line disappears, same as tribe's blame lines.
	var salient := salient_memory_tag()
	if salient != "":
		mood += " You narrowly survived being killed earlier (\"%s\") and it still haunts you." % salient
	return role + " " + mood


## Gated by CHAT_COOLDOWN so a burst of kills/hits in a firefight triggers
## at most one HordeLLM call, not one per event -- HordeLLM's own
## single-flight queue would just drop the rest anyway, but this also spares
## the (small, local) model the wasted calls.
func _try_bark(situation: String, fallback: String, tag: String) -> void:
	if _chat_cooldown_timer > 0.0: return
	_chat_cooldown_timer = CHAT_COOLDOWN
	HordeLLM.say_as(self, _mood_persona(), situation, fallback, tag)


func _fallback_kill_bark() -> String:
	match ally_class:
		AllyClass.GUARD:   return "One down!"
		AllyClass.SCOUT:   return "Got one!"
		AllyClass.BUILDER: return "Not today, ugly."
	return "Take that!"


func _fallback_hurt_bark() -> String:
	match ally_class:
		AllyClass.GUARD:   return "I'm hit, still standing!"
		AllyClass.SCOUT:   return "Ow -- taking fire!"
		AllyClass.BUILDER: return "Hey, watch it!"
	return "I'm hit!"


func _fallback_freed_bark() -> String:
	return "Finally! Let's move."


func _build_rig() -> void:
	if not ResourceLoader.exists(PLAYER_RIG_SCENE):
		return
	var packed : PackedScene = load(PLAYER_RIG_SCENE)
	if not is_instance_valid(packed):
		return
	_rig = packed.instantiate()
	# REAL BUG FIX: must be set BEFORE add_child() -- player.gd's own
	# _ready() (which fires the instant this enters the tree) checks this
	# flag to skip real-player-only setup (class-select UI cascading into
	# the deck-choice screen, claiming the viewport camera, re-binding the
	# WeaponsManager, hiding its own body for first-person view) that has
	# no business running for a puppeted ally. See player.gd's own
	# is_ai_puppet declaration for the full story.
	if "is_ai_puppet" in _rig:
		_rig.set("is_ai_puppet", true)
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
	_fps_pivot  = _rig.get_node_or_null("CameraRoot/FPSPivot") as Node3D
	if is_instance_valid(_weapon_manager) and _weapon_manager.has_method("bind_player") and is_instance_valid(_aim_camera):
		# bind_player's first arg only matters as a fallback source for
		# get_shoot_origin()/get_shoot_direction() (basegun.gd checks
		# has_method before calling either) -- this script implements
		# neither, so basegun.gd's own camera-forward fallback is what
		# actually aims every shot, driven by _aim_camera's orientation.
		_weapon_manager.call("bind_player", self, _aim_camera)

	# REAL BUG FIX: "ally not holding gun, it floats disconnected".
	# WeaponsManager._process() positions the equipped weapon at a
	# first-person viewmodel offset FROM THE CAMERA every frame -- correct
	# for the real player (the camera IS their eyes), wrong for a
	# third-person-viewed puppet: the gun rendered floating near the
	# ally's aim camera (head height) instead of in its hand. Fix: attach a
	# BoneAttachment3D to the rig's real right-hand bone (confirmed via
	# Player.tscn's own skeleton data: "mixamorig_RightHand", NOT
	# "mixamorig5_RightHand" -- that "5" prefix is zombie.gd's separate rig,
	# a different asset) and hand it to WeaponsManager as the position
	# anchor. Orientation still comes from the aim camera (see
	# WeaponsManager.gd's own note) since the hand bone's rest-pose
	# rotation follows the walk/idle animation, not aim direction.
	var skeleton := _rig.get_node_or_null("Skeleton3D") as Skeleton3D
	if is_instance_valid(skeleton) and skeleton.find_bone("mixamorig_RightHand") >= 0:
		var hand_anchor := BoneAttachment3D.new()
		hand_anchor.name = "WeaponHandAnchor"
		hand_anchor.bone_name = "mixamorig_RightHand"
		skeleton.add_child(hand_anchor)
		if is_instance_valid(_weapon_manager) and "third_person_anchor" in _weapon_manager:
			_weapon_manager.set("third_person_anchor", hand_anchor)

	# REAL BUG FIX: "skin disappeared after engagement". player.gd's own
	# _ready() schedules get_tree().create_timer(0.2).timeout.connect(
	# _setup_body_layers) to hide the REAL player's own body meshes for
	# first-person view (so you don't see your own head blocking the
	# camera). That timer fires via the SceneTree, not this rig's own
	# _process/_physics_process, so disabling those above does NOT stop
	# it -- ~0.2s after every ally spawns, its Ch15 skin silently goes
	# invisible. Nothing else in player.gd ever re-shows it (confirmed:
	# _set_body_visible/_refresh_body_visibility have no other call
	# sites), so a single delayed re-show after that timer has already
	# fired is sufficient -- no need to fight or cancel the original timer.
	get_tree().create_timer(0.4).timeout.connect(func():
		if is_instance_valid(_rig) and _rig.has_method("_set_body_visible"):
			_rig.call("_set_body_visible", true)
	)


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

	if _chat_cooldown_timer > 0.0:
		_chat_cooldown_timer -= delta
	if _chat_timer > 0.0:
		_chat_timer -= delta
		if _chat_timer <= 0.0 and is_instance_valid(_chat_label):
			_chat_label.visible = false

	if trapped:
		_tick_trapped(delta)
		return

	if not is_on_floor():
		velocity.y -= 9.8 * delta

	_brain_tick(delta)

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
	_try_bark("You were just freed from captivity and are ready to fight.",
		_fallback_freed_bark(), "freed")
	freed.emit()


# ── Builder ──────────────────────────────────────────────────────────
const BUILDER_WANDER_RADIUS : float = 6.0
const BUILDER_PATROL_POINTS : int   = 6
var _builder_patrol_pts : Array = []
var _builder_patrol_idx : int  = 0

func _tick_builder(delta: float) -> void:
	if _check_self_defense(delta): return
	_tick_builder_wander(delta)
	_decision_timer -= delta
	if _decision_timer > 0.0: return
	_decision_timer = DECISION_INTERVAL
	_try_spend_gold()


## REAL BUG FIX (2026-08-24): "builder teammate should patrol base" --
## Builder previously picked a fresh RANDOM point every time it arrived
## near its last one, which reads as aimless drifting rather than a
## deliberate patrol. Walks a fixed circular route around its own spawn
## point instead (Builder always spawns near the base -- see
## game_phase_script.gd::_spawn_team_ally's base.global_position offset),
## same pattern HiveCluster.gd already uses for its own patrol guards
## (_patrol_circle) -- a real, repeatable loop instead of a random walk.
func _tick_builder_wander(delta: float) -> void:
	if _builder_patrol_pts.is_empty():
		for i in range(BUILDER_PATROL_POINTS):
			var ang := TAU * float(i) / float(BUILDER_PATROL_POINTS)
			_builder_patrol_pts.append(_spawn_pos + Vector3(cos(ang), 0.0, sin(ang)) * BUILDER_WANDER_RADIUS)
	var dest : Vector3 = _builder_patrol_pts[_builder_patrol_idx]
	if global_position.distance_to(dest) < 1.0:
		_builder_patrol_idx = (_builder_patrol_idx + 1) % _builder_patrol_pts.size()
		dest = _builder_patrol_pts[_builder_patrol_idx]
	_seek(dest)
	_face(dest)
	_update_stuck(delta)


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
		# Aggro (>1x mult) fires faster; Caution (<1x mult) fires slower --
		# same brain-driven modulation _seek() applies to movement speed.
		_attack_timer = attack_cooldown / maxf(_current_speed_mult(), 0.01)
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
				_attack_timer = attack_cooldown / maxf(_current_speed_mult(), 0.01)
				_do_attack()
		else:
			_seek(_target.global_position)
			_face(_target.global_position)
			_update_stuck(delta)
	else:
		# Return toward spawn/base rather than wandering off
		var to_home := _spawn_pos - global_position; to_home.y = 0.0
		if to_home.length() > 2.0:
			_seek(_spawn_pos)
			_face(_spawn_pos)
			_update_stuck(delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * delta * 4.0)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * delta * 4.0)


## AIM_HEIGHT_OFFSET: CharacterBody3D targets (zombies, players) have their
## global_position at the FEET, not center-mass -- confirmed via a real
## raycast diagnostic: every shot from an elevated ally landed on a
## StaticBody3D (terrain) at the target's ground-level XZ, not the target
## itself. Aiming _aim_pitch_at() straight at a target's raw feet position
## from above sends the ray into the floor just short of the target's own
## capsule, which starts a bit higher up. Offsetting the aim point to
## roughly torso height fixes this without touching basegun.gd's raycast
## itself (target height varies by creep type, but a fixed mid-body offset
## is far better than aiming at the ground every time).
const AIM_HEIGHT_OFFSET : float = 1.0

## REAL BUG FIX (2026-08-24): "ally facing wrong way while moving/aiming".
## Measured directly via a headless behavioral test (spawned a real Guard
## chasing a real target): Godot's look_at() orients the node's local -Z
## axis at the target, but this rig's actual facing convention (confirmed
## against player.gd's OWN topdown-aim code, which directly assigns
## `rotation.y = atan2(dir.x, dir.z)` at lines ~1216-1218/1523-1525 for the
## real player) is the OPPOSITE sign -- look_at() put the ally's rig exactly
## 180 degrees off from its actual travel/aim direction on every single
## tick (diff_deg==180.0 in the smoke test, not noise). Switched to the
## same direct atan2-based assignment player.gd itself uses elsewhere,
## rather than look_at(), so both the ally and the real player share one
## proven-correct facing convention instead of two conflicting ones.
func _face(pos: Vector3) -> void:
	var dir := pos - global_position; dir.y = 0.0
	if dir.length_squared() > 0.01:
		rotation.y = atan2(dir.x, dir.z)   # body yaw only -- no body tilt
	_aim_pitch_at(pos + Vector3(0.0, AIM_HEIGHT_OFFSET, 0.0))


## REAL BUG FIX: "AI teammate just shoots walls". _face() above only ever
## yaws the BODY toward a flattened (same-Y) target, matching player.gd's
## own rotate_y()-for-yaw split -- but a real player ALSO pitches the
## camera up/down every frame via mouse input (_handle_mouse_look:
## fps_pivot.rotation_degrees.x -= rel.y * sensitivity). Nothing was ever
## driving that pitch for an ally, so basegun.gd's camera-forward raycast
## (dir = -camera.global_transform.basis.z) always fired dead level at
## whatever height the rig's rest pose happened to be -- on this valley
## terrain's slopes, or against any target not at the exact same Y, that
## means the shot flies level into the nearest wall/terrain instead of
## angling to the real target. Confirmed via player.gd:1024-1044's mouse-
## look: positive fps_pivot.rotation_degrees.x = look up, matching
## max_look_up being positive and max_look_down negative.
func _aim_pitch_at(pos: Vector3) -> void:
	if not is_instance_valid(_fps_pivot): return
	var eye : Vector3 = _fps_pivot.global_position
	var to_target : Vector3 = pos - eye
	var horiz : float = Vector2(to_target.x, to_target.z).length()
	if horiz < 0.01: return
	var pitch_deg : float = rad_to_deg(atan2(to_target.y, horiz))
	_fps_pivot.rotation_degrees.x = clampf(pitch_deg, -89.0, 89.0)


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
	# Hebbian reinforcement -- zombie.gd's own brain never calls learn() at
	# all. A confirmed kill strengthens the Alert->Aggro bond (bounded by
	# Spikeling's own GROW_CEIL/RELAX_RATE homeostasis, so this can't run
	# away unboundedly), so an ally that's actually landing kills gets
	# measurably bolder about engaging over the course of a match.
	if is_instance_valid(brain):
		brain.learn(1.0)
	if is_instance_valid(_status_label):
		_status_label.text = "%s %s\n+%d🪙 earned!" % [_class_icon(), _class_name_str(), reward]
	_try_bark("You just killed a zombie.", _fallback_kill_bark(), "kill")


func _build_nav_agent() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.path_desired_distance = 0.5
	_nav_agent.target_desired_distance = 0.75
	_nav_agent.avoidance_enabled = false   # a handful of allies -- not worth RVO overhead
	add_child(_nav_agent)


## Routes through the baked navmesh (NavigationServer3D, same map
## _unstuck() already reads) instead of a straight line, so allies path
## around building walls and through doorways rather than beelining into
## geometry. Falls back to the old straight-line behavior if the nav
## agent isn't ready yet or the world has no baked navigation at all --
## same graceful-degradation shape as every other optional system in this
## file (HordeLLM, VoiceboxTTS).
func _seek(pos: Vector3) -> void:
	var move_target := pos
	if is_instance_valid(_nav_agent) and get_world_3d().navigation_map != RID():
		_nav_agent.target_position = pos
		if not _nav_agent.is_navigation_finished():
			move_target = _nav_agent.get_next_path_position()
	var dir := move_target - global_position; dir.y = 0.0
	if dir.length_squared() > 0.01:
		dir = dir.normalized()
		var eff_speed : float = move_speed * _current_speed_mult()
		velocity.x = dir.x * eff_speed
		velocity.z = dir.z * eff_speed


## Call only from a branch where this ally is actually trying to travel
## somewhere (see _tick_builder_wander/_tick_guard) -- NOT a global per-tick
## check, so legitimately-stationary states (Scout sentry duty, Guard
## holding position in range, self-defense standoffs) never risk a false
## "stuck" read.
func _update_stuck(delta: float) -> void:
	last_position_timer += delta
	if last_position_timer < 0.5:
		return
	last_position_timer = 0.0

	var moved : float = Vector2(
		global_position.x - last_position.x,
		global_position.z - last_position.z
	).length()
	last_position = global_position

	if moved < STUCK_DISTANCE:
		stuck_timer += 0.5
		if stuck_timer >= STUCK_TIME:
			stuck_timer = 0.0
			_unstuck()
	else:
		stuck_timer = 0.0


## Same nav-checked random-hop recovery zombie.gd's own _unstuck() uses --
## a raw teleport risks landing inside geometry, so the target point is
## clamped to the nearest real navmesh point first (falls back to a raw
## teleport only if this world has no baked navigation at all).
func _unstuck() -> void:
	var dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if dir.length_squared() <= 0.01:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var test_pos : Vector3 = global_position + dir * 1.5
	var nav_map : RID = get_world_3d().navigation_map
	if nav_map != RID():
		var closest : Vector3 = NavigationServer3D.map_get_closest_point(nav_map, test_pos)
		if closest.distance_to(test_pos) < 1.0:
			global_position = test_pos
		else:
			# REAL BUG FIX: the inherited zombie.gd version of this check
			# (see that file's own _unstuck()) silently does nothing when
			# the closest navmesh point is too far from test_pos -- and a
			# test point 1.5 units into a WALL is exactly the case most
			# likely to land far off-navmesh, since baked nav stops at wall
			# boundaries. That made "stuck against a wall" (the one bug
			# this whole recovery system exists for) the scenario where it
			# was most likely to do nothing. Snapping to the closest valid
			# navmesh point instead still moves the ally somewhere real and
			# on-mesh, rather than leaving it in place on a coin-flip.
			global_position = closest
	else:
		global_position = test_pos
	velocity.x += dir.x * 5.0
	velocity.z += dir.z * 5.0
	if is_on_floor():
		velocity.y = 4.0


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
		_fire_shoot_animation()
		return
	if _target.has_method("take_damage"):
		_target.take_damage(attack_damage, self)


## REAL BUG FIX: "no shooting animation". A real player's shoot animation
## is triggered by player.gd's own input handler (animation_tree.set on
## KEY PRESS, see player.gd's ANIM_SHOOT const) -- entirely separate from
## basegun.gd's shoot() logic, which only does the raycast/damage and never
## touches an AnimationTree itself. team_ally.gd calls WeaponsManager
## directly (there's no keypress to intercept), so that trigger never fired
## for allies. Reuses this script's own already-declared SHOOT_ANIM_PARAMS
## candidate list, same probing pattern _find_blend_param() already uses.
func _fire_shoot_animation() -> void:
	if not is_instance_valid(_anim_tree) or not _anim_tree.active: return
	for p in SHOOT_ANIM_PARAMS:
		if _anim_tree.get(p) != null:
			_anim_tree.set(p, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			return


func take_damage(amount: float, _source = null) -> void:
	# Every class is a valid, damageable target now that all three carry a
	# real weapon and can shoot back -- Builder/Scout are no longer flatly
	# immune, just not proactively aggressive (see _check_self_defense).
	if trapped: return   # a caged, not-yet-freed ally can't be meaningfully attacked
	if is_dead: return
	health -= amount
	# Self-preservation reflex zombie.gd's own brain doesn't have -- getting
	# actually hit is a much stronger "be careful" signal than just losing
	# ground on a target.
	if is_instance_valid(brain):
		brain.stimulate("Caution", DAMAGE_CAUTION_STIMULUS)
	# Core-memory writes + panic: every hit stresses the chain; a heavy hit
	# anchors a CORE near-death memory, light hits only a routine BULK one.
	_ensure_core_memory().apply_stress(0.35)
	var health_frac := health / maxf(max_health, 1.0)
	if health_frac <= 0.25 and not _near_death_remembered:
		_near_death_remembered = true
		_ensure_core_memory().remember("near_death", true)
	elif health_frac > 0.25:
		_ensure_core_memory().remember("scrape:%d" % (Time.get_ticks_msec() / 10000), false)
	if health > 0.0:
		_try_bark("You just took %d damage and are at %d%% health." %
			[int(amount), int(100.0 * health / maxf(max_health, 1.0))],
			_fallback_hurt_bark(), "hurt")
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
