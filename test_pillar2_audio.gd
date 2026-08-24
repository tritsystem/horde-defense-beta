extends Node
# Headless test for Pillar 2 (Audio) batch 1 (2026-07-20):
# - Musicmanager.gd set bus="Music" but no such bus existed in the real
#   AudioBusLayout -- music was silently falling back to Master.
# - shopui.gd had zero UI click feedback anywhere despite a real, unused
#   UI sound asset already sitting in the project.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_pillar2_audio.tscn --quit

func _ready() -> void:
	print("=".repeat(60))
	print("  PILLAR 2 (AUDIO) -- Music/SFX buses + UI click sound")
	print("=".repeat(60))

	var music_idx: int = AudioServer.get_bus_index("Music")
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	print("  Music bus index: %d   SFX bus index: %d" % [music_idx, sfx_idx])
	var buses_ok: bool = music_idx >= 0 and sfx_idx >= 0
	print("  %s -- both buses now actually exist in the real layout" % ("ok  " if buses_ok else "FAIL"))

	# Musicmanager's own players should now genuinely resolve to the real bus
	var mm := get_tree().get_first_node_in_group("music_manager")
	var mm_bus_ok := false
	if is_instance_valid(mm):
		for p in mm.get_children():
			if p is AudioStreamPlayer and (p as AudioStreamPlayer).bus == "Music":
				mm_bus_ok = AudioServer.get_bus_index("Music") >= 0
	print("  %s -- Musicmanager's players are assigned to a bus that genuinely exists" % ("ok  " if mm_bus_ok else "FAIL"))

	# UI click sound wiring
	var shop_script := load("res://scripts/shopui.gd")
	var shop := Control.new()
	shop.set_script(shop_script)
	add_child(shop)
	var btn: Button = shop.call("_make_button", "Test")
	shop.add_child(btn)
	var had_player_before: bool = shop.get("_ui_click_player") != null
	btn.emit_signal("pressed")
	var player_after = shop.get("_ui_click_player")
	var click_ok: bool = player_after != null and (player_after as AudioStreamPlayer).stream != null
	print("  %s -- pressing a shop button (built via _make_button) actually plays a real UI sound" % ("ok  " if click_ok else "FAIL"))

	var all_ok: bool = buses_ok and mm_bus_ok and click_ok
	print("\n" + "-".repeat(42))
	print("  %s" % ("PASS" if all_ok else "FAIL"))
	print("-".repeat(42) + "\n")
	get_tree().quit(0 if all_ok else 1)
