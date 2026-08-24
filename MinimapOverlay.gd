# MinimapOverlay.gd
# Top-down mode minimap — renders active enemy density heat-dots every 0.5 s.
# Created by player.gd as a CanvasLayer child; visible only in topdown mode.
# Call show_for(player_node) on enter and hide_map() on exit.
extends CanvasLayer

const MAP_RADIUS   : float = 150.0   # world units from player to minimap edge
const MAP_SIZE     : float = 200.0   # pixel side length of the minimap square
const MAP_MARGIN   : float = 16.0    # distance from screen edge in pixels
const REFRESH_RATE : float = 0.5     # seconds between enemy position samples
const SAMPLE_MAX   : int   = 512     # max crowd positions sampled per refresh

# World-space cell size for cluster binning.  Enemies within CLUSTER_CELL units
# of each other collapse into a single heat-dot sized by their count.
const CLUSTER_CELL : float = 12.0

const COL_Z1     : Color = Color(1.00, 0.18, 0.18, 0.90)
const COL_Z2     : Color = Color(1.00, 0.55, 0.10, 0.65)
const COL_PLAYER : Color = Color(0.25, 1.00, 0.40, 1.00)
const COL_BG     : Color = Color(0.05, 0.05, 0.08, 0.70)
const COL_BORDER : Color = Color(0.30, 0.30, 0.40, 0.85)
const COL_RING   : Color = Color(0.25, 0.25, 0.35, 0.35)

# Ability-cooldown ring drawn around the player icon — one arc per class slot.
const RING_R   : float = 10.0   # px radius from player icon centre
const RING_W   : float = 2.5    # px stroke width
const RING_GAP : float = 0.14   # total radian gap at each slot boundary (~8°)
const RING_COLS : Array = [
	Color(1.00, 0.55, 0.10, 1.0),   # slot 0 — orange
	Color(0.20, 0.60, 1.00, 1.0),   # slot 1 — blue
	Color(0.30, 1.00, 0.40, 1.0),   # slot 2 — green
	Color(0.90, 0.20, 0.90, 1.0),   # slot 3 — magenta
]

var _player  : Node3D  = null
var _canvas  : Control = null
var _timer   : Timer   = null
var _ppos    : Vector3 = Vector3.ZERO

# Each entry: [map_px: Vector2, count: int, has_z1: bool]
# Populated by update_enemy_clusters(), consumed by _on_map_draw().
var _clusters : Array = []


func _ready() -> void:
	layer   = 120
	visible = false

	_canvas = Control.new()
	_canvas.name         = "MinimapDraw"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_canvas.offset_left   = -(MAP_MARGIN + MAP_SIZE)
	_canvas.offset_top    = -(MAP_MARGIN + MAP_SIZE)
	_canvas.offset_right  = -MAP_MARGIN
	_canvas.offset_bottom = -MAP_MARGIN
	_canvas.draw.connect(_on_map_draw)
	add_child(_canvas)

	_timer = Timer.new()
	_timer.name       = "RefreshTimer"
	_timer.wait_time  = REFRESH_RATE
	_timer.one_shot   = false
	_timer.autostart  = false
	_timer.timeout.connect(update_enemy_clusters)
	add_child(_timer)


func show_for(player: Node3D) -> void:
	_player = player
	visible = true
	update_enemy_clusters()   # immediate first sample
	_timer.start()


func hide_map() -> void:
	_timer.stop()
	visible = false
	_player = null


func _process(_delta: float) -> void:
	if not visible or not is_instance_valid(_player): return
	_canvas.queue_redraw()


# Public — also called by the 0.5-second Timer.timeout signal.
# Bins every live enemy into a CLUSTER_CELL grid so the draw pass
# renders one heat-dot per occupied cell, not one dot per zombie.
func update_enemy_clusters() -> void:
	if not is_instance_valid(_player): return
	_ppos = _player.global_position
	_clusters.clear()

	var zhm : Node = get_tree().root.get_node_or_null("ZombieHordeManager")
	if not is_instance_valid(zhm): return

	# grid key: Vector2i cell → [accum_pos: Vector3, count: int, has_z1: bool]
	var grid : Dictionary = {}

	for z in zhm._z1_active:
		if not is_instance_valid(z): continue
		var wp   : Vector3  = (z as Node3D).global_position
		var cell : Vector2i = _world_to_cell(wp)
		if grid.has(cell):
			var e : Array = grid[cell]
			e[0] = (e[0] as Vector3) + wp
			e[1] = (e[1] as int) + 1
			e[2] = true
		else:
			grid[cell] = [wp, 1, true]

	var crowd : PackedVector3Array = zhm.get_crowd_positions(SAMPLE_MAX)
	for i in range(crowd.size()):
		var wp   : Vector3  = crowd[i]
		var cell : Vector2i = _world_to_cell(wp)
		if grid.has(cell):
			var e : Array = grid[cell]
			e[0] = (e[0] as Vector3) + wp
			e[1] = (e[1] as int) + 1
		else:
			grid[cell] = [wp, 1, false]

	for cell in grid:
		var e     : Array   = grid[cell]
		var cnt   : int     = e[1] as int
		var avg   : Vector3 = (e[0] as Vector3) / float(cnt)
		var is_z1 : bool    = e[2] as bool
		_clusters.append([_world_to_map(avg), cnt, is_z1])


