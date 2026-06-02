# ============================================================
# KillFeed.gd — Attach to a Control node in HUD
# Call KillFeed.add_kill(killer, victim, method)
# ============================================================
extends Control

const MAX_ENTRIES  : int   = 6
const ENTRY_HEIGHT : float = 28.0
const FADE_TIME    : float = 5.0
const SLIDE_TIME   : float = 0.18

var _entries : Array = []   # Array of {panel, timer, label}

# Icon map for kill methods
const METHOD_ICONS := {
	"gun":        "🔫", "laser":   "⚡", "rocket": "💥",
	"flame":      "🔥", "sword":   "⚔",  "dragon": "🐉",
	"zombie":     "🧟", "turret":  "🗼", "fall":   "💀",
	"headshot":   "🎯", "enchant": "✦",  "default":"☠",
}
const TEAM_COLORS := {
	1: Color(0.35, 0.6, 1.0),   # team 1 — blue
	2: Color(1.0, 0.35, 0.35),  # team 2 — red
}


func _ready() -> void:
	# Top right, below minimap
	anchor_left   = 0.72; anchor_right  = 1.0
	anchor_top    = 0.23; anchor_bottom = 0.6
	offset_right  = -8.0
	mouse_filter  = Control.MOUSE_FILTER_IGNORE
	z_index       = 95
	add_to_group("kill_feed")


func _process(delta: float) -> void:
	for e in _entries.duplicate():
		e.timer -= delta
		if e.timer <= 0.0:
			_remove_entry(e)
		elif e.timer < 1.2:
			var lbl := e.panel as PanelContainer
			if is_instance_valid(lbl):
				lbl.modulate.a = e.timer / 1.2


func add_kill(killer_name: String, killer_team: int,
			  victim_name: String, victim_team: int,
			  method: String = "default") -> void:
	var icon  : String = METHOD_ICONS.get(method, METHOD_ICONS["default"])
	var k_col : Color  = TEAM_COLORS.get(killer_team, Color.WHITE)
	var v_col : Color  = TEAM_COLORS.get(victim_team, Color.GRAY)
	var panel  := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.04, 0.05, 0.07, 0.88)
	sbox.set_border_width_all(1)
	sbox.border_color = k_col.darkened(0.4)
	sbox.set_corner_radius_all(3)
	sbox.content_margin_left  = 6; sbox.content_margin_right  = 6
	sbox.content_margin_top   = 2; sbox.content_margin_bottom = 2
	panel.add_theme_stylebox_override("panel", sbox)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(hbox)
	# Killer name
	var k_lbl := Label.new()
	k_lbl.text = killer_name
	k_lbl.add_theme_font_size_override("font_size", 11)
	k_lbl.add_theme_color_override("font_color", k_col)
	k_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(k_lbl)
	# Method icon
	var i_lbl := Label.new()
	i_lbl.text = " %s " % icon
	i_lbl.add_theme_font_size_override("font_size", 12)
	i_lbl.add_theme_color_override("font_color", Color.WHITE)
	i_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(i_lbl)
	# Victim name
	var v_lbl := Label.new()
	v_lbl.text = victim_name
	v_lbl.add_theme_font_size_override("font_size", 11)
	v_lbl.add_theme_color_override("font_color", v_col)
	v_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(v_lbl)
	# Slide in from right
	add_child(panel)
	panel.modulate.a = 0.0
	var entry := {"panel": panel, "timer": FADE_TIME}
	_entries.append(entry)
	_relayout()
	# Animate in
	var tw := create_tween().set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, SLIDE_TIME)
	tw.tween_property(panel, "position:x", 0.0, SLIDE_TIME).from(60.0)
	# Trim old entries
	while _entries.size() > MAX_ENTRIES:
		_remove_entry(_entries[0])


func _remove_entry(e: Dictionary) -> void:
	if not is_instance_valid(e.panel): _entries.erase(e); return
	var tw := create_tween()
	tw.tween_property(e.panel, "modulate:a", 0.0, 0.15)
	tw.tween_callback(e.panel.queue_free)
	_entries.erase(e)
	_relayout()


func _relayout() -> void:
	var y : float = 0.0
	for e in _entries:
		if is_instance_valid(e.panel):
			e.panel.position.y = y
			y += ENTRY_HEIGHT
