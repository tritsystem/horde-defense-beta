# ============================================================
# HandSocket.gd  —  mount a weapon scene on a Mixamo hand bone
# ============================================================
# This project's player + zombie + ally rigs are all standard Mixamo
# humanoids (bones "mixamorig_Hips" ... "mixamorig_RightHand"). Guns for
# the *first-person* local player are drawn as a camera-relative viewmodel
# by WeaponsManager.gd and do NOT need this. Use HandSocket for anything
# seen in third person: ally/zombie weapons, dropped/pickup weapons,
# melee weapons whose swing should track the animated arm.
#
# Usage (from code, e.g. in a rig's _ready after the Skeleton3D exists):
#
#     const HandSocket := preload("res://scripts/HandSocket.gd")
#     var socket := HandSocket.new()
#     socket.setup(skeleton, "mixamorig_RightHand")
#     skeleton.add_child(socket)
#     socket.equip(load("res://scenes/dagger.tscn"))
#     # fine-tune once in the editor, then bake into grip_offset below:
#     socket.grip_offset = Transform3D(Basis.from_euler(Vector3(0, PI/2, 0)),
#         Vector3(0.03, 0.02, 0.0))
#
# The BoneAttachment3D follows the bone every frame, so the weapon stays
# in the fist through idle / run / attack animations for free.
# ============================================================
extends BoneAttachment3D
# No `class_name` on purpose (a fresh global class isn't registered on a
# headless boot). Callers: const HandSocket := preload(".../HandSocket.gd")

## Local transform from the bone to the weapon's grip. Left at identity the
## weapon sits at the wrist joint origin with the model's own orientation;
## almost every asset needs a small rotate + nudge, found once in-editor.
var grip_offset : Transform3D = Transform3D.IDENTITY

var _weapon : Node3D = null


func setup(skeleton: Skeleton3D, bone_name: String = "mixamorig_RightHand") -> bool:
	if not is_instance_valid(skeleton):
		push_warning("[HandSocket] no skeleton given")
		return false
	var idx := skeleton.find_bone(bone_name)
	if idx == -1:
		# Some import presets keep the colon form ("mixamorig:RightHand").
		idx = skeleton.find_bone(bone_name.replace("_", ":"))
	if idx == -1:
		push_warning("[HandSocket] bone '%s' not found on %s" % [bone_name, skeleton.name])
		return false
	use_external_skeleton = false
	bone_name = skeleton.get_bone_name(idx)
	set("bone_name", skeleton.get_bone_name(idx))
	bone_idx = idx
	return true


## Swap in a new weapon scene (frees the previous one). Returns the instance.
func equip(weapon_scene: PackedScene) -> Node3D:
	clear()
	if weapon_scene == null:
		return null
	_weapon = weapon_scene.instantiate() as Node3D
	if _weapon == null:
		push_warning("[HandSocket] scene root is not Node3D")
		return null
	add_child(_weapon)
	_weapon.transform = grip_offset
	return _weapon


func clear() -> void:
	if is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null


func current() -> Node3D:
	return _weapon
