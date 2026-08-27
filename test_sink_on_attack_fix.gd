extends Node
# Headless behavioral re-verification for the "sink when attacking" fix
# (4th session, 2026-08-24): attack.res/death.res/idle.res's every bone track
# pointed at nonexistent "mixamorig5_*" skeleton paths (real skeleton bones
# are "mixamorig_*"), so those three animations were silent no-ops -- the
# model never actually posed for them at all, only "run" (borrowed from the
# player rig, correctly named) ever did. This is a DIRECT test of the fixed
# unit (do the tracks actually drive Skeleton3D bones now?), not just a
# string check that the resource no longer contains "mixamorig5" -- it's the
# closest headless proxy to what a live playtester would actually see.
#
# Also specifically re-checks a real, non-obvious risk this exact fix could
# have introduced: _correct_root_bone_y() (zeroes the Hips bone's local Y
# every frame to cancel the attack lunge's hip dip) was ALWAYS being called,
# but before this fix the Hips track never actually applied -- so the
# correction was neutralizing nothing. Now that the track is live, if the
# correction doesn't actually zero a REAL nonzero dip, that's a brand-new
# sink risk that didn't exist in this exact form pre-fix.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_sink_on_attack_fix.tscn --quit-after 4000
# (needs --quit-after, not bare --quit -- this project's SceneSetup autoload
# runs a full real-player/SplitScreenManager boot on ANY loaded scene
# including test harnesses, which alone burns ~150 iterations before this
# script's own _ready() logic can run to completion; the 150-physics-frame
# attack-sequence loop below needs real budget on top of that.)

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  SINK-ON-ATTACK ANIMATION FIX (re-verification)")
	print("=".repeat(60))

	var z: Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z)
	await get_tree().physics_frame

	var skel: Skeleton3D = z.get("_skeleton")
	_check("skeleton reference resolved", is_instance_valid(skel))
	if not is_instance_valid(skel):
		_finish()
		return

	# Take manual control of the AnimationPlayer so the AnimationTree
	# (which normally drives attack/death via OneShot requests + a
	# multi-tick blend) can't fight our direct seeks below -- this isolates
	# exactly the fixed unit (does the .res resource's own track data apply
	# to this skeleton by name?), independent of the separately-proven
	# OneShot/blend-tree wiring machinery.
	var anim_tree: AnimationTree = z.get("anim_tree")
	if anim_tree != null:
		anim_tree.active = false

	var hips_idx: int = z.get("_hips_bone_idx")
	var real_hips_idx: int = skel.find_bone("mixamorig_Hips")
	print("  hips_bone_idx=%d  skeleton.find_bone('mixamorig_Hips')=%d" % [hips_idx, real_hips_idx])
	_check("Hips bone resolved by REAL name match, not a lucky bone-0 fallback",
		real_hips_idx >= 0 and hips_idx == real_hips_idx)

	var ap: AnimationPlayer = z.get_node("AnimationPlayer")
	_check("AnimationPlayer resolved", is_instance_valid(ap))
	if not is_instance_valid(ap):
		_finish()
		return

	var arm_idx := skel.find_bone("mixamorig_RightForeArm")
	_check("test limb bone (mixamorig_RightForeArm) exists on this skeleton", arm_idx >= 0)

	# The zombie's AnimationPlayer stores its clips in a NAMED library
	# ("animations", not the default ""), so lookups need the
	# "library_name/anim_name" qualified form.
	for anim_short in ["attack", "death", "idle", "run"]:
		var anim_name := "animations/%s" % anim_short
		if not ap.has_animation(anim_name):
			_check("animation '%s' exists in the library" % anim_name, false)
			continue
		var anim: Animation = ap.get_animation(anim_name)
		var length: float = anim.length

		ap.play(anim_name)
		ap.seek(0.0, true)
		var arm_pose_0: Transform3D = skel.get_bone_pose(arm_idx)

		var mid_t: float = clampf(length * 0.5, 0.01, maxf(length - 0.01, 0.01))
		ap.seek(mid_t, true)
		var arm_pose_mid: Transform3D = skel.get_bone_pose(arm_idx)

		var moved: bool = arm_pose_0.origin.distance_to(arm_pose_mid.origin) > 0.001 \
			or not arm_pose_0.basis.is_equal_approx(arm_pose_mid.basis)
		_check("'%s' track actually drives a limb bone (was a silent no-op pre-fix, len=%.2fs)" % [anim_name, length],
			moved)

	# --- Hips-dip / correction re-check, specifically on attack ---
	if hips_idx >= 0 and ap.has_animation("animations/attack"):
		var attack_anim: Animation = ap.get_animation("animations/attack")
		var atk_len: float = attack_anim.length
		var max_raw_dip := 0.0
		var sample_count := 12
		var all_corrected := true
		for i in range(sample_count):
			var t: float = (float(i) / float(sample_count - 1)) * maxf(atk_len - 0.01, 0.0)
			ap.play("animations/attack")
			ap.seek(t, true)
			var raw_pose: Transform3D = skel.get_bone_pose(hips_idx)
			max_raw_dip = maxf(max_raw_dip, absf(raw_pose.origin.y))
			z.call("_correct_root_bone_y")
			var corrected_pose: Transform3D = skel.get_bone_pose(hips_idx)
			if absf(corrected_pose.origin.y) > 0.011:
				all_corrected = false
				print("  FAIL at t=%.2fs: corrected Hips Y = %.4f (raw was %.4f)" % [t, corrected_pose.origin.y, raw_pose.origin.y])

		print("  max RAW Hips-bone Y offset observed across attack anim (pre-correction): %.4f" % max_raw_dip)
		_check("attack animation carries a real, nonzero Hips Y offset (proves this correction is live-relevant, not a no-op check)",
			max_raw_dip > 0.01)
		_check("_correct_root_bone_y() zeroes the REAL (now-applying) Hips Y dip at every sampled point across the attack animation",
			all_corrected)

	await _test_full_attack_sequence_sink()
	_test_command_api_smoke()

	_finish()

