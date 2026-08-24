# ============================================================
# MusicManager.gd — Autoload
# Plays music from game start with smooth crossfade + volume
# ============================================================
extends Node

@export var master_volume    : float = 0.8
@export var crossfade_time   : float = 1.5
@export var loop_music       : bool  = true

# Manual overrides — set these (via code, or an Inspector on a wrapper scene
# if this autoload is ever switched from a bare script to a .tscn) to pin a
# specific track to a specific role. Any slot left null auto-fills from the
# discovered track pool below instead.
@export var track_menu       : AudioStream = null
@export var track_victory    : AudioStream = null
@export var track_ambient    : AudioStream = null

# REAL BUG FIX (2026-07-21): this autoload is registered as a bare script
# (project.godot: `Musicmanager="*uid://..."`), not a scene -- so there was
# never anywhere for the Inspector to actually assign the track_* exports
# above. They were permanently null, and _ready()'s auto-play checks
# (`is_instance_valid(track_ambient)` etc) all failed silently. Confirmed
# live: zero music ever played. Fix: auto-discover every track in
# MUSIC_DIR at startup and build a real rotating playlist from them, so
# music works out of the box with no manual Inspector wiring required --
# manual track_* overrides above still take priority per-slot if ever set.
const MUSIC_DIR := "res://audio/horde/"

# COMBAT MUSIC REMOVED (2026-07-25): a separate "intense combat" pool used to
# swap in whenever the player took a hit and swap back out ~8s after the last
# hit. Real horde-defense combat ebbs and flows every few seconds, so this
# constantly forced a brand-new track pick + crossfade mid-song -- reported
# live as "music skipping songs every time I fight." Simplest actual fix:
# there is no combat-triggered track switch anymore. Every discovered track
# (regardless of name) goes in one pool that just rotates continuously,
# combat or not.
var _players      : Array[AudioStreamPlayer] = []
var _active_idx    : int   = 0

var _general_pool  : Array[AudioStream] = []
var _general_queue : Array[AudioStream] = []  # shuffled, drained front-to-back
var _current_stream : AudioStream = null

signal track_changed(track_name: String)


# REAL BUG FIX (2026-08-19): linear_to_db(0.0) evaluates to -INF (log(0) is
# undefined). Tweening a volume_db property TO -INF produces NaN on the
# tween's first evaluated frame (-INF * 0 == NaN), and Godot's AudioStreamPlayer
# throws "Volume can't be set to NaN" every time that happens -- which is
# every single crossfade and every fade-out, i.e. constantly during real
# play. Confirmed live: hundreds of these errors per session. Fix: use a
# finite "effectively silent" dB floor instead of true -infinity, same
# pattern AudioManager.gd already uses for its own bus volume.
const SILENT_DB : float = -80.0

func _safe_db(v: float) -> float:
	if v <= 0.0: return SILENT_DB
	return linear_to_db(v)


func _ready() -> void:
	add_to_group("music_manager")
	_discover_tracks()
	# Create two players for crossfading
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus    = "Music"
		p.volume_db = SILENT_DB
		p.finished.connect(_on_track_finished)
		add_child(p)
		_players.append(p)
	# Auto-play on start
	get_tree().create_timer(0.5).timeout.connect(func():
		if is_instance_valid(track_ambient):
			play_track(track_ambient, "Ambient")
		else:
			_play_next_general())


func _discover_tracks() -> void:
	var dir := DirAccess.open(MUSIC_DIR)
	if not is_instance_valid(dir):
		push_warning("[MusicManager] Couldn't open %s -- no music will auto-play. Check the folder exists and tracks were imported." % MUSIC_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and (fname.get_extension().to_lower() in ["mp3", "ogg", "wav"]):
			var stream := load(MUSIC_DIR + fname) as AudioStream
			if is_instance_valid(stream):
				_general_pool.append(stream)
			else:
				push_warning("[MusicManager] Failed to load track: %s" % fname)
		fname = dir.get_next()
	dir.list_dir_end()
	print("[MusicManager] Discovered %d track(s) in %s" % [_general_pool.size(), MUSIC_DIR])


func _refill_and_shuffle(pool: Array[AudioStream]) -> Array[AudioStream]:
	var queue := pool.duplicate()
	queue.shuffle()
	return queue


func _play_next_general() -> void:
	if _general_queue.is_empty():
		if _general_pool.is_empty():
			return  # nothing discovered at all -- nothing to play
		_general_queue = _refill_and_shuffle(_general_pool)
	var next_track : AudioStream = _general_queue.pop_front()
	play_track(next_track, next_track.resource_path.get_file())


func _on_track_finished() -> void:
	# REAL BUG FIX: nothing previously re-triggered playback once a track
	# ended -- music played once, then silence for the rest of the run.
	# Auto-advance to the next track in the rotation.
	#
	# Only skip auto-advance if the track that JUST ENDED is itself one of
	# the manually-pinned overrides (not "any override is set anywhere" --
	# that would wrongly freeze auto-advance for the whole session just
	# because e.g. track_menu got set once for an unrelated screen).
	var was_manual := (is_instance_valid(track_ambient) and _current_stream == track_ambient)
	if was_manual:
		if loop_music:
			play_track(_current_stream, "Loop")
		return
	_play_next_general()


func notify_combat() -> void:
	# Combat music removed — see comment above _general_pool. Music no
	# longer reacts to combat state at all, so this is intentionally a
	# no-op; kept only because player.gd still calls it.
	pass


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
	_current_stream = stream
	# Crossfade
	var tw := create_tween().set_parallel(true)
	tw.tween_property(next, "volume_db", _safe_db(master_volume), crossfade_time)
	tw.tween_property(cur,  "volume_db", SILENT_DB, crossfade_time)
	tw.chain().tween_callback(cur.stop)
	_active_idx = next_idx
	track_changed.emit(name)
	print("[MusicManager] Playing: %s" % name)


func set_volume(vol: float) -> void:
	master_volume = clampf(vol, 0.0, 1.0)
	_players[_active_idx].volume_db = _safe_db(master_volume)


func stop(fade: float = 1.0) -> void:
	for p in _players:
		create_tween().tween_property(p, "volume_db", SILENT_DB, fade).finished.connect(p.stop)


func play_stinger(stream: AudioStream) -> void:
	if not is_instance_valid(stream): return
	var stinger := AudioStreamPlayer.new()
	stinger.stream = stream; stinger.bus = "Music"
	stinger.volume_db = _safe_db(master_volume * 0.7)
	add_child(stinger); stinger.play()
	stinger.finished.connect(stinger.queue_free)
