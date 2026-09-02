# ============================================================
# zombie.gd
# AAA FULL SYSTEM — SINGLE SCRIPT
# ============================================================
# ORIGINAL SYSTEMS (ALL RETAINED, NONE REMOVED)
# ------------------------------------------------------------
# • Stable lane pushing
# • No castle spinning
# • No gate orbiting
# • No attack slot bugs
# • Easy to debug
# • Pool friendly
# • Horde friendly
# • Damage numbers
# • Energy aura
# • Health bars
# • LOD support
# • Multiplayer safe
# ============================================================
# AAA EXTENSIONS ADDED
# ------------------------------------------------------------
# • Elite zombie systems
# • Boss mutations
# • Swarm intelligence
# • Advanced animation states
# • Damage types + armor system
# • Debug overlay tools
# • Network sync layer hooks
# • Phase zombie double health bar
# • Armor DR types (slash/blunt/pierce/magic/fire/ice/poison)
# • Status effects (burn/freeze/poison/stun/slow)
# • Boss phase transitions
# • Swarm pheromone broadcasting
# • Elite ability pool
# • Threat scoring for targeting
# • Debug gizmo overlay
# • Sync snapshot API
# ============================================================

extends CharacterBody3D

# ============================================================
# ENUMS
# ============================================================

enum AIMode {
	LANE_PUSH,
	ATTACK,
	DEFEND,
	STAY,
	FOLLOW_OWNER,
	PATROL
}

enum LOD {
	FULL,
	CHEAP,
	SLEEP
}

# ---- AAA: Zombie tier -------------------------------------

enum ZombieTier {
	BASIC,
	ELITE,
	BOSS,
	PHASE
}

# ---- AAA: Damage types ------------------------------------

enum DamageType {
	PHYSICAL,
	SLASH,
	BLUNT,
	PIERCE,
	MAGIC,
	FIRE,
	ICE,
	POISON,
	TRUE_DAMAGE
}

# ---- AAA: Status effect types -----------------------------

enum StatusType {
	NONE,
	BURN,
	FREEZE,
	POISON,
	STUN,
	SLOW,
	MARKED,
	ENRAGED
}

# ---- AAA: Elite ability pool ------------------------------

enum EliteAbility {
	NONE,
	REGEN,
	SHIELD_BURST,
	LEAP,
	FRENZY,
	GHOST,
	SPORE_CLOUD,
	LIFE_STEAL,
	CHAIN_ATTACK
}

# ============================================================
# TEAM
# ============================================================

@export var team_id : int = 1
# Conversion is NOT exported — scene files cannot accidentally enable this
var conversion_enabled : bool = false   # set to true only by Necromancer class abilities
var conversion_health_pct : float = 0.35
# ============================================================
# STATS
# ============================================================

@export_group("Stats")

@export var max_health : float = 220.0  # was 350 -- early game too punishing
@export var move_speed : float = 4.0
@export var damage : float = 9.0  # was 15 -- ~40% cut for early-game survivability

@export var attack_range : float = 2.3
@export var turret_range : float = 3.5
@export var base_range : float = 5.0

@export var aggro_range : float = 14.0

		# REAL BUG FIX (2026-07-24): the real "attack" AnimationLibrary clip
		# is 2.633s long (confirmed via a real headless AnimationLibrary
		# inspection), but the old 0.9s cooldown let a new attack re-fire
		# the same OneShot node well before the swing finished playing --
		# every single zombie attack was visibly cut off mid-animation.
		# Raised to match the real clip length so the swing actually
		# completes. User's explicit choice over trimming the clip or
		# leaving it, since combat pacing/DPS was already tuned around the
		# old cadence and needs re-checking against this if it feels slow.
@export var attack_cooldown : float = 2.6

@export var gravity : float = 20.0

@export var gold_reward : int = 25
@export var health_bar_height : float = 2.8 :
	set(v):
		health_bar_height = v
		if is_instance_valid(health_bar_root):
			health_bar_root.position.y = v

# ============================================================
# STUCK
# ============================================================

@export_group("Stuck")

@export var stuck_time : float = 1.5
@export var stuck_distance : float = 0.4

# ============================================================
# AUDIO
# ============================================================

@export_group("Audio")

@export var audio_enabled : bool = true

@export var attack_sounds : Array[AudioStream] = []
@export var hurt_sounds : Array[AudioStream] = []
@export var death_sounds : Array[AudioStream] = []

# ---- AAA: Additional audio slots --------------------------

@export var ability_sounds : Array[AudioStream] = []
@export var phase_sounds : Array[AudioStream] = []
@export var enrage_sounds : Array[AudioStream] = []

# ============================================================
# AAA: TIER & IDENTITY
# ============================================================

@export_group("AAA Tier")

@export var zombie_tier : ZombieTier = ZombieTier.BASIC

@export var tier_label : String = ""

# ---- Phase zombie settings --------------------------------

@export var is_phase_zombie : bool = false
@export var phase_count : int = 2
@export var phase_health_equal : bool = true
@export var phase_transition_delay : float = 0.8

# ---- Boss settings ----------------------------------------

@export var is_boss : bool = false
@export var boss_phase_thresholds : Array[float] = [0.75, 0.5, 0.25]
@export var boss_enrage_threshold : float = 0.25

# ── BOSS VARIANTS (2026-08-28): "boss variations with SNN minds reactive
# to their environment and enemies -- giant, cyclops, mythical creatures".
# Reuses real, already-in-project assets: 3 real unused monster .glb
# variants (zombie_variants/zombie_variant_{demon,warrok,maw}.glb, honestly
# built by blender_zombie_variants_run.py from 3 distinct pre-existing
# monster base meshes -- see that script's own header for the full,
# honest provenance) plus the mushroom-boss model in
# zombie/mushroom-boss-game-ready-with-animations/, none of which were
# ever wired into a live scene. Each variant gets a REAL distinct
# reactivity, not just a palette swap: see _apply_boss_variant() and the
# variant-specific stimulus in _brain_tick() below.
enum BossVariant { NONE, DEMON, ORC_TROLL, MAW, MUSHROOM }
@export var boss_variant : BossVariant = BossVariant.NONE
const BOSS_VARIANT_TINT := {
	BossVariant.DEMON:     Color(0.9, 0.05, 0.02),   # hot red -- matches blender_zombie_variants_run.py's own glow_color
	BossVariant.ORC_TROLL: Color(0.1, 0.7, 0.15),    # sickly green, same source
	BossVariant.MAW:       Color(0.55, 0.15, 0.75),  # violet -- caster archetype
	BossVariant.MUSHROOM:  Color(0.75, 0.55, 0.15),  # spore-amber
}

# ---- Elite settings ---------------------------------------

@export var is_elite : bool = false
@export var elite_ability : EliteAbility = EliteAbility.NONE
@export var elite_ability_cooldown : float = 8.0

# Set by LaneSpawner for the wave mid-point elite — guarantees a creep card drop on death
var elite_drops_creep_card : bool = false

# ============================================================
# AAA: ARMOR SYSTEM
# ============================================================

@export_group("AAA Armor")

@export var armor_physical : float = 0.0
@export var armor_slash : float = 0.0
@export var armor_blunt : float = 0.0
@export var armor_pierce : float = 0.0
@export var armor_magic : float = 0.0
@export var armor_fire : float = 0.0
@export var armor_ice : float = 0.0
@export var armor_poison : float = 0.0

# ---- DR cap -----------------------------------------------

@export var armor_dr_cap : float = 0.85

# ============================================================
# AAA: SWARM INTELLIGENCE
# ============================================================

@export_group("AAA Swarm")

@export var swarm_enabled : bool = true
@export var swarm_broadcast_radius : float = 12.0
@export var swarm_pheromone_strength : float = 1.0
@export var swarm_follow_leader : bool = true

# ============================================================
# AAA: DEBUG
# ============================================================

@export_group("AAA Debug")

@export var debug_overlay_enabled : bool = false
@export var debug_show_range : bool = true
@export var debug_show_target_line : bool = true
@export var debug_show_ai_mode : bool = true
@export var debug_show_status : bool = true

# ============================================================
# AAA: NETWORK
# ============================================================

@export_group("AAA Network")

@export var network_sync_enabled : bool = false
@export var network_sync_rate : float = 0.1
@export var network_authority_id : int = 1

# ============================================================
# HEALTH
# ============================================================

var health : float = 0.0

# ---- Phase health tracking --------------------------------

var phase_current : int = 0
var phase_health_thresholds : Array[float] = []
var phase_transitioning : bool = false
var phase_transition_timer : float = 0.0

# ============================================================
# TARGETS
# ============================================================

var target : Node3D = null
var target_type : String = ""

var enemy_base : Node3D = null
var friendly_base : Node3D = null

# REAL BUG FIX (2026-08-24): ZombieHordeManager._promote_to_z1() has always
# had `if "_horde_mgr" in z: z.set("_horde_mgr", self)`, but this var was
# never actually declared anywhere on this script -- the "in" check always
# evaluated false, so this line was a total no-op for every pool-recycled
# zombie. Needed as a real ownership marker: a Z1-active zombie can be
# either pool-recycled (_promote_to_z1, owned by the pool, safe to demote
# back to it) or externally registered (register_z1(), HiveCluster patrol
# guards/Egg hatch waves, owns its OWN lifecycle) -- demoting an externally-
# registered zombie back into the shared _pool would let a later
# _promote_to_z1() hand out a zombie its real owner still thinks is theirs.
var _horde_mgr : Node = null

# ============================================================
# AI
# ============================================================
# ============================================================
# PATH VALIDATION
# ============================================================

var unreachable_timer : float = 0.0
var last_target_distance : float = INF
var target_progress_timer : float = 0.0
var _unreachable_blacklist : Dictionary = {}  # node → cooldown timer

@export var unreachable_timeout : float = 2.5
@export var min_progress_distance : float = 0.75
var ai_mode : AIMode = AIMode.LANE_PUSH

# ============================================================
# LANE
# ============================================================

var lane_waypoints : Array[Vector3] = []

var current_waypoint : int = 0

# ============================================================
# TIMERS
# ============================================================

var attack_timer       : float = 0.0
var _attack_anim_timer : float = 0.0
## Real length of this creep's attack animation clip, derived in _ready() --
## see _try_attack()'s comment. 0.7 is only a fallback if no clip is found.
var _attack_anim_len   : float = 0.7
var _warned_no_attack_anim : bool = false
var _nav_agent         : NavigationAgent3D = null   # no longer created (see _ready()); left null-safe for any stray reads
var _nav_update_timer  : float = 0.0
const NAV_UPDATE_INTERVAL : float = 0.4
var _skeleton          : Skeleton3D = null
var _hips_bone_idx     : int = -1
var retarget_timer : float = 0.0
var _ground_ray_exclude : Array[RID] = []   # self + ragdoll bone RIDs, see _ready()
var _structure_ray_exclude_timer : float = 0.0
const STRUCTURE_RAY_REFRESH : float = 2.0   # castle/base doesn't move; turrets get built/destroyed over a match, so refresh occasionally rather than every frame

# ── DARK-HORROR RESKIN (see theme_horror/HorrorTheme.gd) ──
# Sickly-green tint on hostile-horde (team_id==2) zombies only -- player-
# owned deck creeps (Zombie/Tank/Shaman/Berserker/Leaper, team_id==1,
# same shared script) are left at their normal skin color. Toggle off
# here if it doesn't read well in an actual playtest -- nothing else
# depends on this flag.
const HorrorTheme = preload("res://theme_horror/HorrorTheme.gd")
const ENABLE_HORROR_TINT : bool = true

# ── SPIKELING MOVEMENT BRAIN (2026-07-20) ──
const SpikelingScript = preload("res://spikeling.gd")
const AGGRO_BURST_MULT := 1.30
const CAUTION_DAMP_MULT := 0.80
const BRAIN_EFFECT_DURATION := 1.0
const CLOSING_STIMULUS_SCALE := 40.0
# player-team-only additions (team_id==1) -- see brain-load comment in _ready()
const ALLY_ALERT_RADIUS              : float = 12.0
const ALLY_ALERT_STIMULUS_PER_THREAT : float = 30.0
const ALLY_DAMAGE_CAUTION_STIMULUS   : float = 60.0
var brain: Spikeling
var _prev_target_dist: float = -1.0
var _aggro_timer: float = 0.0
var _caution_timer: float = 0.0
var _smooth_speed_mult: float = 1.0

# ============================================================
# STUCK
# ============================================================

## Shared stuck-detection + nav-checked recovery -- see MovementRecovery.gd.
## Owns its own last_position/timers internally now (previously loose vars
## on this script, duplicated near-verbatim in team_ally.gd's own copy).
var _recovery : MovementRecovery = MovementRecovery.new()

# ============================================================
# NEIGHBORS
# ============================================================

var neighbors_cache : Array = []

# ── ZHM-pushed caches — refreshed every 0.25s by ZombieHordeManager.
# Replaces per-frame get_nodes_in_group("players"/"turrets") scans in
# _find_blocker() and _find_best_target(), eliminating the group-scan
# spike that scales with horde size. Falls back to the live group scan
# when empty (e.g. for zombies not tracked by ZHM).
var _players_cache : Array = []
var _turrets_cache : Array = []

# ============================================================
# LOD
# ============================================================

var lod : LOD = LOD.FULL
var _body_meshes : Array[MeshInstance3D] = []
var _mesh_near   : bool = true   # true = shadows on, false = shadows off

# ============================================================
# STATE
# ============================================================

var is_dead : bool = false

# ============================================================
# AUDIO PLAYER
# ============================================================

var sfx : AudioStreamPlayer3D = null
var sfx_ability : AudioStreamPlayer3D = null

# ============================================================
# ANIMATION
# ============================================================

var anim_tree : AnimationTree = null

# ---- AAA: Advanced anim state tracking --------------------

var anim_state_current : String = "idle"
var anim_blend_speed : float = 0.0

# ============================================================
# ENERGY
# ============================================================

var energized_timer : float = 0.0

# ============================================================
# HEALTH BAR — PRIMARY
# ============================================================

var health_bar_root : Node3D = null
var health_bar_fill : MeshInstance3D = null

# ============================================================
# HEALTH BAR — PHASE (SECOND BAR)
# ============================================================

var phase_bar_root : Node3D = null
var phase_bar_fill : MeshInstance3D = null
var phase_bar_segment_markers : Array[MeshInstance3D] = []

# ============================================================
# ENERGY ICON
# ============================================================

var energy_icon : MeshInstance3D = null

# ============================================================
# AAA: STATUS EFFECTS
# ============================================================

var status_effects : Dictionary = {}
# Format: { StatusType: { timer: float, strength: float, tick_timer: float } }

var is_stunned : bool = false
var is_frozen : bool = false
var current_slow : float = 0.0

# ============================================================
# AAA: ARMOR SHIELD (elite)
# ============================================================

var shield_hp : float = 0.0
var shield_max : float = 0.0
var shield_active : bool = false

# ============================================================
# AAA: BOSS PHASE
# ============================================================

var boss_phase : int = 0
var boss_enraged : bool = false
var boss_phase_triggered : Array[bool] = []

# ============================================================
# AAA: ELITE ABILITY
# ============================================================

var elite_ability_timer : float = 0.0
var elite_ability_active : bool = false
var elite_ghost_timer : float = 0.0

# ============================================================
# AAA: SWARM
# ============================================================

var swarm_leader : Node3D = null
var swarm_pheromone_pos : Vector3 = Vector3.ZERO
var swarm_pheromone_timer : float = 0.0
var swarm_pheromone_active : bool = false

# ============================================================
# AAA: NETWORK SYNC
# ============================================================

var net_sync_timer : float = 0.0
var net_last_snapshot : Dictionary = {}

# ============================================================
# AAA: LIFE STEAL
# ============================================================

var life_steal_pct : float = 0.0

# ============================================================
# AAA: ENRAGE MULTIPLIERS
# ============================================================

var enrage_damage_mult : float = 1.0
var enrage_speed_mult : float = 1.0

# AIDirector.gd broadcasts fleet-wide strategic multipliers here -- kept
# SEPARATE from enrage_speed_mult/enrage_damage_mult on purpose. Those are
# already written by this zombie's own individual low-HP/elite enrage
# trigger (search "enrage_damage_mult =" elsewhere in this file); if the
# director overwrote the same fields, a fleet-wide directive would erase
# an individual zombie's own enrage state, and vice versa. Multiplied
# together wherever speed/damage is actually computed instead.
var director_speed_mult  : float = 1.0
var director_damage_mult : float = 1.0

# ============================================================
# AAA: DEBUG OVERLAY
# ============================================================

var debug_label : Node = null
var debug_draw_timer : float = 0.0
# ============================================================
# COMMAND STATE
# ============================================================

enum SquadOrder {
	NONE,
	ATTACK,
	DEFEND,
	PATROL,
	STAY,
	FOLLOW
}

var patrol_points : Array = []
var _patrol_idx   : int   = 0
var _patrol_dir   : int   = 1
var squad_order      : int     = SquadOrder.NONE
var squad_target     : Node3D  = null
var squad_position   : Vector3 = Vector3.ZERO
var order_persistent : bool    = false
var squad_persistent : bool    = false
var squad_timer      : float   = 0.0

# unreachable handling
var _path_fail_time : float = 0.0

# REAL BUG FIX (2026-07-24): _tick_attack() kept whatever non-base target it
# already had FOREVER (until that target died/became invalid), so a zombie
# mid-fight with a turret/unit never re-ran _find_best_target() and would
# completely ignore a player who walked right up next to it ("zombies don't
# go for player 1st priority when close"). This timer forces a periodic
# re-check so a much higher-priority player can still interrupt a sticky
# lower-priority target, without retargeting every single frame.
var _retarget_timer : float = 0.0
const RETARGET_INTERVAL : float = 0.4
const MAX_UNREACHABLE_TIME := 2.5
# ============================================================
# NOTE (2026-07-25): the old "_update_targeting()" priority system that used
# to live here was a duplicate of _find_best_target() below (same players >
# units > structures priority, just live group-scans instead of cached
# arrays) and was never called from anywhere in this file — removed rather
# than left as a second, contradictory "priority system" to be confused
# with the real one. _find_best_target() (squad-order path) and
# _find_blocker() (default LANE_PUSH path) are now the only target-priority
# code in this file.
# ============================================================
func command_follow(player_node: Node3D, persistent: bool = false) -> void:
	squad_order      = SquadOrder.FOLLOW
	squad_target     = player_node
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0
	ai_mode          = AIMode.FOLLOW_OWNER


func command_defend(persistent: bool = false) -> void:
	squad_order      = SquadOrder.DEFEND
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0
	ai_mode          = AIMode.DEFEND


func command_attack_position(pos: Vector3, persistent: bool = false) -> void:
	squad_order      = SquadOrder.ATTACK
	squad_position   = pos
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0


## REAL BUG FIX (2026-07-25): "no patrolling zombies around hives/eggs" --
## HiveCluster._spawn_patrol_guards() used to poke ai_mode directly
## (guard.set("ai_mode", 5)), but _tick_full() only ever dispatches on
## ai_mode when squad_order != SquadOrder.NONE -- with no squad_order set,
## every guard fell straight through to the unconditional
## "ai_mode = LANE_PUSH; _tick_lane_march()" default and just marched off to
## the enemy base like a normal zombie, regardless of what ai_mode said.
## Patrol needs a real, persistent squad_order (same pattern as
## command_defend/command_follow above) to actually take effect.
func command_patrol(persistent: bool = true) -> void:
	squad_order      = SquadOrder.PATROL
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0
	ai_mode          = AIMode.PATROL


