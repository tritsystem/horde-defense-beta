# ============================================================
# DebugTuningPanel.gd  — AUTOLOAD (CanvasLayer)
# Live balance tuning for playtesting. Toggle with F9.
# Changes apply immediately to existing live instances AND are
# stored as overrides that newly-spawned turrets / zombies read.
# ============================================================
extends CanvasLayer

## Read by baseturret._base_ready() for each new turret placed.
var turret_hp_override     : float = 13500.0
## Read by zombie._ready() for each new zombie that enters Zone 1.
## NOTE: zombie._ready() ALWAYS applies this (the panel is an autoload), so this
## default is the real early-game zombie damage, not the @export in zombie.gd.
var zombie_damage_override : float = 9.0

# ── knob definitions ─────────────────────────────────────────
const _KNOBS : Array = [
	{label="Turret Max HP",       min=500.0,  max=50000.0, step=100.0, default=13500.0, fmt="%.0f"},
	{label="Zombie Damage",       min=1.0,    max=150.0,   step=1.0,   default=9.0,     fmt="%.0f"},
	{label="Director Difficulty", min=0.25,   max=4.0,     step=0.05,  default=1.0,     fmt="%.2f×"},
]

var _val_labels : Array[Label] = []

var _render_stats_lbl : Label = null
var _render_t         : float = 0.0
const _RENDER_HZ      : float = 4.0   # update 4× per second

func _ready() -> void:
	layer   = 128
	visible = false
	_build_ui()

func _process(delta: float) -> void:
	if not visible or not is_instance_valid(_render_stats_lbl): return
	_render_t += delta
	if _render_t < 1.0 / _RENDER_HZ: return
	_render_t = 0.0
	_update_render_stats()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F9:
			visible = not visible
			get_viewport().set_input_as_handled()

# ── UI builder ───────────────────────────────────────────────
func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	panel.custom_minimum_size = Vector2(360, 0)
	var style := StyleBoxFlat.new()
	style.bg_color              = Color(0.05, 0.05, 0.05, 0.82)
	style.border_color          = Color(0.8, 0.7, 0.2)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left   = 10
	style.content_margin_right  = 10
	style.content_margin_top    = 8
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "  DEBUG TUNING  (F9 to toggle)"
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.25))
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	for i in _KNOBS.size():
		var k    : Dictionary = _KNOBS[i]
		var row  := HBoxContainer.new()
		vbox.add_child(row)

		var name_lbl := Label.new()
		name_lbl.text = k.label
		name_lbl.custom_minimum_size = Vector2(168, 0)
		name_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
		row.add_child(name_lbl)

		var slider := HSlider.new()
		slider.min_value = k.min
		slider.max_value = k.max
		slider.step      = k.step
		slider.value     = k.default
		slider.custom_minimum_size = Vector2(110, 0)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(slider)

		var val_lbl := Label.new()
		val_lbl.text = k.fmt % k.default
		val_lbl.custom_minimum_size = Vector2(72, 0)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
		row.add_child(val_lbl)
		_val_labels.append(val_lbl)

		var idx := i
		slider.value_changed.connect(func(v: float) -> void: _on_knob_changed(idx, v))

	# ── Render stats section ─────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var rs_title := Label.new()
	rs_title.text = "  RENDER STATS"
	rs_title.add_theme_color_override("font_color", Color(0.4, 0.88, 1.0))
	vbox.add_child(rs_title)
	_render_stats_lbl = Label.new()
	_render_stats_lbl.add_theme_font_size_override("font_size", 10)
	_render_stats_lbl.add_theme_color_override("font_color", Color(0.82, 0.88, 0.82))
	_render_stats_lbl.text = "waiting..."
	vbox.add_child(_render_stats_lbl)

# ── Render stats helpers ─────────────────────────────────────
func _update_render_stats() -> void:
	var zhm = get_node_or_null("/root/ZombieHordeManager")

	var z1 : int = 0; var z2 : int = 0; var z3 : int = 0
	var z1_max : int = 40   # mirrors ZONE1_MAX in ZombieHordeManager
	if is_instance_valid(zhm):
		if zhm.has_method("z1_count"): z1 = zhm.call("z1_count")
		if zhm.has_method("z2_count"): z2 = zhm.call("z2_count")
		if zhm.has_method("z3_count"): z3 = zhm.call("z3_count")

	var fps : float = Engine.get_frames_per_second()
	var ms  : float = 1000.0 / maxf(fps, 0.001)

	# 9 mesh surfaces per Z1 zombie (55,686 verts measured, 9 surfaces confirmed).
	# Z2 multimesh is a single draw call regardless of crowd size.
	var est_z_dc : int = z1 * 9 + (1 if z2 > 0 else 0)

	var total_dc   : int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var total_tris : int = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var vram_mb : float = float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0

	var z_share : float = 100.0 * float(est_z_dc) / maxf(float(total_dc), 1.0)

	_render_stats_lbl.text = (
		"FPS: %d  (%.1f ms)\n" % [int(fps), ms] +
		"Z1 skinned: %d/%d  → %d DC est.\n" % [z1, z1_max, est_z_dc] +
		"  verts: ~%s\n" % _fmt_k(z1 * 55686) +
		"Z2 multimesh: %d  (1 DC)\n" % z2 +
		"Z3 dormant:   %d  (0 GPU)\n" % z3 +
		"GPU DCs total: %d  (%.0f%% zombie)\n" % [total_dc, z_share] +
		"Triangles: %s\n" % _fmt_k(total_tris) +
		"VRAM: %.1f MB" % vram_mb
	)


func _fmt_k(n: int) -> String:
	if n >= 1_000_000: return "%.2fM" % (float(n) / 1_000_000.0)
	if n >= 1_000:     return "%.1fK" % (float(n) / 1_000.0)
	return str(n)


func _on_knob_changed(idx: int, value: float) -> void:
	_val_labels[idx].text = _KNOBS[idx].fmt % value
	match idx:
		0:  # Turret Max HP
			turret_hp_override = value
			for t in get_tree().get_nodes_in_group("turrets"):
				if "max_health" in t and "health" in t:
					t.max_health = value
					t.health     = value
					if t.has_signal("health_changed"):
						t.health_changed.emit(t.health, t.max_health)
		1:  # Zombie Damage
			zombie_damage_override = value
			for z in get_tree().get_nodes_in_group("zombies"):
				if "damage" in z:
					z.damage = value
		2:  # Director Difficulty
			ZombieHordeManager.director_difficulty = value
