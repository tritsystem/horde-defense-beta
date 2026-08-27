extends Node
# ─────────────────────────────────────────────────────────────────────────────
# HordeLLM -- async local-LLM combat barks for team allies, via Ollama.
# Autoload singleton: HordeLLM
#
# Ported from the tribe project's proven TribeLLM pattern (C:\Users\gbran\
# OneDrive\Documents\tribe\tribe_llm.gd), which that repo's own header
# documents as hard-won: async HTTPRequest (never block a frame), ONE
# request in flight globally, a max-depth queue that DROPS on overflow
# rather than piling up latency, and every call has a timeout + canned
# fallback so a dead/cold Ollama degrades the flavour, not the simulation.
#
# SCOPE (deliberately narrower than TribeLLM): this is bark-only flavour
# text triggered by real combat events (kill, taking damage, freed from a
# cage) -- NOT tactical control. Tactical/strategic AI here is already a
# separate, proven Spiking Neural Network layer (spikeling.gd, wired into
# zombie.gd/team_ally.gd/AIDirector.gd) and stays that way; an LLM call
# costs 2-4s even warm, which is fine for an occasional spoken line but
# would be useless for a per-frame combat decision. See the horde-beta
# session ledger's "Open/next" table for a flagged, NOT-built-here
# follow-up: LLM-driven high-level tactical directives on top of the SNN.
#
# 127.0.0.1, NOT "localhost" -- confirmed on this machine localhost
# resolves to ::1 (IPv6) while Ollama binds 127.0.0.1 (IPv4); Godot's
# HTTPRequest does not silently fall back the way curl/python do (see
# tribe_llm.gd's own header for the exact symptom this caused there: every
# line silently used the canned fallback while /api/ps showed the model
# loaded and healthy the whole time).
# ─────────────────────────────────────────────────────────────────────────────

const OLLAMA_URL := "http://127.0.0.1:11434/api/generate"
const MODEL := "llama3.2"          # confirmed installed via `ollama list` on this machine
const TIMEOUT := 15.0              # warm calls; tribe_llm.gd measured 2.5-4.2s real-world
const WARMUP_TIMEOUT := 180.0      # cold model load; one-off at startup
const MAX_QUEUE := 4               # overflow is dropped -- a stale combat bark is worthless
const MAX_TOKENS := 40             # a bark is one short line, not a speech

# GROUNDING GUARDRAIL (same lesson tribe_llm.gd already paid for): a small
# model handed only "you are a soldier" reaches for generic-shooter-game
# tropes and invents things not in this world (ranks, other factions,
# named commanders). Telling it what's REAL keeps it from confabulating.
const WORLD := """
This is a real-time horde-defense battle. Waves of zombie creeps (some
armored, ranged, or elite) march from spawn lanes toward your team's
castle base, which is defended by turrets and a team of players/allies.
Killing zombies and clearing "hive" nests earns gold, spent on base
upgrades and unlocking new deck creeps. That is the ENTIRE world -- no
ranks, no named commanders, no other human factions, no dialogue with the
enemy (zombies don't talk back). Do not invent lore, names, or events
beyond what you're told below.
"""

signal line_ready(who: Node, text: String, tag: String)

var _http: HTTPRequest
var _busy := false
var _queue: Array = []             # [{who, prompt, tag, fallback}]
var _current: Dictionary = {}
var _elapsed := 0.0
var available := true              # flipped false if Ollama errors out
var warm := false                  # model loaded? until then, callers get fallbacks
var _warming := false

# Untyped on purpose: a bare `HysteresisGate` type annotation depends on
# Godot's global script-class cache having already indexed hysteresis_gate.gd
# -- confirmed to race and fail ("Could not find type HysteresisGate in the
# current scope") on a cold headless run right after adding that file, before
# any editor pass rebuilds the cache. The preloaded script reference below
# doesn't have that dependency.
const HysteresisGateScript = preload("res://hysteresis_gate.gd")
var _queue_gate

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_done)
	_queue_gate = HysteresisGateScript.new(0.25, 0.85)
	_warmup()
	set_process(true)