func command_hold(persistent: bool = false) -> void:
	squad_order      = SquadOrder.STAY
	order_persistent = persistent
	squad_persistent = persistent
	squad_timer      = 0.0


func clear_order() -> void:
	squad_order      = SquadOrder.NONE
	squad_target     = null
	order_persistent = false
	squad_persistent = false
	squad_timer      = 0.0
func _ready() -> void:
	var _dbg := get_node_or_null("/root/DebugTuningPanel")
	if _dbg: damage = _dbg.zombie_damage_override

	health = max_health
	floor_snap_length   = 0.4
	floor_stop_on_slope = true
	floor_max_angle     = deg_to_rad(55.0)

	# MOVEMENT REWORK (2026-07-20): "they don't move normal, they glitch
	# around and bounce" -- _move_toward() used to branch between this
	# NavigationAgent's path direction and direct steering, and per this
	# project's own notes there's no reliably-baked NavMesh everywhere;
	# get_next_path_position() flickering between "a real path point" and
	# "current position" (when the path is stale/absent) caused sudden,
	# unpredictable direction snaps. avoidance_enabled=true also ran a real
	# RVO solver every tick whose output was NEVER actually consumed (no
	# set_velocity()/velocity_computed wiring) -- pure wasted computation.
	# Movement is now ALWAYS direct steering (deterministic, no flickering
	# branch), modulated by a real Spikeling brain (see _brain_tick()) for
	# organic speed instead of a flat constant. NavigationAgent3D itself is
	# no longer created at all.
	brain = SpikelingScript.new()
	# REAL FEATURE: player-owned units (deck-purchased Tank/Shaman/Berserker/
	# Leaper/Zombie -- all real subclasses of this same base script, see
	# tank.gd/shaman.gd/berserk.gd/leaper.gd's super._ready()/
	# super._physics_process() calls) get a 3rd Alert neuron wired into
	# Aggro via a real synapse, matching team_ally.gd's own brain design
	# ("extend the Spikeling brain to the deck creeps too"). Loaded for
	# EVERY unit regardless of team so there's one shared brain definition
	# to maintain, but Alert is only ever stimulated for team_id==1 (see
	# _brain_tick below) -- an unstimulated neuron never fires, so this is
	# a complete no-op for enemy zombies: their Aggro/Caution behavior is
	# byte-for-byte what it was before this change.
	brain.load_from_text(
		"neuron Aggro threshold=100 leak=8\n" +
		"neuron Caution threshold=100 leak=15\n" +
		"neuron Alert threshold=80 leak=10\n" +
		"synapse Alert -> Aggro weight=40\n" +
		"refractory=45\n")

	add_to_group("units")
	add_to_group("zombies")

	if is_phase_zombie:
		add_to_group("phase_zombies")

	if is_boss:
		add_to_group("boss_units")

	if is_elite:
		add_to_group("elite_units")

	_recovery.reset_progress(global_position)

	_setup_audio()

	anim_tree = _find_anim_tree()
	if anim_tree != null:
		anim_tree.active = true

	# Cache skeleton for root bone Y correction
	_skeleton = get_node_or_null("Skeleton3D") as Skeleton3D
	if not is_instance_valid(_skeleton):
		var found := find_children("*", "Skeleton3D", true, false)
		if not found.is_empty(): _skeleton = found[0] as Skeleton3D
	if is_instance_valid(_skeleton):
		# CORRECTED (2026-08-24): the 2026-07-25 comment here had it backwards.
		# Read directly from zombie.tscn: the SKELETON's own bones (bones/0/
		# name etc.) are "mixamorig_*", with NO "5" -- confirmed against the
		# actual .tscn data, not inferred. The "mixamorig5_" prefix is real,
		# but it belongs to attack.res/idle.res/run.res's ANIMATION TRACK
		# paths, not the skeleton's bone names -- a genuine mismatch between
		# the skeleton and the animations built for it (probably a
		# re-export that renamed one but not the other). That mismatch is
		# WHY attack.res's Hips (and all 51 other) tracks silently fail to
		# apply to any bone: Godot can't resolve "mixamorig5_Hips" against a
		# skeleton that only has "mixamorig_Hips". This lookup previously
		# searched for the wrong (animation-track) name, always missed, and
		# only "worked" via the bone-0 fallback below -- by luck of Hips
		# conventionally being bone 0, never actually verified by name.
		# Same corrected mismatch in LIMB_BONE_CHAINS/LIMB_HITBOX_BONE below.
		_hips_bone_idx = _skeleton.find_bone("mixamorig_Hips")
		if _hips_bone_idx < 0: _hips_bone_idx = 0   # fallback to bone 0
		for child in _skeleton.get_children():
			if child is MeshInstance3D:
				_body_meshes.append(child as MeshInstance3D)
		_build_limb_hitboxes()
		if ENABLE_HORROR_TINT and team_id == 2 and not _body_meshes.is_empty():
			HorrorTheme.apply_sickly_tint(_body_meshes, HorrorTheme.SICKLY_GREEN, 0.55)

	# REAL BUG FIX (2026-08-24 rebuild): derive the attack gravity-suppression
	# window from the REAL attack clip length instead of a hardcoded guess --
	# see _try_attack()'s use of _attack_anim_len for the full story. Reads
	# whichever attack animation this creep variant actually has (subclasses
	# like tank.gd set their own attack_cooldown before calling super._ready(),
	# so the clampf below already reads the correct per-variant value).
	var _ap_for_len := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if is_instance_valid(_ap_for_len):
		for _anim_name in ["animations/attack", "animations/Attack", "attack", "Attack"]:
			if _ap_for_len.has_animation(_anim_name):
				_attack_anim_len = _ap_for_len.get_animation(_anim_name).length
				break
	_attack_anim_len = clampf(_attack_anim_len, 0.3, attack_cooldown)

	# REAL BUG FIX (2026-07-19): _snap_to_ground()'s ground raycast only
	# excluded this body's own RID (get_rid()) -- but the 28 PhysicalBone3D
	# ragdoll bones under PhysicalBoneSimulator3D (Hips/Spine/Head/arms/legs)
	# are each SEPARATE physics bodies with their OWN RIDs, none excluded,
	# and none have an explicit collision_layer set (defaulting to Godot's
	# engine-default layer 1, which overlaps the ground/zombie shared
	# "layer 3" bitmask -- narrowing collision_mask alone can't cleanly
	# separate them). With collision_mask=0xFFFF, a downward raycast started
	# 8 units above the zombie's own head could hit ITS OWN torso/head
	# ragdoll collider before ever reaching real ground, snapping
	# global_position.y to a different, drifting value every single frame --
	# this is a strong, concrete explanation for "floating jumping glitching"
	# on every zombie, independent of crowding. Caching bone RIDs to exclude.
	_ground_ray_exclude = [get_rid()]
	var bone_sim: Node = get_node_or_null("PhysicalBoneSimulator3D")
	if not is_instance_valid(bone_sim):
		var found_sim := find_children("*", "PhysicalBoneSimulator3D", true, false)
		if not found_sim.is_empty(): bone_sim = found_sim[0] as Node
	if is_instance_valid(bone_sim):
		for bone in bone_sim.get_children():
			if bone is PhysicalBone3D:
				var pb := bone as PhysicalBone3D
				_ground_ray_exclude.append(pb.get_rid())
				# REAL BUG FIX (2026-07-19): these 28 ragdoll bones are
				# real, solid PhysicsBody3D colliders even while the
				# ragdoll simulation itself is inactive -- meaning the
				# zombie's own body was a physical obstacle to its OWN
				# move_and_slide() movement (confirmed: a zombie dropped
				# above open ground with nothing else nearby settled at
				# Y=3.3, not the real floor at Y=0.5 -- it was resting on
				# its own torso/head colliders). Disabling their collision
				# entirely while inactive; a future real death-ragdoll
				# activation should turn this back on for that bone only.
				pb.collision_layer = 0
				pb.collision_mask = 0

	_find_bases()

	_build_health_bar()

	_build_energy_icon()

	# ---- AAA inits ----------------------------------------

	_init_phase_system()

	_init_boss_system()

	_init_elite_system()

	_init_armor_display()

	if debug_overlay_enabled:
		_build_debug_overlay()

	if swarm_enabled:
		_register_swarm()

# ============================================================
# DISMEMBERMENT — real per-limb hit detection + partial ragdoll
# ============================================================
# Precise "shoot/slice off a specific body part" feature. Uses two real
# Godot mechanisms rather than faked mesh-cutting:
#   1. A small StaticBody3D hitbox per limb, attached via BoneAttachment3D
#      so it tracks the animated pose every frame -- tagged with metadata
#      so basegun.gd/sword.gd can identify exactly which limb was hit
#      (the existing headshot check was only a Y-height guess, not real
#      per-bone detection -- this is the real thing).
#   2. Skeleton3D.physical_bones_start_simulation(bone_list) -- confirmed
#      via direct testing to simulate ONLY the given bones, leaving the
#      rest of the skeleton under normal AnimationTree control. This lets
#      one limb ragdoll-detach while the zombie keeps walking/attacking.
# REAL BUG FIX (2026-08-24): "zombie hitbox not aligned" -- confirmed by
# directly reading zombie.tscn's own Skeleton3D bone list (bones/0/name
# etc.) that the REAL bone names are "mixamorig_*", with no "5". The
# "mixamorig5_" prefix used below was never real for THIS skeleton -- every
# find_bone() call using it returned -1 with no fallback (unlike
# _hips_bone_idx above, which happens to survive via its bone-0 fallback),
# so _build_limb_hitboxes() has been silently building NOTHING this whole
# time. Corrected to match the skeleton's actual bone names.
const LIMB_BONE_CHAINS : Dictionary = {
	"head":      ["mixamorig_Head"],
	"left_arm":  ["mixamorig_LeftShoulder", "mixamorig_LeftArm", "mixamorig_LeftForeArm",
				  "mixamorig_LeftHand", "mixamorig_LeftHandIndex1", "mixamorig_LeftHandIndex2",
				  "mixamorig_LeftHandIndex3"],
	"right_arm": ["mixamorig_RightShoulder", "mixamorig_RightArm", "mixamorig_RightForeArm",
				  "mixamorig_RightHand", "mixamorig_RightHandIndex1", "mixamorig_RightHandIndex2",
				  "mixamorig_RightHandIndex3"],
	"left_leg":  ["mixamorig_LeftUpLeg", "mixamorig_LeftLeg", "mixamorig_LeftFoot", "mixamorig_LeftToeBase"],
	"right_leg": ["mixamorig_RightUpLeg", "mixamorig_RightLeg", "mixamorig_RightFoot", "mixamorig_RightToeBase"],
}
# Representative bone each limb's hitbox attaches to (roughly mid-limb).
const LIMB_HITBOX_BONE : Dictionary = {
	"head":      "mixamorig_Head",
	"left_arm":  "mixamorig_LeftForeArm",
	"right_arm": "mixamorig_RightForeArm",
	"left_leg":  "mixamorig_LeftLeg",
	"right_leg": "mixamorig_RightLeg",
}
const LIMB_HITBOX_RADIUS : Dictionary = {
	"head": 0.14, "left_arm": 0.10, "right_arm": 0.10, "left_leg": 0.13, "right_leg": 0.13,
}
var _detached_limbs : Dictionary = {}   # limb_id -> true once gone
var _limb_hitboxes  : Dictionary = {}   # limb_id -> Area3D

func _build_limb_hitboxes() -> void:
	if not is_instance_valid(_skeleton): return
	for limb_id in LIMB_HITBOX_BONE.keys():
		var bone_name : String = LIMB_HITBOX_BONE[limb_id]
		if _skeleton.find_bone(bone_name) < 0:
			continue   # this rig doesn't have that bone -- skip gracefully
		var attach := BoneAttachment3D.new()
		attach.name = "LimbHitbox_%s" % limb_id
		attach.bone_name = bone_name
		_skeleton.add_child(attach)

		# Area3D, not StaticBody3D: this hitbox rides an animated bone (moves
		# every frame via BoneAttachment3D). Godot's physics server treats
		# StaticBody3D as immovable and pays a full broadphase re-insertion
		# cost whenever one is forcibly moved every frame -- with 5 hitboxes
		# x up to 60 real zombies that tanked FPS to ~6. Area3D is built for
		# cheap per-frame movement and has no physical resolution cost.
		# Dedicated layer (bit 20), mask 0 -- must never share a layer bit
		# with the zombie's own body (collision_layer=3) or move_and_slide()
		# would treat a zombie's own swinging limb as a solid obstacle (the
		# earlier cause of zombies spiraling/glitching into walls near base).
		# Weapon raycasts query collision_mask=0xFFFFFFFF + collide_with_areas
		# so they still detect it.
		var body := Area3D.new()
		body.name = "Hitbox"
		body.collision_layer = 1 << 19
		body.collision_mask  = 0
		body.monitoring   = false
		body.monitorable  = true
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = LIMB_HITBOX_RADIUS.get(limb_id, 0.11)
		capsule.height = capsule.radius * 3.0
		shape.shape = capsule
		body.add_child(shape)
		body.set_meta("limb_id", limb_id)
		body.set_meta("zombie_ref", self)
		body.add_to_group("zombie_limb_hitbox")
		attach.add_child(body)
		_limb_hitboxes[limb_id] = body


## Called by basegun.gd/sword.gd when a raycast/melee hit resolves to one
## of this zombie's limb hitboxes. hit_dir is the world-space direction the
## hit traveled, used to fling the detached limb outward realistically.
func detach_limb(limb_id: String, hit_dir: Vector3 = Vector3.FORWARD) -> void:
	if _detached_limbs.has(limb_id): return   # already gone
	if not is_instance_valid(_skeleton): return
	var chain : Array = LIMB_BONE_CHAINS.get(limb_id, [])
	if chain.is_empty(): return

	var bone_names : Array[StringName] = []
	for b in chain:
		if _skeleton.find_bone(b) >= 0:
			bone_names.append(StringName(b))
	if bone_names.is_empty(): return

	_skeleton.physical_bones_start_simulation(bone_names)

	# Apply an outward impulse to the root bone of the detached chain so it
	# actually flies off instead of just going limp in place.
	var root_bone_name : String = chain[0]
	for pb in _skeleton.find_children("*", "PhysicalBone3D", true, false):
		var pbone := pb as PhysicalBone3D
		if not is_instance_valid(pbone): continue
		# root_bone_name is "mixamorig_X" (see the 2026-08-24 correction on
		# LIMB_BONE_CHAINS above -- confirmed against zombie.tscn's own
		# Skeleton3D bone list, not the stale "mixamorig5_" assumption this
		# comment used to describe). The ragdoll's auto-generated
		# PhysicalBone3D nodes are named "Physical Bone mixamorig_X", so
		# root_bone_name substring-matches them directly with no prefix
		# trimming needed.
		if pbone.name.findn(root_bone_name) >= 0:
			var impulse : Vector3 = hit_dir.normalized() * randf_range(3.5, 5.5) + Vector3.UP * 2.0
			pbone.apply_central_impulse(impulse)
			break

	_detached_limbs[limb_id] = true
	if limb_id == "head":
		# A headshot dismemberment is always lethal, matching player
		# expectation ("shoot the head off" should kill it).
		if health > 0.0: take_damage(health + 1.0, null)

	# The limb is gone -- remove its hitbox so it can't register a second
	# hit on nothing, and stop it colliding with the world oddly.
	if _limb_hitboxes.has(limb_id):
		var hb : Node = _limb_hitboxes[limb_id]
		if is_instance_valid(hb): hb.queue_free()
		_limb_hitboxes.erase(limb_id)

# ============================================================
# AUDIO
# ============================================================

func _setup_audio() -> void:
	# REAL BUG FIX (2026-07-21): a "zombie fx" bus already exists in
	# default_bus_layout.tres, pre-attenuated to -2.9dB specifically so many
	# simultaneous zombies don't blow out the mix -- but these players were
	# never actually routed to it, so every zombie sound went straight to
	# Master at the full +5 to +10dB boost passed at each call site below.
	# With up to 40 zombies now alive at once (ZombieHordeManager.ZONE1_MAX),
	# that's the real cause of "game effects too loud".
	sfx = AudioStreamPlayer3D.new()
	sfx.max_distance = 25.0
	sfx.bus = "zombie fx"
	add_child(sfx)

	sfx_ability = AudioStreamPlayer3D.new()
	sfx_ability.max_distance = 30.0
	sfx_ability.bus = "zombie fx"
	add_child(sfx_ability)

# ============================================================
# ANIMATION TREE
# ============================================================

func _find_anim_tree() -> AnimationTree:

	var t : AnimationTree = get_node_or_null("AnimationTree")

	if t != null:
		return t

	for c in get_children():
		if c is AnimationTree:
			return c

	return null

# ============================================================
# FIND BASES
# ============================================================

func _find_bases() -> void:

	# REAL BUG FIX (2026-08-24): "zombies run to the corner of the map when
	# they spawn, not at base/player". Egg.gd's _spawn_wave() explicitly
	# sets enemy_base = attack_target (HiveNestManager's chosen focus,
	# assigned BEFORE add_child()) with its own comment stating
	# "_find_bases() early-returns without clearing them" -- but this
	# function had NO such guard; it unconditionally nulled and re-derived
	# both bases from a raw "bases" group scan the instant _ready() ran
	# (right after add_child()), silently discarding whatever Egg.gd had
	# just set. If the "bases" group ever has more than the one real
	# enemy-team base in it (or iterates in an order where the intended
	# target isn't last), a hive-spawned zombie's real march target was
	# whatever this scan happened to land on instead -- not necessarily
	# the actual base the player defends. Honor the pre-set values now,
	# matching the contract Egg.gd's own comment already assumed existed.
	# convert_team() (below) explicitly nulls both first when it needs a
	# real re-derivation after flipping team_id, so this doesn't block
	# that legitimate case.
	if is_instance_valid(enemy_base) and is_instance_valid(friendly_base):
		return

	enemy_base = null
	friendly_base = null

	for b in get_tree().get_nodes_in_group("bases"):

		if not is_instance_valid(b):
			continue

		if not ("team_id" in b):
			continue

		if int(b.get("team_id")) == team_id:
			friendly_base = b
		else:
			enemy_base = b

# ============================================================
# AAA: INIT PHASE SYSTEM
# ============================================================

func _init_phase_system() -> void:

	if not is_phase_zombie:
		return

	phase_health_thresholds.clear()

	var segment : float = max_health / float(phase_count)

	for i in range(phase_count):
		phase_health_thresholds.append(
			max_health - segment * float(i + 1)
		)

	phase_current = 0
	phase_transitioning = false

	_build_phase_health_bar()

# ============================================================
# AAA: INIT BOSS SYSTEM
# ============================================================

func _init_boss_system() -> void:

	if not is_boss:
		return

	boss_phase = 0
	boss_enraged = false

	boss_phase_triggered.clear()

	for _i in boss_phase_thresholds.size():
		boss_phase_triggered.append(false)