# Draws four arc segments around the player icon, one per class ability slot.
# Each arc sweeps 82° of its 90° quadrant (gap of ~8° at each boundary).
# The bright foreground arc fills proportionally as the cooldown expires;
# a dim background arc shows the full slot extent while it is recharging.
func _draw_ability_rings(center: Vector2) -> void:
	var cds  : Array = _player.get("_class_cooldowns")
	var maxs : Array = _player.get("_class_cd_max")
	if cds == null or maxs == null or cds.size() < 4 or maxs.size() < 4:
		return
	var span : float = PI * 0.5 - RING_GAP
	for i in range(4):
		var a0  : float = -PI * 0.5 + float(i) * PI * 0.5 + RING_GAP * 0.5
		var col : Color = RING_COLS[i]
		var dim : Color = Color(col.r, col.g, col.b, 0.22)
		_canvas.draw_arc(center, RING_R, a0, a0 + span, 12, dim, RING_W)
		var cd   : float = float(cds[i])
		var mx   : float = float(maxs[i])
		var frac : float = 1.0 if mx <= 0.0 else 1.0 - clampf(cd / mx, 0.0, 1.0)
		if frac > 0.001:
			_canvas.draw_arc(center, RING_R, a0, a0 + frac * span,
			                 maxi(2, int(frac * 12.0)), col, RING_W)


func _world_to_cell(wp: Vector3) -> Vector2i:
	return Vector2i(int(floor((wp.x - _ppos.x) / CLUSTER_CELL)),
	                int(floor((wp.z - _ppos.z) / CLUSTER_CELL)))


func _world_to_map(wp: Vector3) -> Vector2:
	var half  : float = MAP_SIZE * 0.5
	var scale : float = half / MAP_RADIUS
	return Vector2(half + (wp.x - _ppos.x) * scale,
	               half + (wp.z - _ppos.z) * scale)


func _on_map_draw() -> void:
	var half : float = MAP_SIZE * 0.5
	var full : Rect2 = Rect2(0.0, 0.0, MAP_SIZE, MAP_SIZE)

	_canvas.draw_rect(full, COL_BG)
	_canvas.draw_arc(Vector2(half, half), half * 0.6, 0.0, TAU, 32, COL_RING, 1.0)

	for i in range(_clusters.size()):
		var entry : Array   = _clusters[i]
		var mp    : Vector2 = entry[0] as Vector2
		if mp.x < 0.0 or mp.x > MAP_SIZE or mp.y < 0.0 or mp.y > MAP_SIZE:
			continue
		var cnt   : int   = entry[1] as int
		var is_z1 : bool  = entry[2] as bool
		# Dot radius grows with sqrt(count) to show relative density.
		var r     : float = clampf(sqrt(float(cnt)) * 1.8, 2.0, 10.0)
		# Alpha ramps from 40 % at count=1 to 100 % at count>=20.
		var t     : float = clampf(float(cnt) / 20.0, 0.0, 1.0)
		var base  : Color = COL_Z1 if is_z1 else COL_Z2
		var col   : Color = Color(base.r, base.g, base.b,
		                          lerpf(base.a * 0.4, base.a, t))
		_canvas.draw_circle(mp, r, col)

	_canvas.draw_circle(Vector2(half, half), 5.0, COL_PLAYER)
	if is_instance_valid(_player):
		var fwd : Vector3 = -(_player.global_transform.basis.z)
		_canvas.draw_line(
			Vector2(half, half),
			Vector2(half + fwd.x * 10.0, half + fwd.z * 10.0),
			COL_PLAYER, 1.5)
		_draw_ability_rings(Vector2(half, half))
	_canvas.draw_rect(full, COL_BORDER, false, 1.5)
