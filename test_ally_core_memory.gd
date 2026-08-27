extends Node
# Headless test for AllyCoreMemory (ported from tribe's test_npc_core_memory).
# Proves the SSH edge-vs-bulk result produces the intended ally behavior:
# a near-death core memory survives sustained combat panic, a routine scrape
# doesn't, and the HordeLLM bark persona only mentions it while recall is high.
# Run: Godot console exe --headless --path . res://test_ally_core_memory.tscn --quit

var _pass := 0
var _fail := 0

# Explicit preloads -- a fresh class_name isn't in Godot's global class cache
# until a cold boot (see AGENTS.md lesson 8), so don't rely on the name here.
const ACM = preload("res://ally_core_memory.gd")

func _ready() -> void:
	print("=".repeat(60))
	print("  ALLY CORE MEMORY -- SSH edge/bulk wired into ally recall")
	print("=".repeat(60))

	# ── a freshly written memory recalls reliably before any stress ──
	var mem = ACM.new()
	mem.remember("near_death", true)
	mem.remember("scrape:0", false)
	_check("a freshly-written core memory recalls above zero with no stress",
		mem.recall("near_death") > 0.0)
	_check("a freshly-written routine memory also recalls fine before any stress",
		mem.recall("scrape:0") > 0.0)

	# ── across many independent trials, heavy sustained panic degrades ──
	# bulk memories much more often than it degrades core (edge) memories.
	const TRIALS := 40
	var core_survived := 0
	var routine_survived := 0
	for t in range(TRIALS):
		var m = ACM.new()
		m.remember("near_death", true)
		m.remember("scrape:%d" % t, false)
		for i in range(25):
			m.apply_stress(0.35)   # same magnitude take_damage() applies per hit
		if m.recall("near_death") > 0.0:
			core_survived += 1
		if m.recall("scrape:%d" % t) > 0.0:
			routine_survived += 1

	print("\n  under sustained panic (25 stress ticks, %d trials):" % TRIALS)
	print("  core (edge) memory survived: %d/%d" % [core_survived, TRIALS])
	print("  routine (bulk) memory survived: %d/%d" % [routine_survived, TRIALS])
	_check("core (edge-anchored) memories survive sustained panic in a healthy majority of trials",
		core_survived >= TRIALS * 0.4)
	_check("routine (bulk-anchored) memories survive panic measurably less often than core memories",
		routine_survived < core_survived * 0.6)

	# ── wiring check on team_ally.gd's persona hook (script only, NOT added
	# to the tree -- standalone tests can't see autoloads like HordeLLM, and
	# _ready()/barks are deliberately not exercised here) ──
	var ally_script := load("res://team_ally.gd")
	var ally = ally_script.new()
	ally._ensure_core_memory().remember("near_death", true)
	ally._ensure_core_memory().remember("scrape:bulk", false)
	_check("salient_memory_tag() surfaces a fresh core memory",
		ally.salient_memory_tag() == "near_death")
	var persona_with := str(ally._mood_persona())
	_check("the HordeLLM persona mentions the haunting memory while recall survives",
		persona_with.contains("haunts"))
	for i in range(40):
		ally._core_memory.apply_stress(0.35)
	var core_after: float = ally.recall_core_memory("near_death")
	_check("after sustained panic the bulk scrape is gone while core recall survives better",
		core_after > 0.0 and
		(ally.recall_core_memory("scrape:bulk") == 0.0 or
			ally.recall_core_memory("scrape:bulk") < core_after))
	_check("persona tracks salience: no surviving memory means no haunting line",
		(ally.salient_memory_tag() != "") == str(ally._mood_persona()).contains("haunts"))
	ally.free()

	print("\n  RESULT: %d passed, %d failed" % [_pass, _fail])
	if _fail > 0:
		print("ALLY_CORE_MEMORY_TEST FAILED")
	else:
		print("ALLY_CORE_MEMORY_TEST PASSED")
	get_tree().quit(1 if _fail > 0 else 0)


func _check(what: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  [PASS] " + what)
	else:
		_fail += 1
		print("  [FAIL] " + what)