# ============================================================
# AAA: INIT ELITE SYSTEM
# ============================================================

func _init_elite_system() -> void:

	if not is_elite:
		return

	elite_ability_timer = randf_range(
		elite_ability_cooldown * 0.3,
		elite_ability_cooldown
	)

	if elite_ability == EliteAbility.SHIELD_BURST:
		shield_max = max_health * 0.3
		shield_hp = shield_max
		shield_active = true

	if elite_ability == EliteAbility.LIFE_STEAL:
		life_steal_pct = 0.12

	# Red rim-light identifies this as a priority target; skip if already present
	if get_node_or_null("EliteRimLight") == null:
		var rim := OmniLight3D.new()
		rim.name = "EliteRimLight"
		rim.light_color = Color(1.0, 0.15, 0.1)
		rim.light_energy = 4.0
		rim.omni_range = 3.5
		rim.shadow_enabled = false
		rim.position = Vector3(0.0, 1.5, 0.0)
		add_child(rim)

# ============================================================
# AAA: INIT ARMOR DISPLAY (placeholder hook)
# ============================================================

func _init_armor_display() -> void:
	# Future: spawn floating armor text or icon overlay
	pass

# ============================================================
# PHYSICS
# ============================================================

func _physics_process(delta: float) -> void:

	if is_dead:
		return

	# Player-replication pattern applied to zombies: this node replicates
	# via MultiplayerSpawner (through PurchaseRelay for hive-spawned units,
	# or add_spawnable_scene for lane-pushed ones) and zombie.tscn now has
	# a MultiplayerSynchronizer (position/rotation/velocity/health/is_dead)
	# -- but nothing ever reassigns a zombie's authority away from the
	# default (1/server), unlike Player.tscn, so no bootstrap RPC is
	# needed here the way player.gd required. A non-authoritative peer
	# skips AI/movement entirely and relies purely on the synced state;
	# still runs the visual-only refresh so animation/health bar reflect
	# what just arrived instead of freezing on a client's screen. Note:
	# zombie.gd already has a hand-built, richer snapshot system
	# (get_sync_snapshot/apply_sync_snapshot/sync_snapshot_ready,
	# gated by network_sync_enabled, currently always false) that was
	# never wired to actual networking -- left as a documented
	# opportunity for a future pass rather than adopted here, since the
	# MultiplayerSynchronizer approach is the one already proven working
	# for Player.tscn tonight.
	if NetworkManager.is_networked and not is_multiplayer_authority():
		_update_animation()
		_update_health_bar()
		return

	_update_timers(delta)
	_refresh_structure_ray_exclude(delta)

	_apply_gravity(delta)

	# ---- Phase transition hold ----------------------------

	if phase_transitioning:

		phase_transition_timer -= delta

		velocity.x = move_toward(velocity.x, 0.0, move_speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 8.0 * delta)

		move_and_slide()

		_update_animation()

		_update_health_bar()

		_update_phase_bar()

		_update_energy_icon()

		if phase_transition_timer <= 0.0:

			phase_transitioning = false

			_on_phase_complete()

		return

	# ---- Stun hold ----------------------------------------

	if is_stunned:

		# Tick status effects so freeze/slow timers still expire
		_tick_status_effects(delta)

		velocity.x = move_toward(velocity.x, 0.0, move_speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 8.0 * delta)

		move_and_slide()

		_update_animation()

		_update_health_bar()

		_update_phase_bar()

		_update_energy_icon()

		if debug_overlay_enabled:
			_tick_debug_overlay(delta)

		return

	_brain_tick(delta)

	match lod:
		LOD.FULL:
			_tick_full(delta)
		LOD.CHEAP:
			_tick_cheap(delta)
	_validate_target_reachability(delta)
	_apply_knockback(delta)

	if lod == LOD.FULL:
		# GROUND-CONTACT REWRITE (2026-08-19): this used to call _snap_to_ground()
		# right after move_and_slide() every frame. That's two independent
		# ground systems disagreeing and overwriting each other every tick --
		# move_and_slide()'s own native floor snap (floor_snap_length=0.4,
		# floor_stop_on_slope, floor_max_angle, gated correctly via
		# is_on_floor() in _apply_gravity()) already places the body flush on
		# real ground, consistently, using the same physics the rest of the
		# engine trusts. The raycast/cache teleport in _snap_to_ground() then
		# yanked Y to a slightly different value computed a different way,
		# every single frame -- the actual source of "doesn't look like it's
		# physically touching the ground". Trusting the native system alone
		# (already correctly configured, already collision-safe against the
		# zombie's own Area3D-based ragdoll limbs) is the consistent method.
		move_and_slide()
	else:
		# Cheap LOD: direct integration skips per-zombie zombie-zombie overlap
		# queries from move_and_slide. Separation is handled by the ZHM grid.
		# Reset gravity accumulation since _snap_to_ground positions Y directly.
		velocity.y = 0.0
		global_position.x += velocity.x * delta
		global_position.z += velocity.z * delta
		_snap_to_ground()

	_update_animation()

	# REAL BUG FIX (2026-08-24): "zombies still sink when they attack".
	# _correct_root_bone_y() (added 2026-07-25 for this exact symptom --
	# see its own header comment: "the Mixamo Hips bone Y gets animated by
	# the attack lunge, visually sinking the mesh") was fully implemented
	# but had ZERO call sites anywhere in this file -- the fix was written
	# and never actually wired into the per-frame loop, so it never once
	# ran. Must fire AFTER _update_animation() applies this frame's pose
	# (otherwise there's nothing yet to correct) and every tick, not just
	# during an attack, since the Hips track can carry a nonzero Y offset
	# across the anim blend even outside the lunge window.
	_correct_root_bone_y()

	_update_stuck(delta)

	_update_health_bar()

	_update_phase_bar()

	_update_energy_icon()

	# ---- AAA ticks ----------------------------------------

	_tick_status_effects(delta)

	_tick_elite_ability(delta)

	_tick_boss_checks()

	_tick_swarm(delta)

	_tick_network_sync(delta)

	if debug_overlay_enabled:
		_tick_debug_overlay(delta)
	
# ============================================================
# PROCEDURAL ATTACK LUNGE (2026-07-25) — animation-independent
# ============================================================
## A small, code-driven forward lunge-and-return on the Skeleton3D node's
## own local position -- NOT its bones, so it never fights whatever the
## AnimationTree/attack.res chain is or isn't doing to the skeleton's bone
## poses. Converts the world-space direction to the target into the
## zombie's own local space via the root's basis, so it always lunges
## toward the target regardless of which way this particular rig's mesh
## faces locally -- no guessing about the model's forward axis.
const ATTACK_LUNGE_DIST : float = 0.32
const ATTACK_LUNGE_OUT  : float = 0.10
const ATTACK_LUNGE_BACK : float = 0.22
func _play_procedural_attack_lunge(target_world_pos: Vector3) -> void:
	if not is_instance_valid(_skeleton): return
	var world_dir : Vector3 = target_world_pos - global_position
	world_dir.y = 0.0
	if world_dir.length_squared() > 0.01:
		world_dir = world_dir.normalized()
	else:
		world_dir = Vector3.FORWARD
	var local_dir : Vector3 = global_transform.basis.inverse() * world_dir
	local_dir.y = 0.0
	if local_dir.length_squared() > 0.0001:
		local_dir = local_dir.normalized()
	if _skeleton.has_meta("_lunge_tween"):
		var old_tw : Tween = _skeleton.get_meta("_lunge_tween")
		if is_instance_valid(old_tw): old_tw.kill()
	_skeleton.position = Vector3.ZERO
	var tw := _skeleton.create_tween()
	tw.tween_property(_skeleton, "position", local_dir * ATTACK_LUNGE_DIST, ATTACK_LUNGE_OUT) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_skeleton, "position", Vector3.ZERO, ATTACK_LUNGE_BACK) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_skeleton.set_meta("_lunge_tween", tw)


# ============================================================
# TIMERS
# ============================================================

func _correct_root_bone_y() -> void:
	# REVERTED (2026-07-25): the Skeleton3D-node-level Y zeroing added here
	# last pass (for "floats during run") was speculative -- no confirmed
	# track/property was ever identified, and the user's next report was a
	# NEW, worse symptom specifically "half underground + T-pose when
	# attacking", which lines up with this exact change fighting whatever the
	# attack animation's real motion is. Reverted to just the original,
	# narrower Hips-bone correction below (also see the mixamorig_ vs
	# mixamorig5_ bone-name fix in _ready() -- this correction was silently
	# operating on a fallback bone-0 guess, not a confirmed "Hips" lookup,
	# until that fix).
	# The Mixamo Hips bone Y gets animated by the attack lunge, visually sinking the mesh.
	# Reset the bone's local Y to 0 every frame so only XZ root motion is used.
	if not is_instance_valid(_skeleton) or _hips_bone_idx < 0: return
	var pose : Transform3D = _skeleton.get_bone_pose(_hips_bone_idx)
	if absf(pose.origin.y) > 0.01:
		pose.origin.y = 0.0
		_skeleton.set_bone_pose(_hips_bone_idx, pose)


## Refreshes the set of "solid structure" RIDs (castle/base + turrets) that
## the ground-snap ray should pass THROUGH -- same exclusion principle as
## the ragdoll-bone fix, applied to a second real bug: "shouldn't teleport
## above castle walls or float". The broad 0xFFFF mask (needed project-wide,
## see the regression note below) will happily treat the TOP of a castle
## wall or turret mesh as "ground" if a zombie's XZ position happens to be
## over one -- excluding these specific bodies makes the ray keep looking
## until it finds real walkable terrain underneath/around them instead.
## Turrets get built/destroyed mid-match, so this refreshes periodically
## rather than being cached once forever (bases are static, but cheap
## either way at this interval).
func _refresh_structure_ray_exclude(delta: float) -> void:
	_structure_ray_exclude_timer -= delta
	if _structure_ray_exclude_timer > 0.0:
		return
	_structure_ray_exclude_timer = STRUCTURE_RAY_REFRESH
	# REAL BUG FIX (2026-07-21): the "bases" group tag lives on the castle's
	# ROOT node (basenode.gd's "Base", a plain Node3D), but the actual
	# collision comes from many separate StaticBody3D pieces basenode.gd
	# builds procedurally as children (_build_curtain_walls/_build_corner_towers/
	# _build_rampart_walks/_build_gate_ramps/etc, all via the _cb() helper).
	# Only checking "is the group-tagged node itself a CollisionObject3D"
	# excluded NONE of them -- so the ground ray could hit a real rampart-walk/
	# wall-top collider and snap a zombie up onto the castle roof (confirmed
	# live: "zombies teleporting to top of castle"). Fix: walk descendants too.
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b):
			continue
		_exclude_collision_subtree(b)
	for t in get_tree().get_nodes_in_group("turrets"):
		if not is_instance_valid(t):
			continue
		_exclude_collision_subtree(t)

func _exclude_collision_subtree(node: Node) -> void:
	if node is CollisionObject3D:
		var rid: RID = (node as CollisionObject3D).get_rid()
		if not _ground_ray_exclude.has(rid):
			_ground_ray_exclude.append(rid)
	for child in node.find_children("*", "CollisionObject3D", true, false):
		var co := child as CollisionObject3D
		if is_instance_valid(co):
			var rid: RID = co.get_rid()
			if not _ground_ray_exclude.has(rid):
				_ground_ray_exclude.append(rid)

func _snap_to_ground() -> void:
	# Fast path: read the ZHM shared ground cache built once per 0.25 s by
	# a single per-cell shape cast, avoiding a per-zombie per-frame ray query.
	# REAL BUG FIX (2026-07-24, severe): Engine.has_singleton()/get_singleton()
	# NEVER resolve a GDScript autoload (registered in project.godot's
	# [autoload] section, not a true engine singleton) -- this condition was
	# always false, so EVERY zombie fell through to the per-zombie raycast
	# fallback below on EVERY call, every frame, defeating the entire point
	# of the shared cache (this exact mistake already bit MinimapOverlay.gd
	# and a render-cost overlay earlier this session -- see
	# Lessons/godot-autoload-lookup.md).
	# REAL BUG FIX (2026-07-24, severe): the cache samples ground height once
	# per grid cell AT THE CELL CENTER (ZombieHordeManager._rebuild_ground_cache).
	# On any cell that spans real elevation change (hills, ramps, cliffs near
	# the base), a zombie standing elsewhere in that same cell can get a
	# cached_y wildly different from its true local ground. This code used to
	# `return` unconditionally on any cache hit -- so a zombie that was
	# actually falling (real ground far below/above the cell-center sample)
	# never reached the accurate per-zombie raycast fallback below, and just
	# kept free-falling forever ("zombies keep falling from the sky").
	# Fix: only trust the cache -- and skip the accurate fallback -- when the
	# zombie is already close to the cached height (i.e. genuinely just
	# needs the cheap top-up correction). Anything further off falls through
	# to the real raycast, same as before this cache existed.
	const CACHE_TRUST_MARGIN : float = 2.0
	var _zhm_fast := get_node_or_null("/root/ZombieHordeManager")
	if is_instance_valid(_zhm_fast):
		var zhm : Node = _zhm_fast
		if is_instance_valid(zhm):
			var cached_y : float = zhm.get_ground_y(global_position)
			if cached_y > -999.0 and absf(global_position.y - cached_y) <= CACHE_TRUST_MARGIN:
				# REAL BUG FIX (2026-07-25): "zombies still don't stay on the
				# ground, doing random stuff in the air" -- this only ever
				# corrected UPWARD (sinking below ground). LOD.CHEAP zombies
				# never run move_and_slide() or integrate velocity.y into
				# their Y position at all (see _physics_process) -- this
				# function is their ONLY source of Y correction. Any zombie
				# that ended up floating ABOVE the real ground for any reason
				# (stale cache cell, spawn variance, knockback, LOD demotion
				# with residual height) had nothing to ever pull it back down
				# -- it just hovered there permanently. Correct in both
				# directions whenever meaningfully off, not just from below.
				var target_y : float = cached_y + 0.15
				if absf(global_position.y - target_y) > 0.05:
					global_position.y = target_y
					velocity.y = 0.0
				return

	# Fallback: per-zombie ray (zombie is off-grid or cache not yet populated).
	var space := get_world_3d().direct_space_state
	if not is_instance_valid(space): return
	# Always cast from well above current position — handles already-underground case
	var cast_from := Vector3(global_position.x, global_position.y + 8.0, global_position.z)
	var cast_to   := Vector3(global_position.x, global_position.y - 6.0, global_position.z)
	var ray := PhysicsRayQueryParameters3D.create(cast_from, cast_to)
	# was: ray.exclude = [get_rid()]; ray.collision_mask = 0xFFFF -- the
	# mask itself was fine (0xFFFF reliably hits ANY real ground/prop
	# regardless of whatever collision layer scheme is used across the
	# level); the actual bug was that only the root body was excluded, not
	# the 28 ragdoll bone RIDs (each a separate physics body), so this ray
	# could hit the zombie's OWN torso/head collider before real ground.
	# REGRESSION FIX (2026-07-20): narrowing the mask to "3" broke ground
	# detection anywhere the level uses a different collision layer for
	# terrain/props (this level clearly has many pieces beyond the one
	# floor + Terrain3D2 checked) -- movement glitched everywhere as a
	# result. Keep the broad mask; the RID exclusion is what actually
	# fixes the ragdoll self-collision, unambiguously, without guessing at
	# the "right" layer.
	# SECOND BUG FIX (2026-07-20): base/castle + turret RIDs are ALSO
	# excluded now (see _refresh_structure_ray_exclude()) so the ray finds
	# real terrain instead of a wall-top or turret roof.
	ray.exclude = _ground_ray_exclude
	ray.collision_mask = 0xFFFF
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		var ground_y : float = hit.position.y
		# REAL BUG FIX (2026-07-25): same asymmetry as the cache path above --
		# correct downward too, not just up out of the ground.
		var target_ground_y : float = ground_y + 0.15
		if absf(global_position.y - target_ground_y) > 0.05:
			global_position.y = target_ground_y
			velocity.y = 0.0

## Real speed modulation driven by the brain's own recent firing (see
## _brain_tick()) instead of a flat move_speed constant.
func _current_speed_mult() -> float:
	var mult := 1.0
	if _aggro_timer > 0.0:
		mult *= AGGRO_BURST_MULT
	if _caution_timer > 0.0:
		mult *= CAUTION_DAMP_MULT
	return mult

## The Spikeling brain tick: stimulates Aggro/Caution from the ACTUAL
## closing/losing-ground rate against the current target this frame, giving
## a real, temporary speed burst/damp instead of a flat constant.
func _brain_tick(delta: float) -> void:
	_aggro_timer = maxf(0.0, _aggro_timer - delta)
	_caution_timer = maxf(0.0, _caution_timer - delta)
	if not is_instance_valid(target):
		_prev_target_dist = -1.0
		return
	var dist: float = global_position.distance_to((target as Node3D).global_position)
	if _prev_target_dist >= 0.0:
		var closing_rate: float = (_prev_target_dist - dist) / maxf(delta, 0.001)
		# BOSS VARIANT REACTIVITY (2026-08-28): a real, distinct stimulus
		# pattern per archetype -- not the same Aggro/Caution mapping for
		# every boss. See set_boss_variant()'s stat-side comments for the
		# matching archetype description.
		if is_boss and boss_variant == BossVariant.MAW:
			# caster: closing distance makes it CAUTIOUS (wants range),
			# not aggressive -- the opposite mapping from every other
			# variant, a real behavioral difference driven by the SNN,
			# not a cosmetic label.
			if closing_rate > 0.0:
				brain.stimulate("Caution", closing_rate * CLOSING_STIMULUS_SCALE)
			elif closing_rate < 0.0:
				brain.stimulate("Aggro", -closing_rate * CLOSING_STIMULUS_SCALE * 0.5)
		elif is_boss and boss_variant == BossVariant.MUSHROOM:
			# area-effect creature: never goes Cautious -- always presses
			# in regardless of losing ground, real Caution suppression
			# (stimulus simply never sent for this variant)
			if closing_rate > 0.0:
				brain.stimulate("Aggro", closing_rate * CLOSING_STIMULUS_SCALE)
		else:
			if closing_rate > 0.0:
				brain.stimulate("Aggro", closing_rate * CLOSING_STIMULUS_SCALE)
			elif closing_rate < 0.0:
				brain.stimulate("Caution", -closing_rate * CLOSING_STIMULUS_SCALE)
	_prev_target_dist = dist

	# REAL FEATURE: player-team units only (deck-purchased creeps) -- Alert
	# from ambient enemy-unit COUNT nearby, not just the current target, so
	# a defend creep gets keyed-up from being surrounded before it's even
	# picked a target. Gated on team_id so enemy zombies (team 2) never
	# stimulate this neuron at all -- see the brain-load comment above.
	if team_id == 1:
		var nearby_threats : int = 0
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or u == self or not (u is Node3D): continue
			if "team_id" in u and int(u.get("team_id")) == team_id: continue
			if "is_dead" in u and u.get("is_dead"): continue
			if global_position.distance_to((u as Node3D).global_position) <= ALLY_ALERT_RADIUS:
				nearby_threats += 1
		if nearby_threats > 0:
			brain.stimulate("Alert", nearby_threats * ALLY_ALERT_STIMULUS_PER_THREAT)

	var fired: Array = brain.step()
	if "Aggro" in fired:
		_aggro_timer = BRAIN_EFFECT_DURATION
	if "Caution" in fired:
		_caution_timer = BRAIN_EFFECT_DURATION


