# ============================================================
# WeaponHUD.gd
# ============================================================
extends Control

@export var weapon_icon_texture : Texture2D
@export var icon_size           : Vector2 = Vector2(64, 64)
@export var icon_spacing        : int     = 10

var _manager       : Node               = null
var _icons         : Array[TextureRect] = []
var _row           : HBoxContainer      = null
var _ammo_label    : Label              = null
var _name_label    : Label              = null
var _last_ammo     : int                = -1
var _last_max_ammo : int                = -1

const C_ACTIVE   : Color = Color(1.0, 1.0, 1.0, 1.0)
const C_INACTIVE : Color = Color(1.0, 1.0, 1.0, 0.35)
const C_LOW_AMMO : Color = Color(1.0, 0.35, 0.1, 1.0)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	grow_vertical   = Control.GROW_DIRECTION_BEGIN
	grow_horizontal = Control.GROW_DIRECTION_END

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	vbox.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(vbox)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.add_theme_color_override("font_color", Color(0.9, 0.88, 0.82))
	_name_label.text = ""
	vbox.add_child(_name_label)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", icon_spacing)
	vbox.add_child(_row)

	_ammo_label = Label.new()
	_ammo_label.add_theme_font_size_override("font_size", 24)
	_ammo_label.add_theme_color_override("font_color", Color(0.96, 0.48, 0.15))
	_ammo_label.text = "-- / --"
	vbox.add_child(_ammo_label)


func bind_weapon_manager(manager: Node) -> void:
	if not is_instance_valid(manager):
		push_error("[WeaponHUD] bind_weapon_manager: invalid manager")
		return
	if is_instance_valid(_manager):
		_disconnect_manager(_manager)
	_manager = manager
	if not _manager.weapon_equipped.is_connected(_on_weapon_equipped):
		_manager.weapon_equipped.connect(_on_weapon_equipped)
	# Always deferred — ensures _init_weapons() has run first
	call_deferred("_on_initialized")


func _disconnect_manager(mgr: Node) -> void:
	if mgr.weapon_equipped.is_connected(_on_weapon_equipped):
		mgr.weapon_equipped.disconnect(_on_weapon_equipped)
	if mgr.has_signal("weapons_initialized") \
			and mgr.weapons_initialized.is_connected(_on_initialized):
		mgr.weapons_initialized.disconnect(_on_initialized)
	_disconnect_all_ammo_signals(mgr)


func _disconnect_all_ammo_signals(mgr: Node) -> void:
	if not is_instance_valid(mgr): return
	for w : Node in mgr.weapons:
		if is_instance_valid(w) and w.has_signal("ammo_changed"):
			if w.ammo_changed.is_connected(_on_ammo_changed):
				w.ammo_changed.disconnect(_on_ammo_changed)


func _on_initialized() -> void:
	if not is_instance_valid(_manager): return
	if not _manager._initialized:
		if _manager.has_signal("weapons_initialized") \
				and not _manager.weapons_initialized.is_connected(_on_initialized):
			_manager.weapons_initialized.connect(_on_initialized, CONNECT_ONE_SHOT)
		return
	_rebuild_icons()
	if is_instance_valid(_manager.current_weapon):
		_sync_weapon(_manager.current_weapon, _manager.current_index)


func _process(_delta: float) -> void:
	if not is_instance_valid(_manager): return
	var w : Node = _manager.current_weapon
	if not is_instance_valid(w): return
	var cur : int = int(w.get("current_ammo") if "current_ammo" in w else
					w.get("ammo")          if "ammo"         in w else -1)
	var mx  : int = int(w.get("max_ammo")  if "max_ammo" in w else -1)
	if cur == _last_ammo and mx == _last_max_ammo: return
	_last_ammo = cur; _last_max_ammo = mx
	_write_ammo(cur, mx)


func _write_ammo(cur: int, mx: int) -> void:
	if not is_instance_valid(_ammo_label): return
	if cur < 0:
		_ammo_label.text = "∞"
		_ammo_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		return
	_ammo_label.text = "%d / %d" % [cur, mx] if mx > 0 else "%d" % cur
	var ratio : float = float(cur) / float(mx) if mx > 0 else 1.0
	_ammo_label.add_theme_color_override("font_color",
		C_LOW_AMMO if ratio <= 0.25 else Color(0.96, 0.48, 0.15))


func _rebuild_icons() -> void:
	for icon in _icons:
		if is_instance_valid(icon): icon.queue_free()
	_icons.clear()
	if not is_instance_valid(_manager) or not is_instance_valid(_row): return
	var count : int = _manager.get_weapon_count()
	for i in count:
		var icon := TextureRect.new()
		icon.name                = "WeaponIcon%d" % i
		icon.texture             = weapon_icon_texture
		icon.custom_minimum_size = icon_size
		icon.stretch_mode        = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.modulate            = C_INACTIVE
		_row.add_child(icon)
		_icons.append(icon)
	_highlight(_manager.current_index if _manager.current_index >= 0 else 0)
	print("[WeaponHUD] built %d icon(s)" % count)


func _sync_weapon(weapon: Node, index: int) -> void:
	_highlight(index)
	_update_name(weapon)
	_connect_ammo_signal(weapon)
	_last_ammo = -1; _last_max_ammo = -1


func _highlight(active_index: int) -> void:
	for i in _icons.size():
		if is_instance_valid(_icons[i]):
			_icons[i].modulate = C_ACTIVE if i == active_index else C_INACTIVE


func _update_name(weapon: Node) -> void:
	if is_instance_valid(_name_label) and is_instance_valid(weapon):
		_name_label.text = weapon.name.replace("_", " ").to_upper()


func _connect_ammo_signal(weapon: Node) -> void:
	if is_instance_valid(_manager):
		for w : Node in _manager.weapons:
			if is_instance_valid(w) and w.has_signal("ammo_changed"):
				if w.ammo_changed.is_connected(_on_ammo_changed):
					w.ammo_changed.disconnect(_on_ammo_changed)
	if is_instance_valid(weapon) and weapon.has_signal("ammo_changed"):
		weapon.ammo_changed.connect(_on_ammo_changed)


func _on_weapon_equipped(weapon: Node) -> void:
	if not is_instance_valid(_manager): return
	_sync_weapon(weapon, _manager.current_index)


func _on_ammo_changed(current: int, max_val: int) -> void:
	_last_ammo = current; _last_max_ammo = max_val
	_write_ammo(current, max_val)


func refresh() -> void:
	_rebuild_icons()
	if is_instance_valid(_manager) and is_instance_valid(_manager.current_weapon):
		_sync_weapon(_manager.current_weapon, _manager.current_index)
