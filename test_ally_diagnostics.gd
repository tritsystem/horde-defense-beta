extends Node
# Diagnostic test for the user-reported Builder ally issues (2026-08-24,
# 8th session): "builder teamate should patrol base and also have run
# animation and character model facing same way as gun also gun still not
# in models hands". Rather than guess further from static code review
# (the weapon-hand-anchor code in team_ally.gd::_build_rig() LOOKS correct
# on inspection, and the "mixamorig_RightHand" bone name IS confirmed real
# on Player.tscn's own skeleton data -- not another bone-name mismatch),
# this directly instantiates a real team_ally.gd node and inspects its
# actual runtime state.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_ally_diagnostics.tscn --quit-after 400

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ALLY DIAGNOSTICS (weapon anchor, animation, facing)")
	print("=".repeat(60))

	var script := load("res://team_ally.gd")
	var ally := CharacterBody3D.new()
	ally.set_script(script)
	ally.set("team_id", 1)
	ally.set("ally_class", 0)   # BUILDER
	add_child(ally)
	ally.global_position = Vector3(7000, 0, 7000)

	# let _build_rig()'s deferred/timer-based pieces settle
	for i in range(90):
		await get_tree().physics_frame

	var rig = ally.get("_rig")
	_check("rig instanced", is_instance_valid(rig))

	var anim_tree = ally.get("_anim_tree")
	_check("_anim_tree resolved", is_instance_valid(anim_tree))
	if is_instance_valid(anim_tree):
		_check("_anim_tree.active is true", anim_tree.active)

	var wm = ally.get("_weapon_manager")
	_check("_weapon_manager resolved", is_instance_valid(wm))

	if is_instance_valid(wm):
		var anchor = wm.get("third_person_anchor")
		_check("third_person_anchor is set on WeaponsManager (was previously always null -> gun floats at camera-relative offset)",
			is_instance_valid(anchor))

		if is_instance_valid(rig):
			var skel = rig.get_node_or_null("Skeleton3D")
			if is_instance_valid(skel):
				var hand_idx : int = skel.find_bone("mixamorig_RightHand")
				_check("skeleton actually has mixamorig_RightHand", hand_idx >= 0)
				if is_instance_valid(anchor) and hand_idx >= 0:
					var hand_pos : Vector3 = skel.global_transform * skel.get_bone_global_pose(hand_idx).origin
					var anchor_pos : Vector3 = (anchor as Node3D).global_position
					var d : float = anchor_pos.distance_to(hand_pos)
					print("  anchor pos=%s  real hand bone pos=%s  dist=%.4f" % [anchor_pos, hand_pos, d])
					_check("BoneAttachment3D anchor is actually AT the real hand bone position", d < 0.05)

		var cw = wm.get("current_weapon")
		_check("WeaponsManager has a current_weapon equipped", is_instance_valid(cw))
		if is_instance_valid(cw) and is_instance_valid(anchor):
			var cw_pos : Vector3 = (cw as Node3D).global_position
			var anchor_pos2 : Vector3 = (anchor as Node3D).global_position
			var wd : float = cw_pos.distance_to(anchor_pos2)
			print("  weapon pos=%s  anchor pos=%s  dist=%.4f" % [cw_pos, anchor_pos2, wd])
			_check("equipped weapon is actually positioned AT the hand anchor (not floating elsewhere)", wd < 0.1)

	# Facing vs aim direction
	var aim_cam = ally.get("_aim_camera")
	if is_instance_valid(aim_cam):
		var cam_fwd : Vector3 = -(aim_cam as Camera3D).global_transform.basis.z
		var body_fwd : Vector3 = -ally.global_transform.basis.z
		var dot := cam_fwd.normalized().dot(body_fwd.normalized())
		print("  camera forward=%s  body forward=%s  dot=%.3f" % [cam_fwd, body_fwd, dot])
		_check("_aim_camera resolved (needed to compare facing vs gun aim)", true)

	# ── Now check under ACTIVE MOVEMENT, not idle -- the realistic case ──
	# Disable the ally's own autonomous _physics_process (its wander/self-
	# defense logic would otherwise fight these manual calls for control
	# every frame) so this is a clean, fully-controlled signal instead of
	# two AI decisions racing each other.
	print("\n-- Under active movement (_seek + _face toward a far point) --")
	ally.set_physics_process(false)
	var dest : Vector3 = ally.global_position + Vector3(30, 0, 0)
	var max_speed_seen := 0.0
	var min_dot_seen := 2.0   # dot ranges [-1,1]; start above the max possible
	var blend_param_seen := ""
	for i in range(120):
		# Drive velocity directly rather than via _seek() -- this minimal
		# test scene has no baked NavigationRegion3D, and NavigationAgent3D
		# silently returns the agent's OWN position as "next path position"
		# with no valid navmesh, which would make _seek() produce zero
		# velocity here (a test-environment limitation, not a gameplay bug
		# -- the real levels have a baked navmesh per the 4th session's
		# navmesh-pathing work). Driving velocity directly isolates the
		# actual thing being tested (facing/animation/weapon under motion)
		# from that unrelated limitation.
		var mdir : Vector3 = (dest - ally.global_position); mdir.y = 0.0
		ally.set("velocity", mdir.normalized() * float(ally.get("move_speed")))
		ally.call("_face", dest)
		ally.call("move_and_slide")
		ally.call("_update_rig_animation")
		await get_tree().physics_frame
		var v : Vector3 = ally.get("velocity")
		var speed2 : float = Vector2(v.x, v.z).length()
		max_speed_seen = maxf(max_speed_seen, speed2)
		if is_instance_valid(aim_cam):
			# Compare YAW only (flatten to XZ) -- the camera legitimately
			# pitches up/down (aim height) while the body never does, so a
			# raw 3D dot product would show "divergence" from pitch alone,
			# which isn't the thing actually being asked about (does the
			# body point the same HORIZONTAL direction as the gun).
			var cf3 : Vector3 = -(aim_cam as Camera3D).global_transform.basis.z
			var bf3 : Vector3 = -ally.global_transform.basis.z
			var cf : Vector2 = Vector2(cf3.x, cf3.z)
			var bf : Vector2 = Vector2(bf3.x, bf3.z)
			var dt : float = 2.0
			if cf.length_squared() > 0.0001 and bf.length_squared() > 0.0001:
				dt = cf.normalized().dot(bf.normalized())
			min_dot_seen = minf(min_dot_seen, dt)
		var p : String = ally.call("_find_blend_param")
		if p != "": blend_param_seen = p

	print("  max horizontal speed reached: %.3f (move_speed=%s)" % [max_speed_seen, str(ally.get("move_speed"))])
	print("  worst (min) facing/camera dot while actively moving: %.4f" % min_dot_seen)
	_check("moving at a real, non-trivial speed (not stuck)", max_speed_seen > 0.5)
	_check("body facing stays aligned with camera/gun-aim yaw even while actively moving+turning",
		min_dot_seen > 0.95)

	if is_instance_valid(wm):
		var anim : float = -1.0
		if is_instance_valid(anim_tree) and blend_param_seen != "":
			var raw = anim_tree.get(blend_param_seen)
			anim = raw.y if raw is Vector2 else float(raw)
		print("  final blend param value ('%s'): %s (1.0 == full move_speed reached)" % [blend_param_seen, str(anim)])
		_check("blend param actually reaches near 1.0 (full run blend) while moving at full speed",
			anim > 0.8)

	# Weapon-in-hand + hand-bone-anchor check AGAIN, now under motion
	# (the arm bone moves during the walk/run animation -- confirms the
	# anchor tracks it live, not just in a static idle pose)
	if is_instance_valid(wm) and is_instance_valid(rig):
		var anchor2 = wm.get("third_person_anchor")
		var cw2 = wm.get("current_weapon")
		if is_instance_valid(anchor2) and is_instance_valid(cw2):
			var wd2 : float = (cw2 as Node3D).global_position.distance_to((anchor2 as Node3D).global_position)
			print("  weapon-to-anchor distance while moving: %.4f" % wd2)
			_check("weapon still tracks the hand anchor while actively moving (not just idle)", wd2 < 0.1)

	_finish()

func _finish() -> void:
	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