func _update_timers(delta: float) -> void:

	attack_timer       = maxf(0.0, attack_timer       - delta)
	_attack_anim_timer = maxf(0.0, _attack_anim_timer - delta)

	if _forced_target_timer > 0.0:
		_forced_target_timer = maxf(0.0, _forced_target_timer - delta)
		if _forced_target_timer <= 0.0 or not is_instance_valid(_forced_target):
			_forced_target = null

	retarget_timer -= delta

	energized_timer -= delta
	if energized_timer < 0.0: energized_timer = 0.0; energized_stacks = 0
	# Tick unreachable blacklist — only if non-empty
	if not _unreachable_blacklist.is_empty():
		for iid in _unreachable_blacklist.keys():
			_unreachable_blacklist[iid] -= delta
			if _unreachable_blacklist[iid] <= 0.0:
				_unreachable_blacklist.erase(iid)
	elite_ability_timer -= delta; if elite_ability_timer < 0.0: elite_ability_timer = 0.0
	swarm_pheromone_timer -= delta; if swarm_pheromone_timer < 0.0: swarm_pheromone_timer = 0.0
	net_sync_timer -= delta; if net_sync_timer < 0.0: net_sync_timer = 0.0

	# Squad command: non-persistent orders expire after 1s
	if squad_order != SquadOrder.NONE and not squad_persistent and not order_persistent:
		squad_timer += delta
		if squad_timer >= 1.0:
			squad_order      = SquadOrder.NONE
			squad_target     = null
			squad_persistent = false
			squad_timer      = 0.0
			ai_mode          = AIMode.LANE_PUSH

# ============================================================
# GRAVITY
# ============================================================

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
	# REAL BUG FIX (2026-08-24): "zombies sink underground after attack
	# animation" -- this used to gate on `attack_timer` (the full attack_cooldown,
	# 2.6s), not `_attack_anim_timer` (the actual swing-animation window, 0.7s --
	# see _try_attack()). attack_timer stays > 0 for nearly the WHOLE cooldown in
	# sustained melee combat, so gravity's downward accumulation (line above) was
	# being erased back to >=0 on almost every physics frame a zombie was in
	# combat, not just during the 0.7s swing. Confirmed via a real headless
	# behavioral test (temporary _smoke_sink_test.gd): forced repeated attacks on
	# a stationary target on real ground -- the instant the zombie picked up ANY
	# upward/edge-triggered Y velocity while attack_timer was still counting down
	# (e.g. a slope/ledge transition, a knockback, an elite Leap impulse),
	# is_on_floor() went false and Y got PERMANENTLY stuck at that wrong height
	# for the rest of the cooldown -- gravity could never pull it back down,
	# because this clamp re-floored velocity.y to >=0 every single frame
	# regardless of how far off real ground the body actually was. Same
	# mechanism explains an under-ground stall too: whichever direction the body
	# was perturbed the instant attack_timer was nonzero, it could never
	# recover via gravity until the full ~2.6s cooldown ran out. Using the much
	# narrower _attack_anim_timer (0.7s, matches the real swing duration this
	# was clearly meant to protect) keeps the original intent -- no visible
	# falling motion mid-swing -- without leaving gravity disabled for the
	# ~1.9s dead window after every hit.
	if _attack_anim_timer > 0.0:
		velocity.y = maxf(velocity.y, 0.0)

# ============================================================
# KNOCKBACK (2026-07-20) — "make sure zombies react to getting shot and
# pushed back". A real, decaying velocity impulse, set in take_damage()
# and blended in here every physics tick on top of whatever the AI's own
# steering computed -- so a hit zombie visibly staggers back for a beat
# instead of the incoming damage having zero physical effect.
# ============================================================

var _knockback_velocity : Vector3 = Vector3.ZERO
var _knockback_timer     : float  = 0.0
const KNOCKBACK_DURATION : float  = 0.3

func _apply_knockback(delta: float) -> void:
	if _knockback_timer <= 0.0:
		return
	_knockback_timer = maxf(0.0, _knockback_timer - delta)
	var decay : float = _knockback_timer / KNOCKBACK_DURATION   # 1.0 -> 0.0 over the window
	velocity.x += _knockback_velocity.x * decay
	velocity.z += _knockback_velocity.z * decay

# ============================================================
# FULL AI
# ============================================================

func _tick_full(delta: float) -> void:

	if elite_ghost_timer > 0.0:
		elite_ghost_timer -= delta

	# Player-issued squad commands bypass lane AI entirely
	if squad_order != SquadOrder.NONE:
		match ai_mode:
			AIMode.ATTACK:  _tick_attack(delta)
			AIMode.DEFEND:  _tick_defend(delta)
			AIMode.STAY:    _tick_stay(delta)
			AIMode.FOLLOW_OWNER: _tick_follow(delta)
			AIMode.PATROL:  _tick_patrol(delta)
			_: _tick_lane_march(delta)
		return

	# ── TD / MOBA lane-march model ─────────────────────────
	# Always march to the enemy base.
	# Only attack enemies that are directly blocking the path
	# (within melee range in front of the zombie).
	# Never deviate from the lane to hunt distant targets.
	# ──────────────────────────────────────────────────────
	ai_mode = AIMode.LANE_PUSH
	_tick_lane_march(delta)

# ============================================================
# CHEAP AI
# ============================================================

func _tick_cheap(delta: float) -> void:
	# Cheap LOD: always march to base, no combat scanning
	if not is_instance_valid(enemy_base):
		return

	# REAL BUG FIX (2026-08-06): "mass zombies spawn at enemy base and don't
	# attack until triggered" / "zombies aren't focusing turrets, they go
	# straight for base" -- _try_attack() was never called anywhere in this
	# function, and _get_march_destination() only ever routes through gates
	# to the base, never a turret (turret-awareness lives entirely in
	# _find_blocker(), which only FULL AI calls). A zombie beyond LOD0_DIST
	# (40m — see ZombieHordeManager.gd) from the camera the whole approach
	# — true for almost any nest-spawned zombie until the player is
	# physically standing near it — walked straight past every turret with
	# zero awareness of them, then sat at the base forever, unable to deal
	# any damage, until the player's camera came within 40m and promoted it
	# to FULL AI. Give cheap tier ONE deliberately-cheap check instead of a
	# real _find_blocker() scan: reuse the pre-cached _turrets_cache (no
	# group scan) to see if a living enemy turret is already in melee range;
	# if so, fight it in place. This is O(cached turret count) per zombie
	# per frame, not the full combat-threat-range scan _find_best_target()
	# does, so it stays cheap.
	for t in _turrets_cache:
		if not is_instance_valid(t) or not (t is Node3D): continue
		if "team_id" in t and int(t.get("team_id")) == team_id: continue
		if "health" in t and float(t.get("health")) <= 0.0: continue
		if global_position.distance_to((t as Node3D).global_position) <= turret_range:
			target = t as Node3D
			target_type = "turret"
			_try_attack(t as Node3D)
			return

	var dest : Vector3 = _get_march_destination()
	_move_toward(dest, move_speed * 0.85 * (1.0 - current_slow), delta)

	# Already at the base (not just routing through a gate) and in range —
	# attack it instead of standing there inert.
	if dest == enemy_base.global_position and global_position.distance_to(dest) <= base_range:
		target = enemy_base
		target_type = "base"
		_try_attack(enemy_base)

# ============================================================
# TARGETING (2026-08-24 rebuild: unified into TargetPriority.gd -- see
# _select_target() below, called by both the default lane-march path and
# every squad-order AI mode. Replaces this function and _find_blocker(),
# which independently duplicated the same priority logic with different,
# inconsistently-tuned range/scoring rules.)
# ============================================================

## REAL BUG FIX (2026-08-24): tank.gd's Taunt ability sets an enemy's target
## to the tank via the raw `u.set("target", self)` fallback (no
## "set_forced_target" method existed anywhere on this script, so
## has_method() always skipped the intended API and fell through) -- that
## raw assignment got silently overwritten by this function's own next
## periodic scan (every ~0.18-0.4s), so Taunt's stated 3.5s duration lasted
## well under half a second in practice against any real zombie-type
## target. A real forced-target override, checked first and bypassing the
## normal priority scan entirely for its duration, makes Taunt actually
## work as long as it's supposed to.
var _forced_target       : Node3D = null
var _forced_target_timer : float  = 0.0
func set_forced_target(node: Node3D, duration: float) -> void:
	_forced_target       = node
	_forced_target_timer = duration

func _select_target(require_cone: bool, forward_dir: Vector3, engage_range: float) -> void:
	if is_instance_valid(_forced_target) and _forced_target_timer > 0.0:
		target      = _forced_target
		target_type = "unit"
		if squad_order == SquadOrder.NONE:
			ai_mode = AIMode.ATTACK
		return

	var picked : Dictionary = TargetPriority.select(
		self, team_id, is_boss, aggro_range, engage_range,
		require_cone, forward_dir, BLOCKER_CONE_DOT,
		true, Callable(self, "_has_line_of_sight"),
		(_players_cache if not _players_cache.is_empty() else get_tree().get_nodes_in_group("players")),
		neighbors_cache,
		(_turrets_cache if not _turrets_cache.is_empty() else get_tree().get_nodes_in_group("turrets")),
		_unreachable_blacklist,
		enemy_base
	)
	target = picked.target
	target_type = picked.target_type

	# Never let targeting override a player-issued command's ai_mode
	if squad_order != SquadOrder.NONE:
		return
	if is_instance_valid(target):
		ai_mode = AIMode.LANE_PUSH if target_type == "base" else AIMode.ATTACK
	else:
		ai_mode = AIMode.LANE_PUSH

## Same BLOCKER_RANGE/BLOCKER_RANGE_EXIT hysteresis _tick_lane_march uses for
## _march_engaged, applied to the squad-order paths (_tick_attack/_defend/
## _follow) via the existing target/target_type state instead of a separate
## tracked bool -- "already engaged with a unit within the wider exit
## threshold" reuses the exit range this scan too, so squad-ordered zombies
## get the same 2026-07-25 anti-jitter fix the default march path already had.
func _unit_engage_range() -> float:
	if is_instance_valid(target) and target_type == "unit" \
			and global_position.distance_to(target.global_position) <= BLOCKER_RANGE_EXIT:
		return BLOCKER_RANGE_EXIT
	return BLOCKER_RANGE

# ============================================================
# LANE MARCH — TD/MOBA model (always march, only attack blockers)
# ============================================================
# Behaviour model: League of Legends minion / Plants vs Zombies zombie.
#   1. Navigate toward enemy_base at all times.
#   2. Check for enemies within BLOCKER_RANGE directly ahead.
#   3. If a blocker is found: stop, face it, swing once per cooldown.
#   4. Once blocker is dead / out of range: immediately resume march.
#   Never set target to a distant unit; never enter AIMode.ATTACK.
# ============================================================

const BLOCKER_RANGE      : float = 2.8   # max distance to engage a blocker
const BLOCKER_CONE_DOT   : float = 0.2   # cos(78°) — wide forward cone check
const MARCH_SCAN_INTERVAL: float = 0.18  # seconds between blocker scans
var   _march_scan_timer  : float = 0.0
var   _march_blocker     : Node3D = null  # current blocking enemy (nil = march)

# REAL BUG FIX (2026-07-25): fpsboost.gd's CPU throttle presets have always
# called z.set_ai_tick_offset(...) on every zombie, expecting it to spread
# the per-zombie blocker rescan (the single most expensive recurring part of
# zombie AI -- group/cache scans in _find_blocker) across frames so not
# every zombie recalculates in the same tick. That method never existed on
# this script, so `has_method()` silently skipped it and every FPS preset's
# CPU-side throttle was a complete no-op the whole time, regardless of
# preset. Implement it for real: stagger this zombie's scan-timer phase so
# zombies with different offsets scan on different frames instead of all
# lining up together.
var _ai_tick_offset : int = 0
func set_ai_tick_offset(offset: int) -> void:
	_ai_tick_offset = maxi(offset, 0)
	_march_scan_timer = fmod(float(_ai_tick_offset) * (MARCH_SCAN_INTERVAL / 4.0), MARCH_SCAN_INTERVAL)
# REAL BUG FIX (2026-07-25): "zombies jitter/shake back and forth when
# surrounding a target" -- entering AND leaving melee-attack mode used the
# same BLOCKER_RANGE threshold. With several zombies packed around one
# target, each one's own separation force (from _get_separation_force, only
# applied while actively moving) nudges it back and forth across that exact
# boundary frame to frame -- stop-to-attack, get jostled out past the
# threshold, resume moving (re-applying separation), get pushed back in,
# stop again -- a fast, visible shake. Use a wider exit threshold than the
# entry threshold (hysteresis) so being right at the edge doesn't flip state
# every frame.
var   _march_engaged     : bool = false
const BLOCKER_RANGE_EXIT : float = BLOCKER_RANGE * 1.6

## REAL BUG FIX (2026-07-25): "zombies never actually clear turrets before
## the (invincible-while-any-turret-lives) base" -- _find_blocker() correctly
## picks the nearest living turret with NO range cap when no closer player/
## unit exists (turrets are static, you're supposed to walk to them). But
## this "gone" check used the same tight ~5-unit melee threshold for every
## blocker type, so a turret picked from beyond that range was invalidated
## again the very next frame -- before the zombie ever got a chance to move
## toward it -- and it reverted straight back to beelining past every turret
## for the base. Turrets get a much wider "still relevant" leash since the
## zombie is meant to be closing that exact distance.
const TURRET_CHASE_GONE_RANGE : float = 250.0
func _tick_lane_march(delta: float) -> void:
	# ── 1. Validate existing blocker ──────────────────────
	if is_instance_valid(_march_blocker):
		var dead : bool = "is_dead" in _march_blocker and _march_blocker.get("is_dead") is bool and bool(_march_blocker.get("is_dead"))
		var gone_range : float = TURRET_CHASE_GONE_RANGE if _march_blocker.is_in_group("turrets") else BLOCKER_RANGE * 1.8
		var gone : bool = global_position.distance_to(_march_blocker.global_position) > gone_range
		if dead or gone:
			_march_blocker = null
			_march_engaged = false

	# ── 2. Periodic scan (unified TargetPriority: players > units > turrets
	# > base). target_type=="base" is never stored as a _march_blocker (the
	# base must route through _get_march_destination()'s gate-awareness, not
	# beeline into a castle wall like a melee blocker would) -- it's read
	# directly from `target`/`target_type` in step 4 instead.
	_march_scan_timer -= delta
	if _march_scan_timer <= 0.0:
		_march_scan_timer = MARCH_SCAN_INTERVAL
		var march_dir : Vector3 = Vector3.ZERO
		if is_instance_valid(enemy_base):
			march_dir = (enemy_base.global_position - global_position)
			march_dir.y = 0.0
			if march_dir.length_squared() > 0.01: march_dir = march_dir.normalized()
		var engage_range : float = BLOCKER_RANGE_EXIT if _march_engaged else BLOCKER_RANGE
		_select_target(true, march_dir, engage_range)
		var picked : Node3D = target if target_type != "base" else null
		if picked != _march_blocker: _march_engaged = false
		_march_blocker = picked

	# ── 3. If blocked: approach, then stop and attack ─────
	# REAL BUG FIX (2026-07-25): this used to stop-and-attack immediately
	# regardless of actual distance to the blocker -- harmless for players/
	# units (already selected within melee range) but silently broken for
	# turrets (selected from any range): the zombie would freeze in place,
	# fail to land a hit (well outside real attack range), and never
	# actually walk over. Only stop+attack once truly close; otherwise walk
	# to the blocker like any other march destination.
	if is_instance_valid(_march_blocker):
		var _blocker_dist : float = global_position.distance_to(_march_blocker.global_position)
		if _march_engaged:
			_march_engaged = _blocker_dist <= BLOCKER_RANGE_EXIT
		else:
			_march_engaged = _blocker_dist <= BLOCKER_RANGE
		if _march_engaged:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * 12.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * 12.0 * delta)
			_face_target(_march_blocker.global_position)
			# target_type is already set correctly by _select_target() above
			# (was a manual is_in_group() re-derivation before the rebuild --
			# see the 2026-07-25 "turrets not taking damage" fix this used to
			# be needed for; TargetPriority.select() sets it directly now).
			_try_attack(_march_blocker)
		else:
			var chase_speed : float = move_speed * enrage_speed_mult * director_speed_mult * (1.0 - current_slow)
			_move_toward(_march_blocker.global_position, chase_speed, delta)
		return

	# ── 4. No blocker: attack the base if in range and reachable
	# (REAL BUG FIX, 2026-08-24 rebuild: this path previously had NO way to
	# ever attack the base at all once every turret was destroyed -- only
	# LOD.CHEAP's separate simplified logic could. A FULL-LOD marching
	# zombie just stood at the base forever, doing nothing.), otherwise
	# march toward it (gate-routed).
	if not is_instance_valid(enemy_base):
		return
	if target_type == "base" and is_instance_valid(target):
		var base_dist : float = global_position.distance_to(enemy_base.global_position)
		if base_dist <= _get_attack_range():
			velocity.x = move_toward(velocity.x, 0.0, move_speed * 10.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * 10.0 * delta)
			_face_target(enemy_base.global_position)
			_try_attack(enemy_base)
			return
	var dest : Vector3 = _get_march_destination()
	var effective_speed : float = move_speed * enrage_speed_mult * director_speed_mult * (1.0 - current_slow)
	_move_toward(dest, effective_speed, delta)


## REAL FIX (2026-07-25): the procedurally-generated castle (scripts/basenode.gd
## _spawn_castle()) fully encloses each base in curtain walls with exactly ONE
## gate opening per wall side — but zombies always marched in a straight line
## at enemy_base.global_position (the castle's center). Any egg/nest not
## perfectly aligned with one of the 4 gates sent zombies straight into a
## solid wall face, where _deflect_around_wall's generic sliding isn't enough
## to guarantee finding the actual opening (it can slide the wrong way around
## a corner tower and never arrive). basenode.gd already drops an Area3D
## marker per gate in group "castle_gate" (currently otherwise unused) —
## route through the nearest one belonging to THIS base before beelining for
## the base itself, so the march always resolves to a real opening instead of
## a wall.
const GATE_OWN_RADIUS      : float = 20.0   # a gate within this range of enemy_base belongs to its castle
const GATE_ROUTE_SWITCH_DIST : float = 26.0 # once this close to the base, just go straight in (already past the walls)
const GATE_ARRIVAL_DIST    : float = 4.0    # close enough to a gate to stop routing through it
func _get_march_destination() -> Vector3:
	var base_pos : Vector3 = enemy_base.global_position
	if global_position.distance_to(base_pos) < GATE_ROUTE_SWITCH_DIST:
		return base_pos
	var nearest_gate : Node3D = null
	var nearest_d : float = INF
	for g in get_tree().get_nodes_in_group("castle_gate"):
		if not is_instance_valid(g) or not (g is Node3D): continue
		var gate_pos : Vector3 = (g as Node3D).global_position
		if gate_pos.distance_to(base_pos) > GATE_OWN_RADIUS: continue   # belongs to a different castle
		var d : float = global_position.distance_to(gate_pos)
		if d < nearest_d:
			nearest_d = d
			nearest_gate = g as Node3D
	if not is_instance_valid(nearest_gate):
		return base_pos   # no gates found (e.g. castle not built yet) — fall back to old behavior
	if nearest_d < GATE_ARRIVAL_DIST:
		return base_pos   # already at/through the gate — head for the base directly
	return nearest_gate.global_position