# ── Full attack-sequence sink regression (2026-08-24 rebuild) ──────────
# The actual live-reported bug: "sink on attack STILL happening" after the
# bone-name fix above. Root cause found separately: _try_attack() hardcoded
# _attack_anim_timer=0.7 (the ONLY thing telling _apply_gravity() to
# suppress downward velocity mid-swing), but the real attack.res clip is
# ~2.63s. For the ~1.9s after the old 0.7s window expired but the swing was
# still visibly playing, gravity was unprotected -- if is_on_floor() flipped
# false at all in that window (a knockback landing, a slope, an elite
# impulse), the body fell/sank uncontested. Fixed by deriving
# _attack_anim_len from the real clip in _ready(). This test forces exactly
# that edge case: an attack fires, then a knockback lands well AFTER the old
# 0.7s cutoff but WELL WITHIN the new ~2.6s window -- proving the window is
# still actually protecting gravity at that point, not just checking a
# static constant.
func _test_full_attack_sequence_sink() -> void:
	print("\n-- Full attack-sequence sink regression (the actual live-reported bug) --")

	var floor := StaticBody3D.new()
	floor.collision_layer = 3
	floor.collision_mask = 3
	add_child(floor)
	var fshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(50, 1, 50)
	fshape.shape = box
	floor.add_child(fshape)
	floor.global_position = Vector3(9000, 0, 9000)

	var z2 : CharacterBody3D = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z2)
	z2.global_position = Vector3(9000, 5, 9000)
	z2.set("team_id", 1)

	var dummy := Node3D.new()
	dummy.set_script(_dummy_target_script())
	add_child(dummy)
	dummy.set("team_id", 2)
	dummy.set("health", 999.0)
	dummy.set("max_health", 999.0)
	dummy.global_position = Vector3(9000, 5, 9001.0)

	z2.set("target", dummy)
	z2.set("target_type", "unit")

	# let it land on real ground first
	for i in range(60):
		await get_tree().physics_frame

	var y0 : float = z2.global_position.y
	print("  settled floor Y: %.4f" % y0)

	var max_drop := 0.0
	var floor_losses := 0
	var checked_window_at_critical_t := false
	var protected_at_critical_t := false

	for i in range(150):   # 2.5s at 60Hz -- covers the critical t=1.0s checkpoint with margin
		await get_tree().physics_frame
		z2.call("_try_attack", dummy)   # idempotent -- only actually fires when attack_timer<=0, same as real AI
		# Force the exact edge case the bug needed: an is_on_floor()==false
		# event well AFTER the OLD 0.7s window would have expired (frame 42)
		# but WELL WITHIN the real ~2.6s window -- if the fix regressed back
		# to the short window, gravity would be unprotected here.
		if i == 60:
			z2.velocity.y = 2.0
			checked_window_at_critical_t = true
			protected_at_critical_t = float(z2.get("_attack_anim_timer")) > 0.0
		max_drop = maxf(max_drop, y0 - z2.global_position.y)
		if not z2.is_on_floor():
			floor_losses += 1

	var attack_len : float = z2.get("_attack_anim_len")
	print("  max Y drop from settled floor position over 2.5s of sustained attacking (forced knockback at t=1.0s): %.4f" % max_drop)
	_check("no meaningful sink (<0.1) during sustained real attack sequence", max_drop < 0.1)
	print("  frames off-floor during sustained melee: %d / 150" % floor_losses)
	_check("_attack_anim_timer was still actively protecting gravity at t=1.0s (past the OLD 0.7s cutoff, within the NEW ~2.6s one)",
		checked_window_at_critical_t and protected_at_critical_t)
	print("  _attack_anim_len derived: %.3f (stale default was a hardcoded 0.7)" % attack_len)
	_check("_attack_anim_len derived from the real clip, not the stale 0.7s default", attack_len > 1.0)

	z2.queue_free()
	dummy.queue_free()
	floor.queue_free()

