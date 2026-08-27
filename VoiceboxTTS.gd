extends Node
# ─────────────────────────────────────────────────────────────────────────────
# VoiceboxTTS -- async ally speech, via the local Voicebox desktop app's REST
# API (voicebox-server.exe, a real local TTS service the user already had
# installed for other projects -- NOT a new dependency).
# Autoload singleton: VoiceboxTTS
#
# Pure playback layer: HordeLLM.gd decides WHAT an ally says (bark text) and
# emits line_ready; whatever's listening (team_ally.gd) both shows the text
# bubble AND calls VoiceboxTTS.speak() with the same line. This script does
# not know about ally classes, personas, or combat -- callers pass a
# Voicebox profile id directly, same separation HordeLLM.gd itself keeps
# from AllyClass.
#
# REAL API CONTRACT, confirmed by driving voicebox-server.exe directly on
# 127.0.0.1:8765 (not guessed from docs):
#   POST /speak {text, profile}  -> {id, status:"generating"}   (always async,
#       even for a 2-word line -- confirmed, there is no synchronous path)
#   GET  /history/{id}           -> poll until status=="completed" (or
#       "failed"/"error"); NOT the OpenAPI-listed /generate/{id}/status,
#       which is a Server-Sent-Events endpoint Godot's HTTPRequest can't
#       consume as a plain response
#   GET  /audio/{id}             -> raw WAV bytes once completed (confirmed
#       loadable directly via AudioStreamWAV.load_from_buffer, no temp file
#       needed)
#
# Same graceful-degradation contract as HordeLLM.gd: Voicebox is a desktop
# app the user starts manually (it is NOT always running), so every failure
# mode here is silent-skip, never a blocked bark or a game hitch. Barks stay
# fully functional (text bubble only) with the server off.
# ─────────────────────────────────────────────────────────────────────────────

const BASE_URL := "http://127.0.0.1:8765"
const TIMEOUT := 10.0              # POST /speak and each poll/audio fetch
const POLL_INTERVAL := 0.4
const POLL_TIMEOUT := 20.0         # generation abandoned if not done by then
const MAX_QUEUE := 6               # a stale queued bark-voice is worthless, same reasoning as HordeLLM

enum _State { IDLE, POSTING, POLLING, FETCHING_AUDIO }

var available := true              # flips false after one hard connection failure
var _http: HTTPRequest
var _state: _State = _State.IDLE
var _queue: Array = []             # [{who, text, profile_id}]
var _current: Dictionary = {}
var _generation_id := ""
var _poll_elapsed := 0.0
var _poll_accum := 0.0


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.timeout = TIMEOUT
	_http.request_completed.connect(_on_request_completed)
	set_process(true)


## Queue an ally line for real speech. Silently no-ops if Voicebox is
## unreachable or the queue is already backed up -- never blocks the caller.
func speak(who: Node, text: String, profile_id: String) -> void:
	if not available or text.is_empty() or profile_id.is_empty():
		return
	if _queue.size() >= MAX_QUEUE:
		return
	_queue.append({"who": who, "text": text, "profile_id": profile_id})


func _process(delta: float) -> void:
	match _state:
		_State.IDLE:
			if not _queue.is_empty():
				_start_next()
		_State.POLLING:
			_poll_elapsed += delta
			if _poll_elapsed > POLL_TIMEOUT:
				push_warning("VoiceboxTTS: generation %s timed out after %.0fs" % [_generation_id, POLL_TIMEOUT])
				_finish_job()
				return
			_poll_accum += delta
			if _poll_accum >= POLL_INTERVAL:
				_poll_accum = 0.0
				var err := _http.request(BASE_URL + "/history/" + _generation_id)
				if err != OK:
					_fail("poll request error %d" % err)


func _start_next() -> void:
	_current = _queue.pop_front()
	_state = _State.POSTING
	var body := JSON.stringify({
		"text": str(_current["text"]),
		"profile": str(_current["profile_id"]),
	})
	var err := _http.request(BASE_URL + "/speak", ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail("speak request error %d" % err)


func _on_request_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	match _state:
		_State.POSTING:
			if code != 200:
				_fail("HTTP %d on /speak" % code)
				return
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("id"):
				_fail("bad /speak payload")
				return
			_generation_id = str(parsed["id"])
			if str(parsed.get("status", "")) == "completed":
				_state = _State.FETCHING_AUDIO
				var err := _http.request(BASE_URL + "/audio/" + _generation_id)
				if err != OK:
					_fail("audio request error %d" % err)
			else:
				_state = _State.POLLING
				_poll_elapsed = 0.0
				_poll_accum = 0.0

		_State.POLLING:
			if code != 200:
				_fail("HTTP %d on /history/%s" % [code, _generation_id])
				return
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) != TYPE_DICTIONARY:
				_fail("bad /history payload")
				return
			var status := str(parsed.get("status", ""))
			if status == "completed":
				_state = _State.FETCHING_AUDIO
				var err := _http.request(BASE_URL + "/audio/" + _generation_id)
				if err != OK:
					_fail("audio request error %d" % err)
			elif status == "failed" or status == "error":
				_fail("generation %s reported status=%s" % [_generation_id, status])
			# else still "generating" -- _process() keeps polling

		_State.FETCHING_AUDIO:
			if code != 200 or body.is_empty():
				_fail("HTTP %d fetching audio for %s" % [code, _generation_id])
				return
			var wav := AudioStreamWAV.load_from_buffer(body)
			if not is_instance_valid(wav):
				_fail("could not decode WAV for %s" % _generation_id)
				return
			_play(wav)
			_finish_job()


## Attaches a one-shot 3D player to the speaking ally so the line moves and
## dies with it. Skips silently if the ally is gone by the time audio is
## ready (generation can take a couple seconds) -- same is_instance_valid
## guard team_ally.gd's own _on_bark_ready uses for the text bubble.
func _play(wav: AudioStreamWAV) -> void:
	var who = _current.get("who")
	if not is_instance_valid(who) or not (who is Node3D):
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = wav
	player.unit_size = 8.0     # short-range voice line, not a base-shaking sfx
	who.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


func _fail(reason: String) -> void:
	push_warning("VoiceboxTTS: %s -- ally speech disabled for this session" % reason)
	# One hard failure (server not running, connection refused, etc.) disables
	# TTS for the rest of the session rather than retrying every single bark --
	# same reasoning as HordeLLM._fail(). Text bubbles keep working regardless.
	available = false
	_finish_job()


func _finish_job() -> void:
	_state = _State.IDLE
	_current = {}
	_generation_id = ""