## REAL BUG FIX (2026-07-24): "zombies attack through walls" -- _find_blocker()
## picked the nearest player/unit within BLOCKER_RANGE and a forward cone, with
## no check for anything actually IN BETWEEN. A zombie standing on the far
## side of a thin wall/gate/fence from the player, within the short 2.8-unit
## BLOCKER_RANGE, became a valid "blocker" and attacked straight through the
## wall. Real fix: a physics raycast at chest height between zombie and
## candidate -- any hit before reaching the target (that isn't the target
## itself) means something solid is in the way, so it's rejected as a blocker.
const LOS_HEIGHT : float = 1.2
func _has_line_of_sight(target: Node3D) -> bool:
	if not is_inside_tree(): return true
	var space := get_world_3d().direct_space_state
	if not is_instance_valid(space): return true
	var from : Vector3 = global_position + Vector3(0.0, LOS_HEIGHT, 0.0)
	var to   : Vector3 = target.global_position + Vector3(0.0, LOS_HEIGHT, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFF
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty(): return true
	var collider : Object = hit.get("collider")
	# Hitting the target itself (its own hurtbox/body) still counts as clear LOS.
	return collider == target or (collider is Node and (collider as Node).is_ancestor_of(target)) \
		or (target is Node and (target as Node).is_ancestor_of(collider as Node) if collider is Node else false)


# ============================================================
# LANE PUSH (legacy — kept for squad-ordered ATTACK mode)
# ============================================================

func _tick_lane_push(delta: float) -> void:

	if is_instance_valid(target):

		var dist : float = global_position.distance_to(target.global_position)

		var range : float = _get_attack_range()

		if dist <= range:

			velocity.x = move_toward(
				velocity.x,
				0.0,
				move_speed * 10.0 * delta
			)

			velocity.z = move_toward(
				velocity.z,
				0.0,
				move_speed * 10.0 * delta
			)

			_face_target(target.global_position)

			_try_attack(target)

			return

		var effective_speed : float = move_speed * enrage_speed_mult * director_speed_mult * (
			1.0 - current_slow
		)

		_move_toward(
			target.global_position,
			effective_speed,
			delta
		)

		return
func _validate_target_reachability(delta: float) -> void:

	if not is_instance_valid(target):
		unreachable_timer = 0.0; last_target_distance = INF; return

	if target_type == "base":
		return

	var dist : float = global_position.distance_to(target.global_position)

	# Already in range — reset
	if dist <= _get_attack_range() + 0.5:
		unreachable_timer = 0.0
		target_progress_timer = 0.0
		last_target_distance = dist
		return

	# Initialize baseline on first call
	if last_target_distance == INF:
		last_target_distance = dist
		return

	target_progress_timer += delta
	if target_progress_timer < 0.5:
		return
	target_progress_timer = 0.0

	var progress : float = last_target_distance - dist
	last_target_distance = dist

	if progress < min_progress_distance:
		unreachable_timer += 0.5
	else:
		unreachable_timer = maxf(0.0, unreachable_timer - 0.25)

	if unreachable_timer >= unreachable_timeout:
		_clear_unreachable_target()

# ============================================================
# ATTACK
# ============================================================

func _tick_attack(delta: float) -> void:
	# Find and attack nearest enemy; hold position if none found
	_retarget_timer -= delta
	if is_instance_valid(target) and target_type != "base" and target_type != "player" \
			and _retarget_timer > 0.0:
		_tick_lane_push(delta)
		return
	_retarget_timer = RETARGET_INTERVAL
	_select_target(false, Vector3.ZERO, _unit_engage_range())
	if is_instance_valid(target):
		_tick_lane_push(delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)

# ============================================================
# DEFEND
# ============================================================

func _tick_defend(delta: float) -> void:
	# Attack nearby enemies first, then fall back to base if none
	if is_instance_valid(target) and _target_in_defend_range():
		_tick_lane_push(delta)
		return
	_select_target(false, Vector3.ZERO, _unit_engage_range())
	if is_instance_valid(target) and _target_in_defend_range():
		_tick_lane_push(delta)
		return
	# No enemies nearby — move to friendly base
	target = null
	if not is_instance_valid(friendly_base): return
	var d : float = global_position.distance_to(friendly_base.global_position)
	if d > 6.0:
		_move_toward(friendly_base.global_position, move_speed, delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)


func _target_in_defend_range() -> bool:
	if not is_instance_valid(target): return false
	var anchor : Vector3 = friendly_base.global_position if is_instance_valid(friendly_base) else global_position
	return target.global_position.distance_to(anchor) <= 20.0

# ============================================================
# STAY
# ============================================================

func _tick_stay(delta: float) -> void:

	velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)


func _tick_follow(delta: float) -> void:
	# Follow squad_target — also attack enemies that are close to the player
	var follow_target : Node3D = squad_target if is_instance_valid(squad_target) else null
	if not is_instance_valid(follow_target):
		velocity.x = 0.0; velocity.z = 0.0; return
	# Attack nearby enemies (within 12m of the player) before following
	if is_instance_valid(target):
		var tgt_near : bool = is_instance_valid(follow_target) and 			target.global_position.distance_to(follow_target.global_position) <= 12.0
		if tgt_near:
			_tick_lane_push(delta)
			return
		target = null
	# Scan for enemies near the player
	_select_target(false, Vector3.ZERO, _unit_engage_range())
	if is_instance_valid(target):
		var near : bool = target.global_position.distance_to(follow_target.global_position) <= 12.0
		if near:
			_tick_lane_push(delta)
			return
		target = null
	# No threat — stay close to player
	var d : float = global_position.distance_to(follow_target.global_position)
	if d <= 2.5:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 6.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 6.0 * delta)
	else:
		_move_toward(follow_target.global_position, move_speed, delta)


func _tick_patrol(delta: float) -> void:
	if not "patrol_points" in self or patrol_points.is_empty():
		velocity.x = 0.0; velocity.z = 0.0; return
	var dest : Vector3 = patrol_points[_patrol_idx]
	if global_position.distance_to(dest) < 1.5:
		_patrol_idx += _patrol_dir
		if _patrol_idx >= patrol_points.size(): _patrol_idx = patrol_points.size()-2; _patrol_dir = -1
		elif _patrol_idx < 0: _patrol_idx = 1; _patrol_dir = 1
		_patrol_idx = clampi(_patrol_idx, 0, patrol_points.size()-1)
	else:
		_move_toward(dest, move_speed, delta)


# ============================================================
# MOVE
# ============================================================

func _move_toward(
	pos: Vector3,
	speed: float,
	delta: float
) -> void:
	# MOVEMENT REWORK (2026-07-20): deterministic direct steering, always --
	# no more branching between NavigationAgent path direction and direct
	# steering (that flicker, on a level without a reliably-baked NavMesh
	# everywhere, was a real, confirmed source of the reported "glitch
	# around and bounce"). Speed is now modulated by the Spikeling brain
	# (_brain_tick()/_current_speed_mult()) instead of a flat constant.
	var dir : Vector3 = pos - global_position
	dir.y = 0.0
	if dir.length_squared() <= 0.001: return
	dir = dir.normalized()
	dir = _deflect_around_wall(dir)

	dir += _get_separation_force()
	if dir.length_squared() <= 0.001: return
	dir = dir.normalized()

	_smooth_speed_mult = lerp(_smooth_speed_mult, _current_speed_mult(), delta * 8.0)
	var real_speed: float = speed * _smooth_speed_mult
	velocity.x = lerp(velocity.x, dir.x * real_speed, 0.28)
	velocity.z = lerp(velocity.z, dir.z * real_speed, 0.28)
	# Never set downward velocity from path — gravity and snap handle Y
	velocity.y = minf(velocity.y, 0.0)

	rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.25)

# ============================================================
# WALL AVOIDANCE
# ============================================================

## REAL FIX (2026-07-25): straight-line _move_toward had zero look-ahead, so
## a zombie walking toward its destination through a wall just pushed
## straight into it — the only recovery was the random-direction _unstuck()
## nudge after 1.5s of no progress, which visibly reads as "stuck at walls"
## (and can repeat if the random nudge happens to point back into the same
## wall). Cast a short ray along the intended direction; if it hits static
## geometry (a wall, not a living target — those are handled by
## _find_blocker/attack range instead), deflect to slide along the wall's
## surface instead of walking straight into it.
const WALL_PROBE_DIST : float = 1.4
func _deflect_around_wall(dir: Vector3) -> Vector3:
	if not is_inside_tree(): return dir
	var space := get_world_3d().direct_space_state
	if not is_instance_valid(space): return dir
	var from : Vector3 = global_position + Vector3(0.0, LOS_HEIGHT, 0.0)
	var to   : Vector3 = from + dir * WALL_PROBE_DIST
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFF
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty(): return dir
	var collider : Object = hit.get("collider")
	if not (collider is StaticBody3D): return dir   # only deflect for static geometry — living targets are handled elsewhere
	var normal : Vector3 = hit.get("normal")
	normal.y = 0.0
	if normal.length_squared() <= 0.001: return dir
	normal = normal.normalized()
	# Slide along the wall: remove the into-wall component, keep the tangent.
	var slid : Vector3 = dir - normal * dir.dot(normal)
	if slid.length_squared() <= 0.001:
		slid = Vector3(-normal.z, 0.0, normal.x)   # dead-on hit — pick a tangent
	return slid.normalized()


# ============================================================
# SEPARATION
# ============================================================

func _get_separation_force() -> Vector3:

	var force : Vector3 = Vector3.ZERO
	var count : int = 0

	for n in neighbors_cache:

		if count >= 4:
			break

		if not is_instance_valid(n):
			continue

		if n == self:
			continue

		var diff : Vector3 = global_position - n.global_position

		diff.y = 0.0

		var dist : float = diff.length()

		if dist <= 0.01:
			continue

		if dist > 1.4:
			continue

		force += diff.normalized() * (1.0 - (dist / 1.4)) * 0.5

		count += 1

	if force.length_squared() > 0.01:
		# Cap separation so it never overpowers the move-toward direction
		force = force.normalized() * minf(force.length(), 0.18)

	return force

# ============================================================
# FACE
# ============================================================

func _face_target(pos: Vector3) -> void:

	var dir : Vector3 = pos - global_position

	dir.y = 0.0

	if dir.length_squared() <= 0.01:
		return

	rotation.y = lerp_angle(
		rotation.y,
		atan2(dir.x, dir.z),
		0.25
	)

# ============================================================
# RANGE
# ============================================================

func _get_attack_range() -> float:

	match target_type:
		"turret":
			return turret_range
		"base":
			return base_range
		_:
			return attack_range

# ============================================================
# ATTACK
# ============================================================

