# ============================================================
# FogShrinkManager.gd — AUTOLOAD
# ============================================================
# Battle-royale-style fog that shrinks over time, dealing
# damage to players outside the safe zone ring.
#
# Register as Autoload: FogShrinkManager
# ============================================================
extends Node

signal ring_shrunk(new_radius: float)
signal player_in_fog(player: Node)

const SHRINK_PHASES : Array = [
	{"start_radius": 120.0, "end_radius": 80.0,  "duration": 120.0, "damage_ps": 5.0,  "delay": 180.0},
	{"start_radius": 80.0,  "end_radius": 50.0,  "duration": 90.0,  "damage_ps": 10.0, "delay": 0.0},
	{"start_radius": 50.0,  "end_radius": 25.0,  "duration": 60.0,  "damage_ps": 18.0, "delay": 0.0},
	{"start_radius": 25.0,  "end_radius": 10.0,  "duration": 45.0,  "damage_ps": 30.0, "delay": 0.0},
]

var _active        : bool  = false
var _phase_idx     : int   = 0
var _phase_timer   : float = 0.0
var _phase_state   : String = "waiting"  # waiting / shrinking
var _safe_radius   : float = 120.0
var _center        : Vector3 = Vector3.ZERO
var _damage_accum  : float = 0.0
var _fog_announce  : bool  = false


func _ready() -> void:
	add_to_group("fog_shrink_manager")
	set_process(false)


func start(center: Vector3 = Vector3.ZERO) -> void:
	_center      = center
	_active      = true
	_phase_idx   = 0
	_phase_timer = SHRINK_PHASES[0]["delay"]
	_phase_state = "waiting"
	_safe_radius = SHRINK_PHASES[0]["start_radius"]
	set_process(true)
	_announce("🌫 The fog is closing in…", Color(0.6, 0.7, 1.0))


func stop() -> void:
	_active = false
	set_process(false)


func get_safe_radius() -> float:
	return _safe_radius


func _process(delta: float) -> void:
	if not _active or _phase_idx >= SHRINK_PHASES.size(): return
	var phase : Dictionary = SHRINK_PHASES[_phase_idx]
	_phase_timer -= delta

	match _phase_state:
		"waiting":
			if _phase_timer <= 0.0:
				_phase_state  = "shrinking"
				_phase_timer  = phase["duration"]
				_announce("⚠ Safe zone shrinking! Get inside!", Color(0.9, 0.7, 0.2))
		"shrinking":
			var t      := 1.0 - clampf(_phase_timer / float(phase["duration"]), 0.0, 1.0)
			_safe_radius = lerpf(phase["start_radius"], phase["end_radius"], t)
			ring_shrunk.emit(_safe_radius)

			# Damage players outside safe zone
			_damage_accum += delta
			if _damage_accum >= 0.5:
				_damage_accum = 0.0
				_tick_fog_damage(phase["damage_ps"] * 0.5)

			if _phase_timer <= 0.0:
				_safe_radius = phase["end_radius"]
				_phase_idx  += 1
				if _phase_idx < SHRINK_PHASES.size():
					_phase_timer = SHRINK_PHASES[_phase_idx]["delay"]
					_phase_state = "waiting"
				else:
					_announce("☠ The fog has fully closed!", Color(0.9, 0.2, 0.2))
					set_process(false)


func _tick_fog_damage(amount: float) -> void:
	for player in get_tree().get_nodes_in_group("players"):
		if not (player is Node3D): continue
		var dist := _center.distance_to((player as Node3D).global_position)
		if dist > _safe_radius:
			if player.has_method("take_damage"): player.take_damage(amount)
			player_in_fog.emit(player)


func _announce(text: String, col: Color) -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(text, col)
