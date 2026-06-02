# ============================================================
# GamepadUINavigator.gd
# ============================================================
# Autoload. Converts left-stick / d-pad held input into
# repeating ui_up / ui_down / ui_left / ui_right actions so
# controllers can navigate any UI (menus, shops, HUD buttons).
#
# Add to AutoLoad in Project Settings:
#   Name: GamepadUINavigator
#   Path: res://scripts/GamepadUINavigator.gd
#
# Works alongside SplitScreenManager: each gamepad device only
# fires UI events into its owner's SubViewport via SSM.
# ============================================================
extends Node

# ── TUNING ───────────────────────────────────────────────────
## Stick must exceed this to start navigating (avoids drift)
const DEADZONE          : float = 0.35
## Seconds before the first repeat fires after initial press
const INITIAL_DELAY     : float = 0.40
## Seconds between repeats while held
const REPEAT_INTERVAL   : float = 0.12
## Axis indices (standard mapping)
const AXIS_LEFT_X       : int   = JOY_AXIS_LEFT_X
const AXIS_LEFT_Y       : int   = JOY_AXIS_LEFT_Y

# ── INTERNAL ─────────────────────────────────────────────────
# Per-device state  device_id → { dir: Vector2, timer: float, fired_initial: bool }
var _device_state : Dictionary = {}

# Which viewports each device maps to — populated by SSM on spawn
# device_id → SubViewport
var _device_viewport : Dictionary = {}

# Track whether UI nav mode is active per device
# Only navigate when the owning player's UI is open
var _ui_active : Dictionary = {}   # device_id → bool


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("gamepad_ui_navigator")


# ── PUBLIC API ────────────────────────────────────────────────

## Call from SplitScreenManager after players spawn.
## device: the joystick device id (-1 = KBM, ignored here)
## vp: the SubViewport owned by this player
func register_device(device: int, vp: SubViewport) -> void:
	if device < 0: return   # KBM uses real mouse/keyboard, no nav needed
	_device_viewport[device] = vp
	_device_state[device]    = { "dir": Vector2.ZERO, "timer": 0.0, "fired_initial": false }
	_ui_active[device]       = false
	print("[GamepadNav] registered device %d → %s" % [device, vp.name if is_instance_valid(vp) else "NULL"])


## Enable / disable UI navigation for a device.
## Call when a player opens or closes a UI panel (shop, pause, etc).
func set_ui_active(device: int, active: bool) -> void:
	_ui_active[device] = active


## Convenience: activate all registered devices (e.g. pause menu open)
func set_all_ui_active(active: bool) -> void:
	for device in _device_viewport:
		_ui_active[device] = active


# ── PROCESS ──────────────────────────────────────────────────
func _process(delta: float) -> void:
	for device in _device_viewport.keys():
		_tick_device(device, delta)


func _tick_device(device: int, delta: float) -> void:
	if not _ui_active.get(device, false): return
	var vp := _device_viewport.get(device) as SubViewport
	if not is_instance_valid(vp): return

	# Read stick + d-pad, combine
	var stick := Vector2(
		Input.get_joy_axis(device, AXIS_LEFT_X),
		Input.get_joy_axis(device, AXIS_LEFT_Y)
	)
	var dpad := Vector2(
		(1.0 if Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_RIGHT) else 0.0) -
		(1.0 if Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_LEFT)  else 0.0),
		(1.0 if Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_DOWN)  else 0.0) -
		(1.0 if Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_UP)    else 0.0)
	)
	# D-pad always wins over stick when pressed
	var combined := dpad if dpad.length() > 0.1 else stick

	var state : Dictionary = _device_state[device]

	if combined.length() < DEADZONE:
		# Released — reset
		state["dir"]           = Vector2.ZERO
		state["timer"]         = 0.0
		state["fired_initial"] = false
		return

	# Snap to 4-way
	var nav_dir := _snap_to_4way(combined)

	if nav_dir != state["dir"]:
		# Direction changed — reset and fire immediately
		state["dir"]           = nav_dir
		state["timer"]         = 0.0
		state["fired_initial"] = false
		_fire_nav(device, vp, nav_dir)
		state["timer"] = INITIAL_DELAY
		return

	# Same direction held — wait for repeat
	state["timer"] -= delta
	if state["timer"] <= 0.0:
		if not state["fired_initial"]:
			state["fired_initial"] = true
			state["timer"]         = INITIAL_DELAY
		else:
			state["timer"] = REPEAT_INTERVAL
		_fire_nav(device, vp, nav_dir)


func _snap_to_4way(v: Vector2) -> Vector2:
	if absf(v.x) >= absf(v.y):
		return Vector2(signf(v.x), 0.0)
	else:
		return Vector2(0.0, signf(v.y))


func _fire_nav(device: int, vp: SubViewport, dir: Vector2) -> void:
	var action : String
	if   dir == Vector2.UP:    action = "ui_up"
	elif dir == Vector2.DOWN:  action = "ui_down"
	elif dir == Vector2.LEFT:  action = "ui_left"
	elif dir == Vector2.RIGHT: action = "ui_right"
	else: return

	# Build a synthetic action event tagged to this device
	var ev              := InputEventAction.new()
	ev.action           = action
	ev.pressed          = true
	ev.strength         = 1.0
	# device field doesn't exist on InputEventAction in GDScript,
	# so we push directly into the viewport — it's already isolated
	vp.push_input(ev)

	# Also fire the release so Focus doesn't get "stuck pressed"
	var ev_rel          := InputEventAction.new()
	ev_rel.action       = action
	ev_rel.pressed      = false
	ev_rel.strength     = 0.0
	vp.push_input(ev_rel)


# ── CONFIRM / CANCEL via face buttons ────────────────────────
# We handle these here too so controllers can press buttons in UI.
func _input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton): return
	var btn    := event as InputEventJoypadButton
	var device := btn.device
	if not _ui_active.get(device, false): return
	var vp := _device_viewport.get(device) as SubViewport
	if not is_instance_valid(vp): return

	# South button (A/Cross) = ui_accept, East (B/Circle) = ui_cancel
	var action : String = ""
	match btn.button_index:
		JOY_BUTTON_A: action = "ui_accept"
		JOY_BUTTON_B: action = "ui_cancel"
		_: return

	var ev          := InputEventAction.new()
	ev.action       = action
	ev.pressed      = btn.pressed
	ev.strength     = 1.0 if btn.pressed else 0.0
	vp.push_input(ev)
	get_viewport().set_input_as_handled()