func _try_attack(t: Node3D) -> void:

	if attack_timer > 0.0:
		return

	if not is_instance_valid(t):
		return

	if "team_id" in t:
		if int(t.get("team_id")) == team_id:
			return

	attack_timer       = attack_cooldown
	# REAL BUG FIX (2026-08-24 rebuild): this used to be a hardcoded 0.7 --
	# written back when attack.res was a silent no-op (mixamorig5_ bone-name
	# mismatch, fixed earlier the same day) so nobody could have measured
	# the REAL clip length. The actual attack.res animation is ~2.63s long.
	# For the ~1.9s after the old 0.7s window expired but the swing was
	# still visibly playing, _apply_gravity()'s suppression (below) was
	# unprotected -- if is_on_floor() flipped false at all mid-swing (a
	# knockback landing, a slope, an elite impulse), the body fell/sank
	# uncontested for the rest of the visible attack. _attack_anim_len is
	# now derived from the real clip in _ready(), clamped to attack_cooldown.
	_attack_anim_timer = _attack_anim_len

	_play_sound(attack_sounds, 5.0, "zombie_attack")

	if anim_tree != null and anim_tree.active:
		var _fired_attack_anim : bool = false
		for ap in ["parameters/attack_shot/request",
				   "parameters/Attack/request",
				   "parameters/attack/request",
				   "parameters/hit/request"]:
			if anim_tree.get(ap) != null:
				anim_tree.set(ap, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
				_fired_attack_anim = true
				break
		# DIAGNOSTIC (2026-07-25): "still no attack animation" -- the graph in
		# zombie.tscn (attack_shot -> attack -> animations/attack) checks out
		# correctly by static inspection, so if this ever fires for a live
		# instance, the actual creep variant's scene doesn't have a matching
		# OneShot node under any of the 4 guessed names -- print once so
		# it's visible in-game which variant/scene is missing it, instead of
		# silently doing nothing.
		if not _fired_attack_anim and not _warned_no_attack_anim:
			_warned_no_attack_anim = true
			push_warning("[Zombie] '%s' has an active AnimationTree but no attack_shot/Attack/attack/hit request parameter -- attack animation cannot play. Scene: %s" % [name, scene_file_path])
	var _ap2 := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if is_instance_valid(_ap2) and anim_tree == null:
		if _ap2.has_animation("Attack"): _ap2.play("Attack")
		elif _ap2.has_animation("attack"): _ap2.play("attack")

	# REAL FIX (2026-07-25): "zombies need a real attack animation, nothing
	# you've done works" -- rather than keep chasing whether the fragile
	# AnimationTree/attack.res chain actually plays (can't be confirmed
	# without running the game), add a guaranteed, code-driven visual cue
	# that never depends on that resource at all. This runs ALONGSIDE the
	# attempt above, not instead of it -- if the real animation does turn out
	# to work, both play together; if it doesn't, this is still a real,
	# visible swing every single time.
	if is_instance_valid(t) and t is Node3D:
		_play_procedural_attack_lunge((t as Node3D).global_position)

	var final_damage : float = damage * enrage_damage_mult * director_damage_mult

	# Enchant stacking: each stack = +15% (cap 5 stacks = +75%)
	var enchant_mult : float = 1.0 + energized_stacks * 0.15 if energized_timer > 0.0 else 1.0
	final_damage *= enchant_mult
	if energized_timer <= 0.0:
		if target_type != "turret" and target_type != "base":
			final_damage *= 0.45

	# ---- Chain attack (elite) -----------------------------

	if elite_ability == EliteAbility.CHAIN_ATTACK and is_instance_valid(t):
		_do_chain_attack(final_damage * 0.4)

	# ---- Life steal ---------------------------------------

	if life_steal_pct > 0.0:
		_heal(final_damage * life_steal_pct)

	if t.has_method("take_damage"):
		t.take_damage(final_damage, self)
		# Player-team-only Hebbian reinforcement -- see brain-load comment
		# in _ready(). A defend creep that actually lands a killing blow
		# strengthens Alert->Aggro (bounded by Spikeling's own GROW_CEIL/
		# RELAX_RATE homeostasis), so it gets measurably bolder over a
		# match the same way team_ally.gd's allies do. Enemy zombies never
		# call brain.learn() at all -- unchanged from before this feature.
		if team_id == 1 and is_instance_valid(brain) and "is_dead" in t and t.get("is_dead"):
			brain.learn(1.0)
		# PILLAR 1 -- GAME FEEL & JUICE (2026-07-20): Screenshake.gd was a
		# fully-built autoload (hit/explosion/base_hit/etc. presets) that
		# was never actually called ANYWHERE in the codebase -- zombie
		# attacks landing had zero camera feedback. Wired here, restrained
		# on purpose: only the player actually getting hit, or the base
		# coming under attack, shakes the screen -- not every turret
		# exchange, which would just be constant background noise.
		if t.is_in_group("players"):
			Screenshake.hit()
		elif target_type == "base":
			Screenshake.base_hit()

	# ---- Apply elemental effect from enchantment ----------
	var my_enchant : int = get_meta("enchantment") if has_meta("enchantment") else 0
	if my_enchant > 0 and energized_timer > 0.0:
		_apply_zombie_enchant_effect(t, final_damage, my_enchant)


func _spawn_enchant_number(t: Node, amount: float, enchant: int) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if not is_instance_valid(dn) or not dn.has_method("spawn_number"): return
	if not (t is Node3D): return
	dn.spawn_number(amount, (t as Node3D).global_position + Vector3(0, 2.2, 0), enchant, false)


func _apply_zombie_enchant_effect(t: Node, dmg: float, enchant: int) -> void:
	match enchant:
		1: # FIRE — burn DoT
			if t.has_method("apply_status"): t.apply_status(4, 3.0, dmg * 0.2)
			_zombie_dot(t, dmg * 0.15, 3, 1.0, 1)   # orange numbers
		2: # ICE — slow + number
			if t.has_method("apply_status"): t.apply_status(5, 2.5, 0.4)
			_spawn_enchant_number(t, dmg * 0.1, 2)   # cyan flash
		3: # POISON — poison DoT
			if t.has_method("apply_status"): t.apply_status(6, 5.0, dmg * 0.12)
			_zombie_dot(t, dmg * 0.08, 5, 1.0, 3)   # green numbers
		4: # ELECTRIC — chain to nearby
			_spawn_enchant_number(t, dmg * 0.35, 4)  # yellow
			for n in neighbors_cache:
				if not is_instance_valid(n) or n == t: continue
				if not ("team_id" in n) or int(n.get("team_id")) == team_id: continue
				if (n as Node3D).global_position.distance_to(t.global_position) > 4.0: continue
				if n.has_method("take_damage"):
					var chain_dmg := dmg * 0.35
					n.take_damage(chain_dmg, self)
					_spawn_enchant_number(n, chain_dmg, 4)
					break
		5: # SHADOW — extra damage at low HP
			if "health" in t and "max_health" in t:
				if float(t.get("health")) / maxf(float(t.get("max_health")), 1.0) < 0.4:
					var shadow_dmg := dmg * 0.5
					if t.has_method("take_damage"): t.take_damage(shadow_dmg, self)
					_spawn_enchant_number(t, shadow_dmg, 5)  # purple
		6: # VAMPIRIC — heal self + red number
			var heal_amt := dmg * 0.25
			_heal(heal_amt)
			# Show heal as vampiric number above self
			var dn := get_tree().get_first_node_in_group("damage_numbers")
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(heal_amt, global_position + Vector3(0, 2.5, 0), 6, false)


# ============================================================
# DOT SYSTEM (REWORKED — NO TIMER STORMS)
# ============================================================

var active_dots : Array = []

func _zombie_dot(
	t: Node,
	dmg: float,
	ticks: int,
	interval: float,
	enchant_type: int = 0
) -> void:

	if ticks <= 0:
		return

	if not is_instance_valid(t):
		return

	if t.has_method("is_dead") and t.is_dead():
		return

	active_dots.append({
		"target": t,
		"damage": dmg,
		"ticks": ticks,
		"interval": interval,
		"timer": interval,
		"type": enchant_type
	})

func _tick_active_dots(delta: float) -> void:

	if active_dots.is_empty():
		return

	for i in range(active_dots.size() - 1, -1, -1):

		var d : Dictionary = active_dots[i]

		d["timer"] -= delta

		if d["timer"] > 0.0:
			continue

		d["timer"] = d["interval"]
		d["ticks"] -= 1

		var t : Node = d["target"]

		if not is_instance_valid(t):
			active_dots.remove_at(i)
			continue

		if t.has_method("is_dead") and t.is_dead():
			active_dots.remove_at(i)
			continue

		if t.has_method("take_damage"):
			match d["type"]:
				1:
					t.take_damage(d["damage"], self, DamageType.FIRE)
				3:
					t.take_damage(d["damage"], self, DamageType.POISON)
				_:
					t.take_damage(d["damage"], self)

		_spawn_enchant_number(
			t,
			d["damage"],
			d["type"]
		)

		if d["ticks"] <= 0:
			active_dots.remove_at(i)
# ============================================================
# AAA: CHAIN ATTACK
# ============================================================

func _do_chain_attack(chain_damage: float) -> void:

	var chain_count : int = 0

	for n in neighbors_cache:

		if chain_count >= 2:
			break

		if not is_instance_valid(n):
			continue

		if n == self or n == target:
			continue

		if not ("team_id" in n):
			continue

		if int(n.get("team_id")) == team_id:
			continue

		var d : float = global_position.distance_to(n.global_position)

		if d > attack_range * 2.5:
			continue

		if n.has_method("take_damage"):
			n.take_damage(chain_damage, self)

		chain_count += 1

# ============================================================
# AAA: HEAL
# ============================================================

func _heal(amount: float) -> void:

	if is_dead:
		return

	health = minf(health + amount, max_health)

# ============================================================
# DAMAGE (ORIGINAL + AAA ARMOR + STATUS + PHASE)
# ============================================================

# Enchant weakness table — index = enchant type, value = weakness enchant type
# FIRE(1) weak to ICE(2), ICE(2) weak to FIRE(1), POISON(3) weak to ELECTRIC(4),
# ELECTRIC(4) weak to POISON(3), SHADOW(5) weak to VAMPIRIC(6), VAMPIRIC(6) weak to SHADOW(5)
const ENCHANT_WEAKNESS : Array = [0, 2, 1, 4, 3, 6, 5]

var _last_instigator = null   # tracks who dealt the killing blow

func take_damage(
	amount: float,
	instigator = null,
	damage_type: int = DamageType.PHYSICAL
) -> void:

	# Defensive, matching Egg/HiveCluster/player.gd's convention: CombatRelay
	# only ever calls take_damage() on the server's own copy of a target
	# (basegun.gd's authority-gated resolve-locally-or-relay branch), so this
	# guard isn't a path any current caller reaches -- insurance against a
	# future caller that isn't as careful.
	if NetworkManager.is_networked and not is_multiplayer_authority():
		return

	if is_dead:
		return

	if phase_transitioning:
		return

	# Reveal health bar on first hit
	if is_instance_valid(health_bar_root) and not health_bar_root.visible:
		health_bar_root.visible = true

	# ---- Enchant weakness check --------------------------------
	# If zombie is energized AND instigator has the weakness enchant → +50% damage
	if energized_timer > 0.0 and is_instance_valid(instigator):
		var zombie_enchant : int = get_meta("enchantment") if has_meta("enchantment") else 0
		var atk_enchant   : int = int(instigator.get("enchantment") if "enchantment" in instigator else 0)
		if zombie_enchant > 0 and atk_enchant > 0:
			if ENCHANT_WEAKNESS[zombie_enchant] == atk_enchant:
				amount *= 1.5   # weakness bonus
			elif atk_enchant == zombie_enchant:
				amount *= 0.75  # same element is slightly resisted

	# ---- Shield absorb (elite) ----------------------------

	if shield_active and shield_hp > 0.0:

		var absorbed : float = minf(shield_hp, amount)

		shield_hp -= absorbed
		amount -= absorbed

		if shield_hp <= 0.0:
			shield_active = false

		_spawn_damage_number(absorbed, true)

		if amount <= 0.0:
			return

	# ---- Armor DR -----------------------------------------

	var reduced : float = _apply_armor(amount, damage_type)

	health -= reduced

	# Player-team-only self-preservation reflex -- see brain-load comment in
	# _ready(). Enemy zombies get no extra stimulus here; their Caution
	# still only comes from losing ground on a target, same as before.
	if team_id == 1 and is_instance_valid(brain):
		brain.stimulate("Caution", ALLY_DAMAGE_CAUTION_STIMULUS)

	_play_sound(hurt_sounds, 2.0)

	_spawn_damage_number(reduced, false)

	# ---- Knockback: a real push away from whoever/whatever hit us -----
	if is_instance_valid(instigator) and instigator is Node3D and reduced > 0.0:
		var away : Vector3 = global_position - (instigator as Node3D).global_position
		away.y = 0.0
		if away.length_squared() > 0.001:
			away = away.normalized()
			# scales with hit strength but capped so a big hit doesn't launch
			# the zombie absurdly far -- a stagger, not a rocket
			var strength : float = clampf(reduced * 0.35, 1.5, 9.0)
			_knockback_velocity = away * strength
			_knockback_timer = KNOCKBACK_DURATION

	if is_instance_valid(instigator) and instigator is Node3D:
		# Only retaliate against actual combat units — not weapons/projectiles
		var _ins := instigator as Node3D
		var _is_combatant : bool = (
			_ins.is_in_group("player") or
			_ins.is_in_group("units")  or
			_ins.is_in_group("zombies")
		)
		if _is_combatant:
			target = _ins
			target_type = "unit"

	# ---- Status on hit (example: fire applies burn) -------

	_maybe_apply_status_from_damage(damage_type)

	# ---- Phase check first --------------------------------

	if is_phase_zombie:

		_check_phase_transition()

		if phase_transitioning:
			return

	# ---- Boss threshold check ----------------------------

	if is_boss:
		_check_boss_thresholds()

	if health <= 0.0:
		if is_instance_valid(instigator): _last_instigator = instigator
		_die()

# ============================================================
# AAA: ARMOR DR
# ============================================================

func _apply_armor(amount: float, damage_type: int) -> float:

	if damage_type == DamageType.TRUE_DAMAGE:
		return amount

	var dr : float = 0.0

	match damage_type:
		DamageType.PHYSICAL:
			dr = armor_physical
		DamageType.SLASH:
			dr = armor_slash
		DamageType.BLUNT:
			dr = armor_blunt
		DamageType.PIERCE:
			dr = armor_pierce
		DamageType.MAGIC:
			dr = armor_magic
		DamageType.FIRE:
			dr = armor_fire
		DamageType.ICE:
			dr = armor_ice
		DamageType.POISON:
			dr = armor_poison

	var dr_pct : float = dr / (dr + 100.0)

	dr_pct = clampf(dr_pct, 0.0, armor_dr_cap)

	return amount * (1.0 - dr_pct)

# ============================================================
# AAA: DAMAGE NUMBER SPAWN
# ============================================================

# ============================================================
# DAMAGE NUMBER SPAWN (REWORKED)
# ============================================================

func _spawn_damage_number(
	amount: float,
	is_shield: bool
) -> void:

	_cache_damage_number_manager()

	if damage_number_manager == null:
		return

	if not damage_number_manager.has_method("spawn_number"):
		return

	damage_number_manager.spawn_number(
		amount,
		global_position + Vector3(0, 2.0, 0),
		1 if is_shield else 0,
		is_shield
	)
# ============================================================
# AAA: STATUS FROM DAMAGE
# ============================================================

func _maybe_apply_status_from_damage(damage_type: int) -> void:

	match damage_type:

		DamageType.FIRE:
			apply_status(StatusType.BURN, 4.0, 5.0)

		DamageType.ICE:
			apply_status(StatusType.FREEZE, 2.0, 1.0)
			apply_status(StatusType.SLOW, 3.0, 0.4)

		DamageType.POISON:
			apply_status(StatusType.POISON, 6.0, 3.0)

# ============================================================
# AAA: APPLY STATUS EFFECT
# ============================================================

func apply_status(
	type: int,
	duration: float,
	strength: float
) -> void:

	if is_dead:
		return

	if status_effects.has(type):

		var existing : Dictionary = status_effects[type]

		var existing_timer : float = existing.get("timer", 0.0)

		status_effects[type] = {
			"timer": maxf(existing_timer, duration),
			"strength": maxf(existing.get("strength", 0.0), strength),
			"tick_timer": existing.get("tick_timer", 0.0)
		}

	else:

		status_effects[type] = {
			"timer": duration,
			"strength": strength,
			"tick_timer": 0.0
		}

	_apply_status_immediate(type, strength)

# ============================================================
# AAA: IMMEDIATE STATUS EFFECT APPLY
# ============================================================

# ============================================================
# APPLY STATUS IMMEDIATE (FIXED SLOW STACKING)
# ============================================================

func _apply_status_immediate(
	type: int,
	strength: float
) -> void:

	match type:

		StatusType.STUN:
			is_stunned = true

		StatusType.FREEZE:
			is_frozen = true
			is_stunned = true

		StatusType.SLOW:
			current_slow = maxf(
				current_slow,
				strength
			)

		StatusType.ENRAGED:
			enrage_damage_mult = 1.0 + strength
			enrage_speed_mult = 1.0 + (strength * 0.5)

# ============================================================
# AAA: TICK STATUS EFFECTS
# ============================================================

# ============================================================
# STATUS EFFECT TICK (REWORKED)
# ============================================================
# ============================================================
# DAMAGE NUMBER CACHE
# ============================================================

var damage_number_manager : Node = null

func _cache_damage_number_manager() -> void:

	if damage_number_manager != null:
		return

	damage_number_manager = get_tree().get_first_node_in_group("damage_numbers")
func _tick_status_effects(delta: float) -> void:

	if status_effects.is_empty():
		return

	var to_remove : Array = []

	for type in status_effects.keys():

		var data : Dictionary = status_effects[type]

		data["timer"] -= delta

		if data["timer"] <= 0.0:
			to_remove.append(type)
			continue

		match type:

			StatusType.BURN:

				data["tick_timer"] -= delta

				if data["tick_timer"] <= 0.0:

					data["tick_timer"] = 1.0

					var burn_dmg : float = data.get("strength", 5.0)

					take_damage(
						burn_dmg,
						null,
						DamageType.FIRE
					)

					if health <= 0.0:
						return

			StatusType.POISON:

				data["tick_timer"] -= delta

				if data["tick_timer"] <= 0.0:

					data["tick_timer"] = 1.5

					var poison_dmg : float = data.get("strength", 3.0)

					take_damage(
						poison_dmg,
						null,
						DamageType.POISON
					)

					if health <= 0.0:
						return

	for type in to_remove:

		_expire_status(type)

		status_effects.erase(type)

# ============================================================
# AAA: EXPIRE STATUS
# ============================================================

func _expire_status(type: int) -> void:

	match type:

		StatusType.STUN:
			is_stunned = false

		StatusType.FREEZE:
			is_frozen = false
			is_stunned = false

		StatusType.SLOW:
			current_slow = 0.0
			# Re-check if another slow is still active
			for other_type in status_effects.keys():
				if other_type == StatusType.SLOW:
					current_slow = status_effects[other_type].get("strength", 0.0)

		StatusType.ENRAGED:
			enrage_damage_mult = 1.0
			enrage_speed_mult = 1.0

# ============================================================
# AAA: PHASE ZOMBIE — CHECK TRANSITION
# ============================================================

func _check_phase_transition() -> void:

	if phase_current >= phase_health_thresholds.size():
		return

	var threshold : float = phase_health_thresholds[phase_current]

	if health <= threshold:

		phase_transitioning = true
		phase_transition_timer = phase_transition_delay

		_play_sound(phase_sounds, 8.0)

		if anim_tree != null:
			anim_tree.set(
				"parameters/phase_shot/request",
				AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
			)

		_on_phase_start(phase_current)

# ============================================================
# AAA: PHASE START
# ============================================================

func _on_phase_start(phase_index: int) -> void:

	# Override in subclass or connect signal for custom logic
	emit_signal("phase_started", phase_index)

# ============================================================
# AAA: PHASE COMPLETE
# ============================================================

func _on_phase_complete() -> void:

	phase_current += 1

	emit_signal("phase_completed", phase_current - 1)

	# ---- Partial heal between phases ----------------------

	if phase_current < phase_health_thresholds.size():

		health = maxf(
			health,
			phase_health_thresholds[phase_current - 1] * 0.1
		)

# ============================================================
# AAA: BOSS — CHECK THRESHOLDS
# ============================================================

# ============================================================
# BOSS CHECKS (FIXED LOOP)
# ============================================================

func _tick_boss_checks() -> void:

	if not is_boss:
		return

	var pct : float = health / maxf(max_health, 1.0)

	for i in range(boss_phase_thresholds.size()):

		if boss_phase_triggered[i]:
			continue

		if pct <= boss_phase_thresholds[i]:

			boss_phase_triggered[i] = true
			boss_phase = i + 1

			_on_boss_phase_start(boss_phase)

	if not boss_enraged and pct <= boss_enrage_threshold:

		boss_enraged = true

		_play_sound(enrage_sounds, 10.0)

		apply_status(
			StatusType.ENRAGED,
			9999.0,
			0.5
		)

		emit_signal("boss_enraged")

func _check_boss_thresholds() -> void:

	_tick_boss_checks()

# ============================================================
# AAA: BOSS PHASE START
# ============================================================

func _on_boss_phase_start(phase_index: int) -> void:

	emit_signal("boss_phase_started", phase_index)

# ============================================================
# AAA: ELITE ABILITY TICK
# ============================================================

func _tick_elite_ability(delta: float) -> void:

	if not is_elite:
		return

	if elite_ability_timer > 0.0:
		return

	elite_ability_timer = elite_ability_cooldown

	_fire_elite_ability()

# ============================================================
# AAA: FIRE ELITE ABILITY
# ============================================================

func _fire_elite_ability() -> void:

	_play_sound_on(sfx_ability, ability_sounds, 7.0, "zombie_ability")

	match elite_ability:

		EliteAbility.REGEN:
			_ability_regen()

		EliteAbility.SHIELD_BURST:
			_ability_shield_burst()

		EliteAbility.LEAP:
			_ability_leap()

		EliteAbility.FRENZY:
			_ability_frenzy()

		EliteAbility.GHOST:
			_ability_ghost()

		EliteAbility.SPORE_CLOUD:
			_ability_spore_cloud()

		EliteAbility.LIFE_STEAL:
			pass

		EliteAbility.CHAIN_ATTACK:
			pass

# ============================================================
# AAA: ELITE — REGEN
# ============================================================

func _ability_regen() -> void:
	var regen_amount : float = max_health * 0.18   # buffed: 8%→18%
	_heal(regen_amount)
	# Aura heal: also heal nearby friendly zombies for 5%
	for n in neighbors_cache:
		if not is_instance_valid(n) or n == self: continue
		if not ("team_id" in n) or int(n.get("team_id")) != team_id: continue
		if n.has_method("_heal"):
			n.call("_heal", float(n.get("max_health") if "max_health" in n else 100.0) * 0.05)

# ============================================================
# AAA: ELITE — SHIELD BURST
# ============================================================

func _ability_shield_burst() -> void:
	shield_hp = shield_max * 1.5   # buffed: 150% max shield on self
	shield_active = true
	# Grant 20% mini-shield to nearby friendly zombies
	for n in neighbors_cache:
		if not is_instance_valid(n) or n == self: continue
		if not ("team_id" in n) or int(n.get("team_id")) != team_id: continue
		if "shield_max" in n and "shield_hp" in n:
			var mini : float = float(n.get("max_health") if "max_health" in n else 100.0) * 0.20
			n.set("shield_max", maxi(int(n.get("shield_max")), int(mini)))
			n.set("shield_hp",  mini)
			n.set("shield_active", true)

# ============================================================
# AAA: ELITE — LEAP
# ============================================================

func _ability_leap() -> void:
	if not is_instance_valid(target): return
	var dir : Vector3 = (target.global_position - global_position).normalized()
	dir.y = 0.0
	velocity.x = dir.x * move_speed * 6.0   # buffed speed
	velocity.z = dir.z * move_speed * 6.0
	if is_on_floor(): velocity.y = 12.0     # buffed jump height
	# Schedule landing AoE — deal damage to ALL enemies in 4m radius on landing
	get_tree().create_timer(0.7).timeout.connect(func():
		if not is_instance_valid(self): return
		var land_dmg : float = damage * 2.5
		for grp in ["players", "units", "zombies", "turrets"]:
			for e in get_tree().get_nodes_in_group(grp):
				if not is_instance_valid(e) or e == self: continue
				if "team_id" in e and int(e.get("team_id")) == team_id: continue
				if not (e is Node3D): continue
				if global_position.distance_to((e as Node3D).global_position) <= 4.0:
					if e.has_method("take_damage"): e.take_damage(land_dmg, self)
	, CONNECT_ONE_SHOT)

# ============================================================
# AAA: ELITE — FRENZY
# ============================================================

func _ability_frenzy() -> void:
	apply_status(StatusType.ENRAGED, 10.0, 0.8)   # buffed: 5s→10s, 40%→80%
	# War cry: enrage nearby friendly zombies too
	for n in neighbors_cache:
		if not is_instance_valid(n) or n == self: continue
		if not ("team_id" in n) or int(n.get("team_id")) != team_id: continue
		if n.has_method("apply_status"):
			n.apply_status(StatusType.ENRAGED, 6.0, 0.4)

# ============================================================
# AAA: ELITE — GHOST
# ============================================================

# ============================================================
# GHOST ABILITY (SAFE)
# ============================================================

func _ability_ghost() -> void:

	elite_ghost_timer = 5.0

	var removed_units : bool = is_in_group("units")
	var removed_zombies : bool = is_in_group("zombies")

	if removed_units:
		remove_from_group("units")

	if removed_zombies:
		remove_from_group("zombies")

	get_tree().create_timer(5.0).timeout.connect(func():

		if not is_instance_valid(self):
			return

		if is_dead:
			return

		if removed_units:
			add_to_group("units")

		if removed_zombies:
			add_to_group("zombies")

	, CONNECT_ONE_SHOT)
# ============================================================
# AAA: ELITE — SPORE CLOUD
# ============================================================

func _ability_spore_cloud() -> void:
	# Hit ALL enemy groups in 8m radius — players, zombies, units, turrets
	for grp in ["players", "units", "zombies"]:
		for n in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(n) or n == self: continue
			if not ("team_id" in n) or int(n.get("team_id")) == team_id: continue
			if not (n is Node3D): continue
			if global_position.distance_to((n as Node3D).global_position) > 8.0: continue
			if n.has_method("apply_status"):
				n.apply_status(StatusType.POISON, 8.0, 6.0)   # buffed
				n.apply_status(StatusType.SLOW,   4.0, 0.5)   # also slows
			if n.has_method("take_damage"):
				n.take_damage(damage * 0.5, self)   # instant burst damage

# ============================================================
# AAA: SWARM INTELLIGENCE
# ============================================================

func _register_swarm() -> void:

	add_to_group("swarm_units")

# ============================================================
# SWARM TICK (FIXED TIMER)
# ============================================================

func _tick_swarm(delta: float) -> void:

	if not swarm_enabled:
		return

	swarm_pheromone_timer -= delta

	if swarm_pheromone_timer > 0.0:
		return

	swarm_pheromone_timer = randf_range(2.0, 4.0)

	_broadcast_pheromone()

	_receive_swarm_data()

func _broadcast_pheromone() -> void:
	if not is_instance_valid(target): return
	if neighbors_cache.is_empty(): return   # nothing to broadcast to

	for n in neighbors_cache:

		if not is_instance_valid(n):
			continue

		if n == self:
			continue

		if not ("team_id" in n):
			continue

		if int(n.get("team_id")) != team_id:
			continue

		if not n.has_method("receive_pheromone"):
			continue

		var d : float = global_position.distance_to(n.global_position)

		if d > swarm_broadcast_radius:
			continue

		n.receive_pheromone(
			target.global_position,
			swarm_pheromone_strength
		)

func _receive_swarm_data() -> void:

	if swarm_leader == null:
		return

	if not is_instance_valid(swarm_leader):
		swarm_leader = null
		return

	if swarm_follow_leader and not is_instance_valid(target):

		if swarm_leader.has_method("get_target"):
			var leader_target : Node3D = swarm_leader.call("get_target")
			if is_instance_valid(leader_target):
				target = leader_target
				target_type = "unit"

# ============================================================
# AAA: RECEIVE PHEROMONE (PUBLIC)
# ============================================================

func receive_pheromone(
	pos: Vector3,
	strength: float
) -> void:

	swarm_pheromone_pos = pos
	swarm_pheromone_active = true
	swarm_pheromone_timer = maxf(
		swarm_pheromone_timer,
		2.0 * strength
	)

# ============================================================
# AAA: GET TARGET (PUBLIC for swarm)
# ============================================================

func get_target() -> Node3D:

	return target

# ============================================================
# DIE
# ============================================================

# ============================================================
# DIE (FULL SAFE CLEANUP)
# ============================================================

func _die() -> void:
	if is_dead: return

	# ── Conversion check — only when a Necromancer player is alive ──
	if conversion_enabled:
		# Verify a local player with Necromancer class (enum 1) is present
		var necro_active : bool = false
		for p in get_tree().get_nodes_in_group("players"):
			if is_instance_valid(p) and "player_class" in p:
				if int(p.get("player_class")) == 1:  # PlayerClass.NECROMANCER
					necro_active = true
					break
		if necro_active:
			convert_team()
			return
	# ────────────────────────────────────────────────────────

	is_dead = true
	status_effects.clear()
	active_dots.clear()
	velocity = Vector3.ZERO
	set_physics_process(false)
	is_dead = true
	status_effects.clear()
	active_dots.clear()
	velocity = Vector3.ZERO
	set_physics_process(false)
	_play_sound(death_sounds, 7.0)

	if anim_tree != null and anim_tree.active:
		for dp in ["parameters/death_shot/request",
				   "parameters/Death/request",
				   "parameters/death/request"]:
			if anim_tree.get(dp) != null:
				anim_tree.set(dp, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
				break
		anim_tree.active = false

	var _apd := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if is_instance_valid(_apd):
		if _apd.has_animation("Death"): _apd.play("Death")
		elif _apd.has_animation("death"): _apd.play("death")
		elif _apd.has_animation("Die"): _apd.play("Die")

	_award_gold()
	_drop_crystals()
	if elite_drops_creep_card:
		_drop_elite_creep_card()
	emit_signal("zombie_died", self)
	# Cinematic death VFX
	var vfx := get_tree().get_first_node_in_group("vfx_manager")
	if is_instance_valid(vfx):
		vfx.death_burst(global_position)
	# Notify killer player so kill streak / ult charge / mastery all fire
	var killer : Node = _last_instigator as Node
	if is_instance_valid(killer):
		# Walk up to the root player node if instigator is a weapon/bullet
		var node : Node = killer
		while is_instance_valid(node) and not node.is_in_group("players"):
			node = node.get_parent()
		if is_instance_valid(node) and node.is_in_group("players"):
			killer = node
	if is_instance_valid(killer) and killer.has_method("on_kill"):
		killer.on_kill(self)

	# Notify ZHM before freeing so it can return to pool cleanly
	var zhm := Engine.get_singleton("ZombieHordeManager") if Engine.has_singleton("ZombieHordeManager") else null
	if is_instance_valid(zhm) and zhm.has_method("on_zombie_died"):
		zhm.on_zombie_died(self)
		# ZHM handles cleanup — don't queue_free, it returns to pool
		return

	# No ZHM — free normally
	await get_tree().create_timer(1.4).timeout
	if is_instance_valid(self): queue_free()
# ============================================================
# GOLD
# ============================================================

func _drop_crystals() -> void:
	# Use crystal_drop_chance if available (set by subclass or inspector)
	var drop_chance : float = get("crystal_drop_chance") if "crystal_drop_chance" in self else 0.3
	if randf() > drop_chance: return
	var drop_pos : Vector3 = global_position
	# Try to use CrystalShard script
	for path in ["res://scripts/CrystalShard.gd","res://CrystalShard.gd",
				 "res://scenes/CrystalShard.gd","res://pickups/CrystalShard.gd"]:
		if ResourceLoader.exists(path):
			var shard : Node3D = Node3D.new()
			shard.set_script(load(path))
			get_tree().current_scene.add_child(shard)
			shard.global_position = drop_pos + Vector3(randf_range(-0.6,0.6), 1.2, randf_range(-0.6,0.6))
			return
	# Inline fallback crystal
	_spawn_inline_crystal(drop_pos + Vector3(randf_range(-0.5,0.5), 1.2, randf_range(-0.5,0.5)))


func _spawn_inline_crystal(pos: Vector3) -> void:
	var root := Node3D.new()
	get_tree().current_scene.add_child(root); root.global_position = pos
	var mi := MeshInstance3D.new(); var gem := CylinderMesh.new()
	gem.top_radius = 0.0; gem.bottom_radius = 0.18; gem.height = 0.38; gem.radial_segments = 5
	mi.mesh = gem; var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; mat.emission_enabled = true
	mat.emission = Color(0.55,0.2,1.0); mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(0.55,0.2,1.0,0.88); mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat; root.add_child(mi)
	var lt := OmniLight3D.new(); lt.light_color = Color(0.55,0.2,1.0)
	lt.light_energy = 1.5; lt.omni_range = 2.5; lt.shadow_enabled = false; root.add_child(lt)
	var tw := root.create_tween().set_loops()
	tw.tween_property(root,"position:y",pos.y+0.2,0.5).set_trans(Tween.TRANS_SINE)
	tw.tween_property(root,"position:y",pos.y,0.5).set_trans(Tween.TRANS_SINE)
	get_tree().create_timer(18.0).timeout.connect(func():
		if is_instance_valid(root): root.queue_free())


func _drop_elite_creep_card() -> void:
	var cdm : Node = get_tree().get_first_node_in_group("creep_deck_manager")
	if not is_instance_valid(cdm): return
	var all_creeps : Array = cdm.call("get_all_creeps")
	if all_creeps.is_empty(): return
	var def : Dictionary = all_creeps[randi() % all_creeps.size()]
	var creep_id : String = def.get("id", "")
	if creep_id.is_empty(): return
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p): continue
		if "player_id" not in p: continue
		var pid : int = int(p.get("player_id"))
		cdm.call("add_card_to_deck", pid, creep_id)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message("Elite card dropped: %s!" % def.get("name", creep_id), Color(1.0, 0.6, 0.1))


func _award_gold() -> void:

	var gm : Node = get_tree().get_first_node_in_group("game_manager")

	if gm == null:
		return

	var enemy_team : int = 2

	if team_id == 2:
		enemy_team = 1

	if gm.has_method("award_gold"):
		gm.award_gold(enemy_team, gold_reward)

# ============================================================
# STUCK
# ============================================================

## Thin wrapper around MovementRecovery.gd (2026-08-24 rebuild) -- keeps this
## script's own combat-aware guard (see the 2026-08-24 comment history: firing
## _unstuck() on a zombie deliberately holding still to melee an in-range
## target caused exactly the random pop/hop sink bug near walls/ramps), then
## delegates the actual stuck-detection + recovery to the shared class.
func _update_stuck(delta: float) -> void:
	if attack_timer > 0.0 and is_instance_valid(target) \
			and global_position.distance_to(target.global_position) <= _get_attack_range() + 1.0:
		_recovery.reset_progress(global_position)
		return

	var r : Dictionary = _recovery.tick(delta, global_position, stuck_distance, stuck_time, get_world_3d(), is_on_floor())
	if r.fired:
		global_position = r.teleport_to
		velocity.x += r.velocity_add.x
		velocity.z += r.velocity_add.y
		if r.set_velocity_y != null:
			velocity.y = r.set_velocity_y

# ============================================================
# HEALTH BAR — PRIMARY (ORIGINAL)
# ============================================================

func _build_health_bar() -> void:

	# Remove any pre-existing health bar (e.g. from scene editor) to prevent doubles
	var existing := find_child("HBar", true, false)
	if is_instance_valid(existing): existing.queue_free()
	var existing2 := find_child("HealthBar", true, false)
	if is_instance_valid(existing2): existing2.queue_free()

	var root := Node3D.new()
	root.name = "HBar"
	root.position = Vector3(0, health_bar_height, 0)

	add_child(root)

	health_bar_root = root

	var bg := MeshInstance3D.new()

	var bg_mesh := QuadMesh.new()

	bg_mesh.size = Vector2(1.2, 0.16)

	bg.mesh = bg_mesh

	var bg_mat := StandardMaterial3D.new()

	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.albedo_color = Color(0.05, 0.05, 0.05, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	bg.material_override = bg_mat

	root.add_child(bg)

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.1, 1.0, 0.1)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	root.add_child(fill)

	health_bar_fill = fill

	# ---- AAA: Shield bar slot (built on top) --------------

	_build_shield_bar(root)

	# Hidden until first damage taken
	root.visible = false

# ============================================================
# AAA: SHIELD BAR (attached to primary bar root)
# ============================================================

var shield_bar_fill : MeshInstance3D = null

func _build_shield_bar(parent: Node3D) -> void:

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	fill.position.y = 0.0

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.5, 0.8, 1.0, 0.6)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	fill.visible = false

	parent.add_child(fill)

	shield_bar_fill = fill

