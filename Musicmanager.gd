# ============================================================
# MusicManager.gd — Autoload
# Plays music from game start with smooth crossfade + volume
# ============================================================
extends Node

@export var master_volume    : float = 0.8
@export var crossfade_time   : float = 1.5
@export var loop_music       : bool  = true

# Assign tracks in Inspector or via code
@export var track_menu       : AudioStream = null
@export var track_combat     : AudioStream = null
@export var track_intense    : AudioStream = null
@export var track_victory    : AudioStream = null
@export var track_ambient    : AudioStream = null

var _players    : Array[AudioStreamPlayer] = []
var _active_idx : int   = 0
var _is_combat  : bool  = false
var _combat_timer : float = 0.0

signal track_changed(track_name: String)


func _ready() -> void:
	add_to_group("music_manager")
	# Create two players for crossfading
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus    = "Music"
		p.volume_db = linear_to_db(0.0)
		add_child(p)
		_players.append(p)
	# Auto-play ambient on start
	get_tree().create_timer(0.5).timeout.connect(func():
		if is_instance_valid(track_ambient):
			play_track(track_ambient, "Ambient")
		elif is_instance_valid(track_combat):
			play_track(track_combat, "Combat"))


func _process(delta: float) -> void:
	# Auto-detect combat — if in combat, stay intense for 8s after last hit
	if _combat_timer > 0.0:
		_combat_timer -= delta
		if _combat_timer <= 0.0 and _is_combat:
			_is_combat = false
			if is_instance_valid(track_ambient):
				play_track(track_ambient, "Ambient")


func notify_combat() -> void:
	_combat_timer = 8.0
	if not _is_combat:
		_is_combat = true
		if is_instance_valid(track_intense):
			play_track(track_intense, "Intense Combat")
		elif is_instance_valid(track_combat):
			play_track(track_combat, "Combat")


func play_track(stream: AudioStream, name: String = "") -> void:
	if not is_instance_valid(stream): return
	var next_idx : int = 1 - _active_idx
	var cur  := _players[_active_idx]
	var next := _players[next_idx]
	# Don't restart same track
	if cur.stream == stream and cur.playing: return
	next.stream    = stream
	next.pitch_scale = 1.0
	next.play()
	# Crossfade
	var tw := create_tween().set_parallel(true)
	tw.tween_property(next, "volume_db", linear_to_db(master_volume), crossfade_time)
	tw.tween_property(cur,  "volume_db", linear_to_db(0.0), crossfade_time)
	tw.chain().tween_callback(cur.stop)
	_active_idx = next_idx
	track_changed.emit(name)
	print("[MusicManager] Playing: %s" % name)


func set_volume(vol: float) -> void:
	master_volume = clampf(vol, 0.0, 1.0)
	_players[_active_idx].volume_db = linear_to_db(master_volume)


func stop(fade: float = 1.0) -> void:
	for p in _players:
		create_tween().tween_property(p, "volume_db", linear_to_db(0.0), fade).finished.connect(p.stop)


func play_stinger(stream: AudioStream) -> void:
	if not is_instance_valid(stream): return
	var stinger := AudioStreamPlayer.new()
	stinger.stream = stream; stinger.bus = "Music"
	stinger.volume_db = linear_to_db(master_volume * 0.7)
	add_child(stinger); stinger.play()
	stinger.finished.connect(stinger.queue_free)
