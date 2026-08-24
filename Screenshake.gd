# ============================================================
# ScreenShake.gd — Autoload
# ScreenShake.shake(intensity, duration, frequency)
# ============================================================
extends Node

var _camera      : Camera3D = null
var _intensity   : float    = 0.0
var _duration    : float    = 0.0
var _frequency   : float    = 15.0
var _timer       : float    = 0.0
var _origin      : Vector3  = Vector3.ZERO
var _noise_t     : float    = 0.0

func _ready() -> void:
	add_to_group("screen_shake")
	set_process(false)

func bind_camera(cam: Camera3D) -> void:
	_camera = cam
	_origin = cam.position

func shake(intensity: float = 0.5, duration: float = 0.3, frequency: float = 15.0) -> void:
	_intensity = intensity
	_duration  = duration
	_frequency = frequency
	_timer     = duration
	_noise_t   = 0.0
	if is_instance_valid(_camera): _origin = _camera.position
	set_process(true)

# Preset shakes
func explosion()    -> void: shake(0.8, 0.45, 12.0)
func hit()          -> void: shake(0.25, 0.12, 20.0)
func land()         -> void: shake(0.18, 0.10, 18.0)
func sword_hit()    -> void: shake(0.35, 0.18, 16.0)
func base_hit()     -> void: shake(1.2, 0.6, 8.0)
func gun_shot()     -> void: shake(0.08, 0.06, 22.0)
func death_impulse() -> void: shake(0.6, 0.12, 24.0)
func enemy_death(max_hp: float) -> void:
	shake(clampf(max_hp / 1000.0 * 0.3, 0.08, 0.40), 0.15, 20.0)

func _process(delta: float) -> void:
	if not is_instance_valid(_camera): set_process(false); return
	_timer   -= delta
	_noise_t += delta * _frequency
	if _timer <= 0.0:
		_camera.position = _origin
		set_process(false)
		return
	var fade   : float = _timer / _duration
	var offset : Vector3 = Vector3(
		_pseudo_noise(_noise_t)        * _intensity * fade,
		_pseudo_noise(_noise_t + 31.7) * _intensity * fade * 0.6,
		0.0)
	_camera.position = _origin + offset

func _pseudo_noise(t: float) -> float:
	return sin(t * 7.3) * 0.5 + sin(t * 13.7) * 0.3 + sin(t * 23.1) * 0.2