# ============================================================
# HEALTH BAR — PHASE (DOUBLE BAR FOR PHASE ZOMBIES)
# ============================================================

func _build_phase_health_bar() -> void:

	var root := Node3D.new()

	# Positioned above the primary bar
	root.position = Vector3(0, 3.15, 0)

	add_child(root)

	phase_bar_root = root

	# ---- Background ---------------------------------------

	var bg := MeshInstance3D.new()

	var bg_mesh := QuadMesh.new()

	bg_mesh.size = Vector2(1.2, 0.16)

	bg.mesh = bg_mesh

	var bg_mat := StandardMaterial3D.new()

	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.albedo_color = Color(0.05, 0.02, 0.08, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	bg.material_override = bg_mat

	root.add_child(bg)

	# ---- Phase fill (purple tinted) ----------------------

	var fill := MeshInstance3D.new()

	var fill_mesh := QuadMesh.new()

	fill_mesh.size = Vector2(1.0, 0.12)

	fill.mesh = fill_mesh

	var fill_mat := StandardMaterial3D.new()

	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.albedo_color = Color(0.7, 0.2, 1.0)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	fill.material_override = fill_mat

	root.add_child(fill)

	phase_bar_fill = fill

	# ---- Segment dividers (one per phase) -----------------

	_build_phase_segment_markers(root)

# ============================================================
# AAA: PHASE SEGMENT MARKERS
# ============================================================

func _build_phase_segment_markers(parent: Node3D) -> void:

	phase_bar_segment_markers.clear()

	if phase_count <= 1:
		return

	for i in range(1, phase_count):

		var marker := MeshInstance3D.new()

		var m_mesh := QuadMesh.new()

		m_mesh.size = Vector2(0.025, 0.18)

		marker.mesh = m_mesh

		var m_mat := StandardMaterial3D.new()

		m_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
		m_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		marker.material_override = m_mat

		# Position divider at the correct fraction of bar width
		var pct : float = float(i) / float(phase_count)

		marker.position.x = (pct - 0.5) * 1.0

		parent.add_child(marker)

		phase_bar_segment_markers.append(marker)

# ============================================================
# UPDATE HEALTH BAR (ORIGINAL + SHIELD OVERLAY)
# ============================================================

var _last_health_pct : float = -1.0   # cached to skip redundant mesh uploads

# ============================================================
# HEALTH BAR UPDATE (REWORKED — NO MESH RESIZE)
# ============================================================



func _update_health_bar() -> void:

	if health_bar_fill == null:
		return

	var pct : float = clampf(
		health / maxf(max_health, 0.01),
		0.0,
		1.0
	)

	if absf(pct - _last_health_pct) < 0.005:
		return

	_last_health_pct = pct

	health_bar_fill.scale.x = pct
	health_bar_fill.position.x = (pct - 1.0) * 0.5

	var mat := health_bar_fill.material_override as StandardMaterial3D

	if mat != null:
		mat.albedo_color = Color(
			1.0 - pct,
			pct,
			0.0
		)

	if shield_bar_fill != null:

		if shield_active and shield_max > 0.0:

			shield_bar_fill.visible = true

			var s_pct : float = clampf(
				shield_hp / shield_max,
				0.0,
				1.0
			)

			shield_bar_fill.scale.x = s_pct * pct
			shield_bar_fill.position.x = health_bar_fill.position.x

		else:

			shield_bar_fill.visible = false
# ============================================================
# UPDATE PHASE BAR
# ============================================================

# ============================================================
# PHASE BAR UPDATE (REWORKED)
# ============================================================

func _update_phase_bar() -> void:

	if not is_phase_zombie:
		return

	if phase_bar_fill == null:
		return

	var phase_total : int = phase_health_thresholds.size()

	if phase_total == 0:
		return

	var current_phase_top : float = max_health

	if phase_current > 0:
		current_phase_top = phase_health_thresholds[phase_current - 1]

	var current_phase_bottom : float = 0.0

	if phase_current < phase_health_thresholds.size():
		current_phase_bottom = phase_health_thresholds[phase_current]

	var span : float = current_phase_top - current_phase_bottom

	var within : float = health - current_phase_bottom

	var pct : float = clampf(
		within / maxf(span, 0.01),
		0.0,
		1.0
	)

	phase_bar_fill.scale.x = pct
	phase_bar_fill.position.x = (pct - 1.0) * 0.5

	var mat := phase_bar_fill.material_override as StandardMaterial3D

	if mat != null:

		if phase_transitioning:

			var pulse : float = 0.5 + 0.5 * sin(
				Time.get_ticks_msec() * 0.012
			)

			mat.albedo_color = Color(
				0.7 + pulse * 0.3,
				0.1,
				1.0
			)

		else:

			mat.albedo_color = Color(
				0.7,
				0.2,
				1.0
			)

# ============================================================
# ENERGY ICON (ORIGINAL)
# ============================================================

func _build_energy_icon() -> void:

	var orb := MeshInstance3D.new()

	var sphere := SphereMesh.new()

	sphere.radius = 0.16

	orb.mesh = sphere

	var mat := StandardMaterial3D.new()

	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.8, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(0.3, 0.8, 1.0, 0.7)

	orb.material_override = mat

	# REAL BUG FIX (2026-08-19): was a hardcoded Vector3(0, 3.0, 0) -- looked
	# fine on whichever zombie type that number happened to be tuned against,
	# but every other type (tank/shaman/berserker/leaper each have their own
	# model height, see health_bar_height below) either floated way above the
	# mesh or clipped into it. health_bar_height is already the established,
	# per-scene-calibrated "how tall is THIS zombie type" value used for the
	# health bar above -- reuse it instead of guessing a second, unrelated
	# constant.
	orb.position = Vector3(0, health_bar_height + 0.4, 0)

	add_child(orb)

	energy_icon = orb

# ============================================================
# UPDATE ENERGY (ORIGINAL)
# ============================================================

func _update_energy_icon() -> void:

	if energy_icon == null:
		return

	var mat := energy_icon.material_override as StandardMaterial3D

	if mat == null:
		return

	if energized_timer > 0.0:
		var pulse : float = 2.0 + sin(Time.get_ticks_msec() * 0.008)
		mat.emission_energy_multiplier = pulse

		# Color matches enchant type
		var _my_e : int = get_meta("enchantment") if has_meta("enchantment") else 0
		var _ecols : Array = [Color(0.3,0.8,1.0),Color(1.0,0.35,0.0),Color(0.3,0.8,1.0),
			Color(0.2,0.9,0.1),Color(1.0,0.95,0.1),Color(0.5,0.0,0.8),Color(0.8,0.0,0.2)]
		mat.albedo_color = _ecols[clampi(_my_e, 0, 6)]

	else:

		mat.emission_energy_multiplier = 0.4

		mat.albedo_color = Color(0.3, 0.3, 0.3, 0.4)

# ============================================================
# RECEIVE ENERGY (ORIGINAL)
# ============================================================

var energized_stacks : int = 0  # each stack adds 15% bonus (cap 5)

func receive_energy(duration: float) -> void:
	if energized_timer > 0.0:
		energized_stacks = mini(energized_stacks + 1, 5)
	else:
		energized_stacks = 1
	energized_timer = maxf(energized_timer, duration)

# ============================================================
# ANIMATION (ORIGINAL + AAA STATES)
# ============================================================

var _last_anim_blend : float = -1.0
# Common AnimationTree param paths to try for locomotion blend
const BLEND_PARAMS : Array = [
	"parameters/move_blend/blend_position",
	"parameters/Locomotion/blend_position",
	"parameters/blend/blend_position",
	"parameters/BlendSpace1D/blend_position",
	"parameters/Walk/blend_amount",
	"parameters/speed/blend_amount",
]
var _blend_param : String = ""   # cached once found

func _find_blend_param() -> String:
	if _blend_param != "": return _blend_param
	if anim_tree == null: return ""
	for p in BLEND_PARAMS:
		if anim_tree.get(p) != null:
			_blend_param = p; return p
	return ""

func _update_animation() -> void:
	# Defer bone correction so it runs after AnimationTree finishes updating poses
	call_deferred("_correct_root_bone_y")
	# Don't override attack animation while it's playing
	if _attack_anim_timer > 0.0: return

	var spd2  : float = velocity.x * velocity.x + velocity.z * velocity.z
	var speed : float = sqrt(spd2)
	anim_state_current = "stunned" if (is_stunned or is_frozen) else ("walk" if speed > 0.2 else "idle")
	anim_blend_speed = speed
	if anim_tree != null and anim_tree.active:
		var blend : float = clampf(speed / maxf(move_speed, 0.01), 0.0, 1.0)
		if absf(blend - _last_anim_blend) > 0.015:
			_last_anim_blend = blend
			var param := _find_blend_param()
			if param != "":
				var cur = anim_tree.get(param)
				if cur is Vector2: anim_tree.set(param, Vector2(0.0, blend))
				else:              anim_tree.set(param, blend)
		return
	# Fallback: AnimationPlayer direct
	var ap := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if not is_instance_valid(ap): return
	if speed > 0.2:
		if ap.has_animation("Walk") and ap.current_animation != "Walk":
			ap.play("Walk")
		elif ap.has_animation("walk") and ap.current_animation != "walk":
			ap.play("walk")
		elif ap.has_animation("Run") and ap.current_animation != "Run":
			ap.play("Run")
	else:
		if ap.has_animation("Idle") and ap.current_animation != "Idle":
			ap.play("Idle")
		elif ap.has_animation("idle") and ap.current_animation != "idle":
			ap.play("idle")

# ============================================================
# SOUND (ORIGINAL)
# ============================================================

func _play_sound(
	arr: Array,
	volume: float,
	category: String = ""
) -> void:

	if not audio_enabled:
		return

	if sfx == null:
		return

	if arr.is_empty():
		return

	var valid : Array = []

	for s in arr:
		if s != null:
			valid.append(s)

	if valid.is_empty():
		return

	if category != "":
		var am := get_node_or_null("/root/AudioManager")
		if is_instance_valid(am) and not am.claim_voice(category, sfx):
			return

	sfx.stream = valid.pick_random()
	sfx.volume_db = volume
	sfx.pitch_scale = randf_range(0.92, 1.08)
	sfx.play()

# ============================================================
# AAA: PLAY SOUND ON SPECIFIC PLAYER
# ============================================================

func _play_sound_on(
	player: AudioStreamPlayer3D,
	arr: Array,
	volume: float,
	category: String = ""
) -> void:

	if not audio_enabled:
		return

	if player == null:
		return

	if arr.is_empty():
		return

	var valid : Array = []

	for s in arr:
		if s != null:
			valid.append(s)

	if valid.is_empty():
		return

	if category != "":
		var am := get_node_or_null("/root/AudioManager")
		if is_instance_valid(am) and not am.claim_voice(category, player):
			return

	player.stream = valid.pick_random()
	player.volume_db = volume
	player.pitch_scale = randf_range(0.9, 1.1)
	player.play()

# ============================================================
# AAA: DEBUG OVERLAY
# ============================================================

func _build_debug_overlay() -> void:

	# Uses Label3D if available, otherwise skips gracefully

	var label_class := ClassDB.get_class_list()

	if not ClassDB.class_exists("Label3D"):
		return

	debug_label = ClassDB.instantiate("Label3D")

	if debug_label == null:
		return

	debug_label.set("pixel_size", 0.012)
	debug_label.set("billboard", 3)
	debug_label.set("no_depth_test", true)
	debug_label.set("position", Vector3(0, 3.6, 0))
	debug_label.set("font_size", 20)

	add_child(debug_label)

func _tick_debug_overlay(delta: float) -> void:

	debug_draw_timer -= delta

	if debug_draw_timer > 0.0:
		return

	debug_draw_timer = 0.15

	if debug_label == null:
		return

	var lines : Array = []

	if debug_show_ai_mode:
		lines.append("MODE: " + AIMode.keys()[ai_mode])

	if debug_show_target_line and is_instance_valid(target):
		lines.append("TGT: " + target_type + " @ " + str(
			snapped(global_position.distance_to(target.global_position), 0.1)
		) + "m")

	if debug_show_status:

		var status_str : String = ""

		for s in status_effects.keys():
			status_str += StatusType.keys()[s].substr(0, 3) + " "

		if status_str != "":
			lines.append("SFX: " + status_str)

		if boss_enraged:
			lines.append("!! ENRAGED !!")

		if shield_active:
			lines.append("SHIELD: " + str(snapped(shield_hp, 1)))

	debug_label.set("text", "\n".join(lines))

# ============================================================
# AAA: NETWORK SYNC
# ============================================================

func _tick_network_sync(delta: float) -> void:
	if not network_sync_enabled: return   # early exit — no timer math
	net_sync_timer -= delta

	if net_sync_timer > 0.0:
		return

	net_sync_timer = network_sync_rate

	_emit_sync_snapshot()

func _emit_sync_snapshot() -> void:

	var snapshot : Dictionary = {
		"pos": global_position,
		"vel": velocity,
		"hp": health,
		"phase": phase_current,
		"ai_mode": int(ai_mode),
		"target_id": -1,
		"status": status_effects.keys(),
		"boss_phase": boss_phase,
		"enraged": boss_enraged
	}

	if is_instance_valid(target) and target.has_method("get_instance_id"):
		snapshot["target_id"] = target.get_instance_id()

	net_last_snapshot = snapshot

	emit_signal("sync_snapshot_ready", snapshot)

func apply_sync_snapshot(snapshot: Dictionary) -> void:

	if snapshot.has("pos"):
		global_position = snapshot["pos"]

	if snapshot.has("vel"):
		velocity = snapshot["vel"]

	if snapshot.has("hp"):
		health = snapshot["hp"]

	if snapshot.has("phase"):
		phase_current = snapshot["phase"]

	if snapshot.has("ai_mode"):
		ai_mode = snapshot["ai_mode"] as AIMode

	if snapshot.has("boss_phase"):
		boss_phase = snapshot["boss_phase"]

	if snapshot.has("enraged"):
		boss_enraged = snapshot["enraged"]

func get_sync_snapshot() -> Dictionary:

	return net_last_snapshot

# ============================================================
# PUBLIC API (ORIGINAL, ALL RETAINED)
# ============================================================

func set_lane(
	points: Array,
	lane_id: int = -1
) -> void:

	lane_waypoints.clear()

	for p in points:
		lane_waypoints.append(Vector3(p))

	current_waypoint = 0

	# Only reset to lane push if no command is active
	if squad_order == SquadOrder.NONE:
		ai_mode = AIMode.LANE_PUSH

func set_ai_mode(mode: int) -> void:

	ai_mode = mode

func set_target(t: Node3D) -> void:

	target = t

func push_neighbors(arr: Array) -> void:

	neighbors_cache = arr

func push_players(arr: Array) -> void:
	_players_cache = arr

func push_turrets(arr: Array) -> void:
	_turrets_cache = arr

func get_lod() -> int:
	match lod:
		LOD.FULL:  return 0
		LOD.CHEAP: return 1
		_:         return 2


func set_lod(level: int) -> void:

	match level:

		0:
			lod = LOD.FULL
			set_physics_process(true)

		1:
			lod = LOD.CHEAP
			set_physics_process(true)

		2:
			lod = LOD.SLEEP
			set_physics_process(false)

		# REAL BUG FIX (2026-08-24): ZombieHordeManager._update_z1_lod() computes
		# a 4-band distance tier (0/1/2/3, using LOD0/1/2_DIST) and calls
		# set_lod(nlod) directly -- but this match previously had no case for
		# level 3 at all, so a Z1-active zombie beyond LOD2_DIST (350 units)
		# silently kept whatever lod/physics_process state it last had. Since
		# there's also no Z1->Z2 demotion path (a Z1 zombie only ever leaves
		# _z1_active by dying), a zombie that drifted or got left behind past
		# 350 units just kept running its last tier's full physics/AI cost
		# forever while invisible -- exactly the kind of leak the whole LOD
		# system exists to prevent. Mapped to SLEEP (physics off), matching
		# the "LOD 3 -> physics OFF (sleeping)" contract _update_z1_lod()'s
		# own header comment already describes.
		3:
			lod = LOD.SLEEP
			set_physics_process(false)

func set_mesh_near(near: bool) -> void:
	if _mesh_near == near: return
	_mesh_near = near
	var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in _body_meshes:
		if is_instance_valid(m): m.cast_shadow = shadow

func reset(pos: Vector3) -> void:

	global_position = pos

	health = max_health

	is_dead = false
	_last_health_pct = -1.0   # force bar refresh on next damage
	if is_instance_valid(health_bar_root): health_bar_root.visible = false

	target = null
	target_type = ""

	# REAL BUG FIX (2026-08-24): "zombies run to the corner of the map when
	# they spawn, not at base/player". This object pool (see
	# ZombieHordeManager._promote_to_z1) reuses the SAME zombie instance
	# across completely unrelated lives -- one life as a HiveCluster patrol
	# guard (command_patrol() sets squad_order=PATROL + patrol_points to
	# that specific hive's ring) or a player-commanded unit
	# (command_attack_position() sets squad_order=ATTACK + squad_position
	# to wherever was clicked), the next life as a fresh horde marcher after
	# _return_to_pool()/_promote_to_z1(). None of that state was ever
	# cleared here -- _tick_full()'s very first check is
	# `if squad_order != SquadOrder.NONE: ... return`, which routes a
	# "fresh" zombie straight to _tick_patrol()/_tick_attack() using
	# leftover patrol_points/squad_position from its PREVIOUS life instead
	# of marching to the CURRENT enemy_base, and those stale coordinates
	# can be anywhere on the map -- including nowhere near the base or
	# player. clear_order() already existed for this exact purpose but was
	# never called from reset(); also clears the two fields it doesn't
	# (ai_mode, patrol_points/_patrol_idx) and the march-blocker cache so a
	# recycled instance starts every new life with zero cross-life state.
	clear_order()
	ai_mode = AIMode.LANE_PUSH
	patrol_points = []
	_patrol_idx = 0
	_march_blocker = null
	_march_engaged = false

	velocity = Vector3.ZERO

	_recovery.reset_progress(pos)

	energized_timer = 0.0

	# ---- AAA state reset ----------------------------------

	phase_current = 0
	phase_transitioning = false
	phase_transition_timer = 0.0

	status_effects.clear()

	is_stunned = false
	is_frozen = false
	current_slow = 0.0

	boss_phase = 0
	boss_enraged = false

	for i in boss_phase_triggered.size():
		boss_phase_triggered[i] = false

	enrage_damage_mult = 1.0
	enrage_speed_mult = 1.0
	director_speed_mult = 1.0
	director_damage_mult = 1.0
	_aggro_timer = 0.0
	_caution_timer = 0.0
	_smooth_speed_mult = 1.0

	if elite_ability == EliteAbility.SHIELD_BURST:
		shield_hp = shield_max
		shield_active = true

	elite_ability_timer = elite_ability_cooldown

	swarm_pheromone_active = false

	# REAL BUG FIX (2026-07-25): "run animation works, then later they just
	# glide" -- _die() sets anim_tree.active = false to freeze the death pose,
	# but this pooled-instance reset() never turned it back on. A recycled
	# zombie (this object pool exists specifically so dead instances get
	# reused for new spawns instead of always instantiating fresh) kept
	# moving via normal physics/movement code but its AnimationTree stayed
	# permanently deactivated -- no locomotion animation for the rest of that
	# instance's life, ever. Also reset the blend-cache and attack-anim lock
	# so the new life starts from a clean animation state instead of
	# possibly inheriting a stale "don't touch animation" window from the
	# instance's previous death.
	if anim_tree != null: anim_tree.active = true
	_last_anim_blend = -1.0
	_attack_anim_timer = 0.0

	set_physics_process(true)

func apply_upgrade(
	stat: String,
	amount: float
) -> void:

	match stat:

		"max_health":
			max_health += amount
			health += amount

		"damage":
			damage += amount

		"move_speed":
			move_speed += amount

		"attack_cooldown":
			# REAL BUG FIX (2026-07-24): floor was 0.2s against a 2.633s real
			# attack animation -- a fully-upgraded zombie would re-fire the
			# swing 13x faster than it can play, reintroducing the exact
			# animation-cutoff bug the 2.6s base cooldown above just fixed.
			# 1.8s still lets upgrades meaningfully speed attacks up while
			# keeping most of the real swing visible.
			attack_cooldown = maxf(1.8, attack_cooldown - amount)

		# ---- AAA: Extended upgrade stats ------------------

		"armor_physical":
			armor_physical += amount

		"armor_magic":
			armor_magic += amount

		"armor_fire":
			armor_fire += amount

		"life_steal":
			life_steal_pct = clampf(life_steal_pct + amount, 0.0, 0.5)

		"shield_max":
			shield_max += amount
			if shield_active:
				shield_hp += amount

		"aggro_range":
			aggro_range += amount

		"swarm_strength":
			swarm_pheromone_strength += amount

# ============================================================
# AAA: PUBLIC STATUS API
# ============================================================

func clear_status(type: int) -> void:

	if status_effects.has(type):
		_expire_status(type)
		status_effects.erase(type)

func has_status(type: int) -> bool:

	return status_effects.has(type)

func get_status_timer(type: int) -> float:

	if status_effects.has(type):
		return status_effects[type].get("timer", 0.0)

	return 0.0

# ============================================================
# AAA: PUBLIC TIER API
# ============================================================

func set_tier(tier: int) -> void:

	zombie_tier = tier as ZombieTier

	match zombie_tier:

		ZombieTier.ELITE:
			is_elite = true
			gold_reward = int(gold_reward * 2.5)
			max_health *= 1.8
			health = max_health
			damage *= 1.5

		ZombieTier.BOSS:
			is_boss = true
			gold_reward = int(gold_reward * 6.0)
			max_health *= 4.0
			health = max_health
			damage *= 2.2
			armor_physical = 20.0
			armor_magic = 15.0
			# BUG FOUND + FIXED (2026-08-28): add_to_group("boss_units") in
			# _ready() only fires if is_boss was ALREADY true at _ready()
			# time -- but set_tier(BOSS) is (and, per the fixed
			# _spawn_boss_unit() in game_phase_script.gd, now actually IS)
			# called AFTER the unit is added to the tree, so is_boss was
			# always false during _ready() for a real spawned boss. No
			# current code reads "boss_units" (checked via a full-project
			# search), so this had zero observed gameplay effect yet, but
			# it's the correct fix regardless of caller timing -- do it
			# here, not in _ready(), so it holds no matter when set_tier()
			# is called relative to the tree.
			if not is_in_group("boss_units"):
				add_to_group("boss_units")

		ZombieTier.PHASE:
			is_phase_zombie = true
			gold_reward = int(gold_reward * 3.5)
			max_health *= 2.2
			health = max_health
			_init_phase_system()
# ============================================================
# AAA: BOSS VARIANT API
# ============================================================

## Applies a real, distinct archetype on top of an already-BOSS-tiered
## unit: different stat leans (not just cosmetic) and a different real
## reactive stimulus pattern in _brain_tick() below. Call AFTER
## set_tier(ZombieTier.BOSS).
func set_boss_variant(variant: int) -> void:
	boss_variant = variant as BossVariant
	if BOSS_VARIANT_TINT.has(boss_variant) and not _body_meshes.is_empty():
		HorrorTheme.apply_sickly_tint(_body_meshes, BOSS_VARIANT_TINT[boss_variant], 0.6)
	match boss_variant:
		BossVariant.DEMON:
			# aggressive brute: hits harder, less armor -- a real glass-cannon
			# lean, not just a bigger number across the board
			damage *= 1.25
			armor_physical = maxf(0.0, armor_physical - 8.0)
			move_speed *= 1.15
		BossVariant.ORC_TROLL:
			# tank: more HP/armor, slower, enrages more readily (lower
			# threshold) -- a real behavioral shift, reacts to taking
			# damage sooner than the other variants
			max_health *= 1.3
			health = max_health
			armor_physical += 10.0
			move_speed *= 0.85
			boss_enrage_threshold = 0.4
		BossVariant.MAW:
			# caster archetype: keeps range, less melee damage, more magic
			# armor -- real environmental reactivity added in _brain_tick()
			# (backs off when a target closes in, rather than always
			# closing distance like every other variant)
			damage *= 0.8
			armor_magic += 15.0
		BossVariant.MUSHROOM:
			# area-effect archetype: real Caution suppression -- reacts to
			# being surrounded by pressing forward instead of backing off,
			# reflecting a spore-cloud creature that wants enemies close
			armor_physical += 5.0
			max_health *= 1.15
			health = max_health

# ============================================================
# CLEAR UNREACHABLE TARGET
# ============================================================

func _clear_unreachable_target() -> void:

	if is_instance_valid(target):
		_unreachable_blacklist[target.get_instance_id()] = 4.0

	unreachable_timer = 0.0
	target_progress_timer = 0.0
	last_target_distance = INF

	target = null
	target_type = ""

	_reach_cache.clear()

	ai_mode = AIMode.LANE_PUSH

# ============================================================
# REACHABILITY CHECK (CACHED)
# ============================================================

var _reach_cache : Dictionary = {}
var _reach_check_t : float = 0.0

func _can_reach_position(pos: Vector3) -> bool:

	_reach_check_t += get_physics_process_delta_time()

	if _reach_check_t < 1.5:
		return true

	_reach_check_t = 0.0

	var key := str(
		snapped(pos.x, 1.0)
	) + ":" + str(
		snapped(pos.z, 1.0)
	)

	if _reach_cache.has(key):
		return _reach_cache[key]

	var nav_map : RID = get_world_3d().navigation_map

	if nav_map == RID():
		return true

	var path := NavigationServer3D.map_get_path(
		nav_map,
		global_position,
		pos,
		true
	)

	var reachable : bool = path.size() > 1

	_reach_cache[key] = reachable

	return reachable
# ============================================================
# SIGNALS
# ============================================================

signal zombie_died(zombie)
signal phase_started(phase_index)
signal phase_completed(phase_index)
signal boss_phase_started(phase_index)

signal sync_snapshot_ready(snapshot)
func convert_team() -> void:
	team_id = 2 if team_id == 1 else 1
	# _find_bases() now early-returns if both are already valid (see its
	# own comment) -- null them first so flipping team actually re-derives
	# both instead of keeping the pre-flip assignments.
	enemy_base = null
	friendly_base = null
	_find_bases()

	target = null
	target_type = ""
	_unreachable_blacklist.clear()
	_reach_cache.clear()
	unreachable_timer = 0.0
	last_target_distance = INF

	status_effects.clear()
	active_dots.clear()
	is_stunned = false
	is_frozen = false
	current_slow = 0.0

	# ── stat penalty on conversion ───────────────────────────
	damage      *= 0.55
	move_speed  *= 0.80
	# REAL BUG FIX (2026-07-24): this cap (2.5) predated the base cooldown
	# being raised to 2.6 for the animation-length fix above -- capping
	# BELOW the new base would have made this "40% slower" conversion
	# penalty actually speed the zombie's attacks up. Raised proportionally
	# to the new base so the intended penalty still holds.
	attack_cooldown = minf(attack_cooldown * 1.4, 4.0)
	max_health  *= 0.70
	health       = max_health * conversion_health_pct

	# ── grow back to full strength over time ─────────────────
	var tween := create_tween().set_parallel(true)
	tween.tween_method(
		func(v: float): damage = v,
		damage, damage / 0.55, 18.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_method(
		func(v: float): move_speed = v,
		move_speed, move_speed / 0.80, 18.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_method(
		func(v: float): attack_cooldown = v,
		attack_cooldown, attack_cooldown / 1.4, 18.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_method(
		func(v: float): max_health = v; health = minf(health, max_health),
		max_health, max_health / 0.70, 18.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	is_dead = false
	_last_health_pct = -1.0
	ai_mode = AIMode.LANE_PUSH
	set_physics_process(true)

	if is_instance_valid(health_bar_root):
		health_bar_root.visible = true

	emit_signal("zombie_died", self)
	print("[CONVERT] team %d | weak → ramping over 18s" % team_id)
