# ============================================================
# DamageNumbers.gd
# ============================================================
# Self-contained floating damage numbers. No Autoload required.
# 
# HOW IT WORKS:
# Call from any script:
#   get_tree().get_first_node_in_group("damage_numbers").spawn_number(amount, world_pos, type)
# OR just use the static helper that auto-creates it:
#   DamageNumbers.spawn(get_tree(), amount, world_pos, type, is_crit)
#
# TYPE TABLE:
#   0=physical(white) 1=fire(orange) 2=ice(cyan) 3=poison(green)
#   4=electric(yellow) 5=shadow(purple) 6=vampiric(red) 7=crit(gold)
#   8=zombie(sickly green)
#
# ADD TO SCENE: Place this script on a CanvasLayer node in your main scene,
# set layer to 100, name it "DamageNumbers" and add_to_group("damage_numbers").
# OR: it auto-creates itself the first time spawn() is called.
# ============================================================
extends CanvasLayer

const VISIBLE_RANGE : float = 30.0  # only show damage numbers within this distance of local player

const COLORS := {
	0: Color(1.00, 1.00, 1.00),  # physical - white
	1: Color(1.00, 0.42, 0.08),  # fire
	2: Color(0.30, 0.90, 1.00),  # ice
	3: Color(0.30, 1.00, 0.20),  # poison
	4: Color(1.00, 0.95, 0.10),  # electric
	5: Color(0.70, 0.10, 0.95),  # shadow
	6: Color(0.90, 0.10, 0.30),  # vampiric
	7: Color(1.00, 0.85, 0.15),  # crit/headshot - gold
	8: Color(0.55, 0.90, 0.30),  # zombie damage - sickly green
}
const ICONS := {
	0:"", 1:"🔥", 2:"❄", 3:"☠", 4:"⚡", 5:"✦", 6:"🩸", 7:"💥", 8:"🧟"
}

var _ctrl : Control  # full-rect Control child for adding labels


func _ready() -> void:
	layer = 100
	add_to_group("damage_numbers")
	_ctrl = Control.new()
	_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ctrl)


func spawn_number(amount: float, world_pos: Vector3, dmg_type: int = 0, is_crit: bool = false) -> void:
	# Distance check
	var _lp := get_tree().get_first_node_in_group("players") as Node3D
	if is_instance_valid(_lp) and _lp.global_position.distance_to(world_pos) > VISIBLE_RANGE: return
	if amount <= 0.0: return
	# Project world position to screen
	var cam := _get_cam()
	if not is_instance_valid(cam): return
	if cam.is_position_behind(world_pos): return
	var sp : Vector2 = cam.unproject_position(world_pos)
	var vs : Vector2 = get_viewport().get_visible_rect().size
	if sp.x < -50 or sp.x > vs.x + 50 or sp.y < -50 or sp.y > vs.y + 50: return

	var t   : int    = 7 if is_crit else clampi(dmg_type, 0, 8)
	var col : Color  = COLORS.get(t, COLORS[0])
	var ico : String = ICONS.get(t, "")

	var lbl := Label.new()
	lbl.text = ("💥 %d!" % int(amount)) if is_crit else \
			   ("%s %d" % [ico, int(amount)] if ico != "" else str(int(amount)))

	var fsz : int = 26 if is_crit else (20 if amount >= 100 else 16 if amount >= 50 else 13)
	lbl.add_theme_font_size_override("font_size", fsz)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.z_index = 10
	# Position: use set_position AFTER adding so size is known
	_ctrl.add_child(lbl)
	lbl.set_position(sp + Vector2(randf_range(-14, 14), randf_range(-8, 0)))

	var rise  : float = 72.0 if is_crit else 52.0
	var dur   : float = 1.0  if is_crit else 0.75
	var drift : float = randf_range(-18.0, 18.0)
	var tw := lbl.create_tween().set_parallel(true)
	tw.tween_property(lbl, "position:y", lbl.position.y - rise, dur) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "position:x", lbl.position.x + drift, dur) \
		.set_trans(Tween.TRANS_SINE)
	tw.tween_property(lbl, "modulate:a", 0.0, dur * 0.7) \
		.set_delay(dur * 0.3).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lbl.queue_free)


func _get_cam() -> Camera3D:
	# Try current scene's active camera
	var vp := get_viewport()
	if is_instance_valid(vp):
		var c := vp.get_camera_3d()
		if is_instance_valid(c): return c
	return null


# ── Static helper — auto-creates the system if not in scene ──
static func spawn(tree: SceneTree, amount: float, world_pos: Vector3,
		dmg_type: int = 0, is_crit: bool = false) -> void:
	if amount <= 0.0: return
	var sys : Node = tree.get_first_node_in_group("damage_numbers")
	if not is_instance_valid(sys): return  # DamageNumbers node not in scene yet
	if sys.has_method("spawn_number"):
		sys.spawn_number(amount, world_pos, dmg_type, is_crit)
