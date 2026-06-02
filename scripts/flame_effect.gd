extends Area3D
class_name FlameProjectile

@export var damage   : float = 6.0
@export var lifetime : float = 0.4
@export var flame_color : Color = Color(1.0, 0.45, 0.06)

var velocity : Vector3 = Vector3.ZERO
var shooter  : Node    = null
var team_id  : int     = -1

var _expired : bool = false
var _timer   : float = 0.0
var _mesh    : MeshInstance3D = null


func _ready() -> void:
	monitoring      = false
	collision_layer = 0
	collision_mask  = 0xFFFFFFFF
	monitorable     = false
	scale           = Vector3.ONE * 0.001
	body_entered.connect(_on_body_entered)


func init(origin: Vector3, start_vel: Vector3, new_shooter: Node, new_team_id: int = -1) -> void:
	global_position = origin
	velocity        = start_vel
	shooter         = new_shooter
	team_id         = new_team_id

	# Tiny sphere mesh — emissive dot
	var col := CollisionShape3D.new()
	var sp  := SphereShape3D.new()
	sp.radius = 0.015
	col.shape = sp
	add_child(col)

	_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.015
	sm.height = 0.03
	sm.radial_segments = 4
	sm.rings = 2
	_mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color               = Color(1.0, 0.55, 0.1, 0.9)
	mat.emission_enabled           = true
	mat.emission                   = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 4.0
	_mesh.material_override = mat
	add_child(_mesh)
	scale = Vector3.ONE

	get_tree().create_timer(lifetime).timeout.connect(_expire)
	monitoring = true
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _expired: return
	_timer += delta
	velocity.y  -= 3.0 * delta
	var spd := velocity.length()
	if spd > 0.01:
		velocity -= velocity.normalized() * 1.5 * spd * delta
	global_position += velocity * delta
	var life_frac := clampf(1.0 - _timer / lifetime, 0.0, 1.0)
	scale = Vector3.ONE * life_frac * 0.018   # max 0.018 world units — tiny dot


func _on_body_entered(body: Node) -> void:
	if _expired or body == shooter: return
	if _is_friendly(body): return
	var t := _resolve(body)
	if is_instance_valid(t): t.take_damage(damage, shooter)
	_expire()


func _resolve(n: Node) -> Node:
	var c := n
	while is_instance_valid(c):
		if c.has_method("take_damage"): return c
		c = c.get_parent()
	return null


func _is_friendly(body: Node) -> bool:
	if not is_instance_valid(shooter) or team_id == -1: return false
	var b := body
	while is_instance_valid(b):
		if "team_id" in b: return int(b.get("team_id")) == team_id
		b = b.get_parent()
	return false


func _expire() -> void:
	if _expired: return
	_expired = true
	set_physics_process(false)
	monitoring = false
	queue_free()