func _dummy_target_script() -> GDScript:
	var src := GDScript.new()
	src.source_code = "extends Node3D\nvar team_id : int = 0\nvar health : float = 100.0\nvar max_health : float = 100.0\n"
	src.reload()
	return src

# ── Command-API smoke check (2026-08-24 rebuild) ────────────────────────
# Cheap insurance that extracting target-priority/stuck-recovery into
# TargetPriority.gd/MovementRecovery.gd didn't touch the public command
# surface SquadCommandPanel.gd/ZombieHordeManager.gd/HiveCluster.gd depend
# on -- none of that logic was extracted, but this confirms it directly
# rather than by argument.
func _test_command_api_smoke() -> void:
	print("\n-- Command-API smoke check --")
	var z3 : Node = (load("res://zombie/zombie.tscn") as PackedScene).instantiate()
	add_child(z3)
	var dummy_player := Node3D.new()
	add_child(dummy_player)

	z3.call("command_follow", dummy_player, true)
	_check("command_follow sets squad_order=FOLLOW, ai_mode=FOLLOW_OWNER",
		int(z3.get("squad_order")) == 5 and int(z3.get("ai_mode")) == 4)

	z3.call("command_defend", true)
	_check("command_defend sets squad_order=DEFEND", int(z3.get("squad_order")) == 2)

	z3.call("command_attack_position", Vector3(1, 2, 3), true)
	_check("command_attack_position sets squad_order=ATTACK and squad_position",
		int(z3.get("squad_order")) == 1 and (z3.get("squad_position") as Vector3).is_equal_approx(Vector3(1, 2, 3)))

	z3.call("command_patrol", true)
	_check("command_patrol sets squad_order=PATROL, ai_mode=PATROL",
		int(z3.get("squad_order")) == 3 and int(z3.get("ai_mode")) == 5)

	z3.call("command_hold", true)
	_check("command_hold sets squad_order=STAY", int(z3.get("squad_order")) == 4)

	z3.call("set_ai_mode", 2)
	_check("set_ai_mode sets ai_mode directly", int(z3.get("ai_mode")) == 2)

	z3.call("clear_order")
	_check("clear_order resets squad_order=NONE", int(z3.get("squad_order")) == 0)

	z3.queue_free()
	dummy_player.queue_free()

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
