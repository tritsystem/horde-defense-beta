# ============================================================
# CreepOverlay.gd — AUTOLOAD
# ============================================================
# Draws health bars and energy icons for ALL active Zone-1 zombies
# in a single Control._draw() pass.  Replaces the per-zombie
# MeshInstance3D billboard nodes (energy icon + health bar tray)
# with one CanvasItem, so GPU overhead is O(1) regardless of
# horde size.
#
# Reads from each zombie:
#   hud_hp_visible_timer : float  — seconds until HP bar hides
#   health               : float
#   max_health           : float
#   energized_timer      : float  — >0 while energized
#   team_id              : int
#
# Depth-sorting (far-to-near) ensures nearer zombies draw on top.
# ============================================================
extends CanvasLayer

var _draw_node : Control  = null
var _cam       : Camera3D = null
var _zhm       : Node     = null

# Visual constants
const BAR_W   : float = 38.0
const BAR_H   : float = 4.0
const ICON_R  : float = 4.5
const HEAD_Y  : float = 2.4   # world units above zombie origin
const CULL_PAD: float = 60.0  # px beyond viewport edge before culling


func _ready() -> void:
	layer = 5   # below HUD (10), above 3D

	_draw_node              = Control.new()
	_draw_node.name         = "CreepSpriteBatch"
	_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	# y_sort_enabled on a Node2D/Control sorts children; since we draw everything
	# in one _draw() pass there are no children to sort — we sort the zombie array
	# ourselves below (painter's algorithm, far-to-near).
	_draw_node.draw.connect(_on_draw)
	add_child(_draw_node)


func _process(_delta: float) -> void:
	_cam = get_viewport().get_camera_3d()
	if not is_instance_valid(_zhm):
		_zhm = get_node_or_null("/root/ZombieHordeManager")
	_draw_node.queue_redraw()


func _on_draw() -> void:
	if not is_instance_valid(_zhm) or not is_instance_valid(_cam):
		return

	var vp_size : Vector2 = get_viewport().get_visible_rect().size
	var cam_pos : Vector3 = _cam.global_position

	# Collect visible zombies and sort far-to-near (painter's algorithm).
	var zombies : Array = []
	for z in _zhm._z1_active:
		if is_instance_valid(z):
			zombies.append(z)

	zombies.sort_custom(func(a: Node, b: Node) -> bool:
		return cam_pos.distance_squared_to((a as Node3D).global_position) \
			 > cam_pos.distance_squared_to((b as Node3D).global_position))

	for z in zombies:
		_draw_zombie(z, vp_size)


func _draw_zombie(z: Node, vp_size: Vector2) -> void:
	var z3d    := z as Node3D
	var head   := z3d.global_position + Vector3(0.0, HEAD_Y, 0.0)

	# Cull anything behind the camera (positive local-Z = behind in Godot).
	var local := _cam.global_transform.affine_inverse() * head
	if local.z > 0.0:
		return

	var sp : Vector2 = _cam.unproject_position(head)
	if sp.x < -CULL_PAD or sp.x > vp_size.x + CULL_PAD \
	or sp.y < -CULL_PAD or sp.y > vp_size.y + CULL_PAD:
		return

	var show_hp : bool = "hud_hp_visible_timer" in z \
		and float(z.get("hud_hp_visible_timer")) > 0.0

	# ── Health bar ───────────────────────────────────────────────
	if show_hp:
		var hp    : float = float(z.get("health")     if "health"     in z else 0.0)
		var mxhp  : float = maxf(float(z.get("max_health") if "max_health" in z else 1.0), 1.0)
		var ratio : float = clampf(hp / mxhp, 0.0, 1.0)
		var bx    : float = sp.x - BAR_W * 0.5
		var by    : float = sp.y

		# Dark border tray
		_draw_node.draw_rect(Rect2(bx - 1.0, by - 1.0, BAR_W + 2.0, BAR_H + 2.0),
			Color(0.06, 0.06, 0.06, 0.84))
		# Coloured fill (green→red as health falls)
		_draw_node.draw_rect(Rect2(bx, by, BAR_W * ratio, BAR_H),
			Color(1.0 - ratio, ratio * 0.88, 0.10))

	# ── Energy icon ──────────────────────────────────────────────
	var en : float = float(z.get("energized_timer") if "energized_timer" in z else 0.0)
	if en > 0.0:
		var tid  : int   = int(z.get("team_id") if "team_id" in z else 1)
		var ecol : Color = Color(1.0, 0.20, 0.20, 0.9) if tid == 2 \
			else Color(0.30, 0.85, 1.0, 0.85)
		# Subtle pulse without per-zombie State: use time modulated by zombie UID
		var phase : float = float(z.get_instance_id() % 37) * 0.27
		ecol.a   *= 0.65 + sin(Time.get_ticks_msec() * 0.006 + phase) * 0.35
		# Place icon to the right of the bar (or centred if no bar showing)
		var ix : float = sp.x + (BAR_W * 0.5 + ICON_R + 2.0 if show_hp else 0.0)
		var iy : float = sp.y + BAR_H * 0.5
		_draw_node.draw_circle(Vector2(ix, iy), ICON_R, ecol)
