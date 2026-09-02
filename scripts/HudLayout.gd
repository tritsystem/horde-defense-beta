# ============================================================
# HudLayout.gd  —  autoload singleton
# ============================================================
# Owns the player's per-panel HUD layout (position + size), persisted to
# user://hud_layout.cfg, and a global "HUD edit mode" flag.
#
# Any Control can opt in with one line in its _ready():
#     DraggableHudPanel.attach(self, "upgrade_panel")
#
# While edit mode is on (toggle with F8, or HudLayout.set_edit(true)):
#   • drag a panel's title/body to move it
#   • drag its bottom-right grip to resize it
#   • right-click a panel to reset it to its scene default
# Positions are saved automatically and restored next launch.
# ============================================================
extends Node

signal edit_mode_changed(on: bool)

const CFG_PATH := "user://hud_layout.cfg"

var _cfg := ConfigFile.new()
var edit_mode : bool = false


var _toast : Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cfg.load(CFG_PATH)   # missing file is fine — returns != OK, cfg stays empty
	_build_toast()


func _build_toast() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 128
	add_child(cl)
	_toast = Label.new()
	_toast.text = "HUD EDIT MODE  —  drag to move · corner to resize · right-click to reset · F8 to exit"
	_toast.add_theme_font_size_override("font_size", 13)
	_toast.add_theme_color_override("font_color", Color(0.05, 0.07, 0.1))
	_toast.add_theme_color_override("font_outline_color", Color(0.35, 0.75, 1.0))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.anchor_left = 0.0; _toast.anchor_right = 1.0
	_toast.anchor_top = 1.0;  _toast.anchor_bottom = 1.0
	_toast.offset_top = -30.0; _toast.offset_bottom = -6.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	cl.add_child(_toast)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F8:
		set_edit(not edit_mode)
		get_viewport().set_input_as_handled()


func set_edit(on: bool) -> void:
	if on == edit_mode:
		return
	edit_mode = on
	if is_instance_valid(_toast):
		_toast.visible = on
	edit_mode_changed.emit(on)


# --- persistence -------------------------------------------------------------
func get_rect(id: String) -> Rect2:
	if not _cfg.has_section_key(id, "rect"):
		return Rect2()   # zero rect => "no saved layout, use scene default"
	return _cfg.get_value(id, "rect", Rect2())


func save_rect(id: String, r: Rect2) -> void:
	_cfg.set_value(id, "rect", r)
	_cfg.save(CFG_PATH)


func clear_rect(id: String) -> void:
	if _cfg.has_section(id):
		_cfg.erase_section(id)
		_cfg.save(CFG_PATH)
