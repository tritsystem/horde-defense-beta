# ============================================================
# BaseTurret.gd
# ============================================================
# All three turrets extend this.
# Handles health, damage scaling, death, and team assignment.
# ============================================================
extends Node3D
class_name BaseTurret

# ── HEALTH ───────────────────────────────────────────────────
@export_group("Health")
@export var max_health   : float = 300.0   # ~25s for 3 zombies to kill
@export var armor        : float = 0.0    # flat damage reduction per hit

var health : float = 0.0
var _is_dead : bool = false

signal health_changed(current: float, maximum: float)
signal turret_died(turret: Node)

# ── SHARED IDENTITY ──────────────────────────────────────────
var team_id : int = 1
var level   : int = 1
var max_level : int = 999   # No cap — cost doubles each level

signal turret_selected(turret)
signal turret_upgraded(turret)


# ============================================================
func _base_ready() -> void:
	health = max_health
	add_to_group("turrets")
	add_to_group("towers")
	add_to_group("units")
	_build_health_bar()
	health_changed.connect(_update_health_bar)

var _hbar_root : Node3D = null
var _hbar_fill : MeshInstance3D = null

func _build_health_bar() -> void:
	_hbar_root = Node3D.new(); _hbar_root.name = "TurretHealthBar"
	_hbar_root.position = Vector3(0, 3.2, 0)
	add_child(_hbar_root)
	# Background
	var bg := MeshInstance3D.new()
	var bm  := BoxMesh.new(); bm.size = Vector3(1.2, 0.12, 0.02)
	bg.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.1, 0.1, 0.1)
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg.material_override = bmat; _hbar_root.add_child(bg)
	# Fill
	_hbar_fill = MeshInstance3D.new(); _hbar_fill.name = "Fill"
	var fm := BoxMesh.new(); fm.size = Vector3(1.2, 0.12, 0.025)
	_hbar_fill.mesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.15, 0.75, 0.25)
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hbar_fill.material_override = fmat; _hbar_root.add_child(_hbar_fill)

func _update_health_bar(cur: float, maximum: float) -> void:
	if not is_instance_valid(_hbar_fill): return
	var ratio : float = clampf(cur / maxf(maximum, 0.001), 0.0, 1.0)
	_hbar_fill.scale.x = ratio
	_hbar_fill.position.x = (ratio - 1.0) * 0.6
	var mat := _hbar_fill.material_override as StandardMaterial3D
	if mat: mat.albedo_color = Color(1.0 - ratio, ratio * 0.75, 0.1)

func _process(_delta: float) -> void:
	# Billboard health bar toward nearest camera
	if not is_instance_valid(_hbar_root): return
	var cam := get_viewport().get_camera_3d()
	if is_instance_valid(cam):
		var look := _hbar_root.global_position + (cam.global_position - _hbar_root.global_position) * Vector3(1, 0, 1)
		if look.distance_to(_hbar_root.global_position) > 0.1:
			_hbar_root.look_at(cam.global_position, Vector3.UP)


@export var damage_resistance : float = 0.85  # 15% reduction — zombies deal ~85% dmg to turrets
func take_damage(amount: float, instigator = null) -> void:
	if _is_dead: return
	# Friendly fire guard — never take damage from same team
	if instigator != null and is_instance_valid(instigator):
		var ins_team : int = int(instigator.get("team_id") if "team_id" in instigator else -1)
		if ins_team == team_id: return
	var actual : float = amount
	if instigator is Object and is_instance_valid(instigator) and (instigator.is_in_group("units") or instigator.is_in_group("minions")):
		actual = amount * damage_resistance
	if armor > 0.0: actual = maxf(actual - armor, 1.0)
	health = maxf(health - actual, 0.0)
	# Floating damage number
	var _dn2 : Node = get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(_dn2) and _dn2.has_method("spawn_number"):
		var _dtype2 : int = 8 if instigator is Object and is_instance_valid(instigator) and (instigator.is_in_group("zombies") or instigator.is_in_group("minions")) else 0
		_dn2.spawn_number(amount, global_position + Vector3(0, 3.5, 0), _dtype2, false)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		_die()


func _die() -> void:
	if _is_dead: return
	_is_dead = true
	turret_died.emit(self)
	# Quest: turret kill for enemy team
	for p in get_tree().get_nodes_in_group("player"):
		if "team_id" in p and int(p.get("team_id")) != team_id:
			if p.has_method("record_quest_event"): p.record_quest_event("turret_kills", 1)
	# Brief delay so death VFX can play if you add one
	await get_tree().create_timer(0.4).timeout
	queue_free()


# ── Per-level stat scaling helpers ───────────────────────────
# Call these in each turret's upgrade() function.

# Returns a multiplier that grows with level: 1.0 at L1, peaks at L5
func _dmg_scale() -> float:
	# L1=1.0  L2=1.35  L3=1.75  L4=2.25  L5=3.0
	return pow(1.32, level - 1)

func _rate_scale() -> float:
	# Fire rate gets faster each level (multiplier < 1)
	return pow(0.88, level - 1)

func _range_bonus() -> float:
	return (level - 1) * 1.8

func _health_scale() -> float:
	# L1=1.0  L2=1.4  L3=1.9  L4=2.6  L5=3.5
	return pow(1.37, level - 1)