## True if the queue is genuinely backed up right now -- hysteresis-gated so
## draining by one line right at the cap doesn't immediately let a new call
## back in, only to hit the cap again a moment later.
func _queue_backed_up() -> bool:
	var load: float = float(_queue.size()) / float(MAX_QUEUE)
	return _queue_gate.update(load)

## Load the model NOW with a long leash, so no ally ever eats the cold-start
## cost mid-fight. Until this lands, say_as() returns canned lines.
func _warmup() -> void:
	_warming = true
	_busy = true
	_http.timeout = WARMUP_TIMEOUT
	var body := JSON.stringify({
		"model": MODEL, "prompt": "hi", "stream": false,
		"options": {"num_predict": 1},
	})
	var err := _http.request(OLLAMA_URL, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_warming = false
		_busy = false
		available = false
		push_warning("HordeLLM: Ollama unreachable -- allies will use canned barks")

func _process(delta: float) -> void:
	if _busy:
		_elapsed += delta
		return
	if _queue.is_empty():
		return
	_send(_queue.pop_front())

## Ask an ally to bark a short combat line. Returns immediately; listen for
## `line_ready`. `fallback` is used verbatim if the LLM is unavailable, cold,
## or backed up -- an ally saying something plain beats silence or a
## multi-second stall mid-fight.
func say_as(who: Node, persona: String, situation: String, fallback: String,
		tag: String = "bark") -> void:
	if not available or not warm or _queue_backed_up():
		line_ready.emit(who, fallback, tag)
		return
	var prompt := """You are an ally soldier in a horde-defense battle. %s
%s

Situation: %s

Reply in ONE short shouted combat line (max 12 words). Plain speech, no
quotes, no narration, no asterisks, no name prefix.""" % [persona, WORLD, situation]
	_queue.append({"who": who, "prompt": prompt, "tag": tag, "fallback": fallback})

func _send(job: Dictionary) -> void:
	_busy = true
	_elapsed = 0.0
	_current = job
	var body := JSON.stringify({
		"model": MODEL,
		"prompt": job["prompt"],
		"stream": false,
		"options": {"num_predict": MAX_TOKENS, "temperature": 0.85},
	})
	var err := _http.request(OLLAMA_URL, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail("request error %d" % err)

func _on_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# the startup warmup shares this callback -- it is NOT a real bark, must
	# never reach line_ready or it'd put "hi" above someone's head
	if _warming:
		_warming = false
		_busy = false
		_http.timeout = TIMEOUT        # back to the short gameplay leash
		warm = (code == 200)
		available = warm
		print("[HordeLLM] model '%s' %s" % [MODEL,
			"warm -- allies will bark via the LLM" if warm else "unavailable (HTTP %d) -- canned barks" % code])
		return
	if code != 200:
		_fail("HTTP %d" % code)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("response"):
		_fail("bad payload")
		return
	var text: String = str(parsed["response"]).strip_edges()
	# the model sometimes wraps the line in quotes -- strip it.
	text = text.trim_prefix("\"").trim_suffix("\"").strip_edges()
	if text == "":
		text = str(_current["fallback"])
	var who = _current["who"]
	if is_instance_valid(who):
		line_ready.emit(who, text, str(_current["tag"]))
	_busy = false
	_current = {}

func _fail(reason: String) -> void:
	push_warning("HordeLLM unavailable (%s) -- falling back to canned barks" % reason)
	if not _current.is_empty():
		var who = _current["who"]
		if is_instance_valid(who):
			line_ready.emit(who, str(_current["fallback"]), str(_current["tag"]))
	# one hard failure disables the LLM for the session rather than
	# stuttering on every subsequent call; combat keeps running on fallbacks.
	if reason.begins_with("HTTP") or reason.begins_with("request error"):
		available = false
	_busy = false
	_current = {}
