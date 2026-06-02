# ============================================================
# TutorialSystem.gd — FULL REWRITE WITH DEBUG
# ============================================================
# AutoLoad: Name=TutorialSystem  Path=res://scripts/TutorialSystem.gd
# Layer 210 — renders above PauseMenu (layer 200)
# ============================================================
extends CanvasLayer

# ── PALETTE ──────────────────────────────────────────────────
const C_GOLD      := Color(0.98, 0.82, 0.18, 1.0)
const C_GOLD_DIM  := Color(0.82, 0.65, 0.08, 0.65)
const C_GOLD_GLOW := Color(1.00, 0.92, 0.35, 1.0)
const C_BG        := Color(0.04, 0.04, 0.07, 0.97)
const C_CARD      := Color(0.07, 0.07, 0.05, 0.95)
const C_BORDER    := Color(0.90, 0.74, 0.12, 0.90)
const C_BORDER_DIM:= Color(0.68, 0.53, 0.08, 0.40)
const C_WHITE     := Color(0.92, 0.90, 0.86, 1.0)
const C_DIM       := Color(0.52, 0.54, 0.58, 1.0)

# ── PAGES DATA ───────────────────────────────────────────────
const PAGES : Array = [
	{
		"title": "⚔  WELCOME",
		"sections": [
			{ "heading": "What Is This Game?",
			  "body": "MOBA / Tower Defense hybrid. Two teams fight to destroy each other's BASE while commanding zombie armies down lanes.\n\nYou play in FPS — shooting enemies, using abilities, and enchanting your zombie horde — while issuing squad commands." },
			{ "heading": "The Two Phases",
			  "body": "▸ PREP PHASE — Press TAB to open the Shop. Buy zombies, turrets, upgrades. Press SPACE or READY to deploy.\n\n▸ COMBAT PHASE — Zombies march lanes automatically. You fight FPS. Destroy the enemy BASE to win." },
		],
		"highlights": [],
		"tip": "💡  TAB once = TopDown + Shop  |  TAB twice = TopDown play mode  |  TAB three times = back to FPS"
	},
	{
		"title": "🏪  THE SHOP  ——  [ TAB ]",
		"sections": [
			{ "heading": "Opening the Shop  →  TOP CENTER",
			  "body": "Press TAB to open the Shop. Camera shifts to top-down view.\n\nShop tabs along the top:\n🏰 TURRETS — buy and place gun turrets\n👤 PLAYER UPG — upgrade your stats\n🧟 CREEP UPG — global zombie buffs\n🧟 CREEPS — pick your zombie deck\n⚡ ABILITIES — equip Q/E/F abilities\n✦ CRYSTALS — boost enchant damage\n⚔ WEAPONS — upgrade guns and sword" },
			{ "heading": "Gold  ◆  —  TOP CENTER",
			  "body": "Your gold shows TOP CENTER between the timer and enemy count.\n\nEarn gold by killing enemies and completing rounds. Spend on turrets, zombies, and upgrades." },
		],
		"highlights": ["top_center"],
		"tip": "💡  TAB again (or ESC from shop) to enter TopDown play mode — shoot in top-down!"
	},
	{
		"title": "🧟  YOUR ZOMBIE ARMY",
		"sections": [
			{ "heading": "Buying Zombies  →  Shop → CREEPS tab",
			  "body": "Open Shop (TAB) → CREEPS tab. Click any zombie type to buy — they spawn at your base and march the lane automatically." },
			{ "heading": "Zombie Types",
			  "body": "🧟 Zombie — Basic cheap lane pusher\n🛡 Tank — Huge HP, taunts enemies\n⚡ Berserker — Enrages below 40% HP for +60% damage\n💚 Shaman — Heals allies, poisons enemies\n🦘 Leaper — Jumps to targets from 12m\n💣 Bomber — Explodes on death / contact\n💀 Boss — Round 6 VS AI only. Grabs + throws you for 60 damage" },
			{ "heading": "Squad Commands  →  BOTTOM strip",
			  "body": "[F/G] Select ALL zombies\n[Z] Toggle selection mode — click/drag to select\n[1] Attack  [2] Defend  [3] Patrol  [4] Stay  [5] Follow\n[ESC] Cancel pending command" },
		],
		"highlights": ["bottom"],
		"tip": "💡  FOLLOW mode = bodyguard. Zombies escort you and attack nearby enemies automatically."
	},
	{
		"title": "🔫  WEAPONS & ENCHANTS",
		"sections": [
			{ "heading": "Weapons  →  BOTTOM LEFT / RIGHT",
			  "body": "Weapon name = BOTTOM LEFT. Ammo = BOTTOM RIGHT.\n\nScroll wheel or 1-5 to switch weapons.\n\n🔵 Laser  🚀 Rocket  🔥 Flamethrower  🔵 Projectile  ⚔ Sword  🪝 Grappler" },
			{ "heading": "Sword Enchantments  →  [R] to cycle",
			  "body": "Hold Sword and press [R]:\n🔥 Fire — burn DoT\n❄ Ice — 60% slow 3s\n☠ Poison — poison DoT\n⚡ Electric — chains to nearby enemies\n✦ Shadow — +50% vs enemies below 40% HP\n🩸 Vampiric — heals you 30% of damage\n\n[G] Enchants nearby allied zombies with same element!" },
			{ "heading": "Enchant Weaknesses  →  +50% damage",
			  "body": "🔥 Fire ↔ ❄ Ice\n☠ Poison ↔ ⚡ Electric\n✦ Shadow ↔ 🩸 Vampiric\n\nHit a zombie affected by one element with its weakness for +50% bonus damage." },
		],
		"highlights": ["bottom_left", "bottom_right"],
		"tip": "💡  Upgrade enchant damage in Shop → CRYSTALS ✦ tab permanently."
	},
	{
		"title": "⚡  ABILITIES  ——  [Q]  [E]  [F]",
		"sections": [
			{ "heading": "Ability Bar  →  BOTTOM CENTER",
			  "body": "Three colored panels BOTTOM CENTER show your abilities.\n\n• Slot icon + name\n• Cooldown bar fills up as it recharges\n• Timer shows seconds remaining\n• Border pulses gold when READY" },
			{ "heading": "Equipping  →  Shop → ABILITIES",
			  "body": "Find trinkets near your base — walk over glowing orbs to collect.\n\n⚔ [Q] Attack — Rapid Fire, Death Mark, Berserker Rage…\n🛡 [E] Defense — Shield, Heal Burst, Iron Skin…\n🌀 [F] Motion — Dash, Sprint, Blink, Grapple…" },
		],
		"highlights": ["bottom_center"],
		"tip": "💡  Upgrade ability cooldowns in Shop → PLAYER UPG → Special Ability Upgrades."
	},
	{
		"title": "🏰  BASE & TURRETS",
		"sections": [
			{ "heading": "Base HP  →  TOP LEFT (orange bar)",
			  "body": "TOP LEFT shows two bars:\n• HP (green) — your personal health\n• BASE (orange) — shared base structure\n\nIf BASE hits zero → you lose. Protect it with turrets and defending zombies." },
			{ "heading": "Placing Turrets  →  Shop → TURRETS",
			  "body": "Buy a turret → placement ghost appears.\n🟦 Blue = valid  🟥 Red = invalid\n\nLMB: Place  |  RMB/ESC: Cancel  |  Scroll/[R]: Rotate\n\nTurrets auto-target ALL enemies in range including enemy player." },
		],
		"highlights": ["top_left"],
		"tip": "💡  Click any turret in top-down view to upgrade or repair it."
	},
	{
		"title": "🗺  MINIMAP & HUD",
		"sections": [
			{ "heading": "HUD Layout",
			  "body": "▸ TOP LEFT — HP (green) + BASE HP (orange) + Crystals ✦\n▸ TOP CENTER — Phase | Timer | Gold ◆ | Enemy count\n▸ TOP RIGHT — Minimap\n▸ BOTTOM LEFT — Weapon name\n▸ BOTTOM RIGHT — Ammo\n▸ BOTTOM CENTER — Ability panels [Q][E][F]\n▸ VERY BOTTOM — Squad Command Panel" },
			{ "heading": "Minimap  →  TOP RIGHT corner",
			  "body": "🟢 You (with facing arrow)  🔵 Your turrets  🟥 Enemy turrets\n🟦 Your base  🟥 Enemy base\n🔵 tiny = your zombies  🔴 tiny = enemy zombies" },
			{ "heading": "Sniper Scope  →  RMB",
			  "body": "Right-click to scope in. Circular lens view — black surround, game visible through lens.\n\n[C] Hold breath — reduces sway for precision\nHUD + squad panel auto-hide while scoped." },
		],
		"highlights": ["top_right", "top_left", "top_center"],
		"tip": "💡  Minimap fades when shop is open to avoid blocking the view."
	},
	{
		"title": "🌊  ROUNDS & VS AI",
		"sections": [
			{ "heading": "Round Structure",
			  "body": "Each round:\n1. Round card shows (name, enemy count, waves)\n2. PREP PHASE — shop + buy\n3. COMBAT — waves march your lanes\n4. Gold bonus awarded\n5. Next round begins" },
			{ "heading": "Wave Deploy  →  [SHIFT+Q]",
			  "body": "Press SHIFT+Q → Wave Deploy Panel (right side).\n\n[1-6] Select which wave your zombies deploy on\n[Shift+1-9] Queue a creep type\n[Shift+Q] Toggle open/close" },
			{ "heading": "VS AI Mode  →  Main Menu",
			  "body": "Toggle AI opponent from Main Menu → 🤖 VS AI.\n\nDifficulty: Easy / Medium / Hard / Nightmare\n\n💀 Round 6: BOSS ZOMBIE spawns — 4000 HP, 3 phases, grabs + throws you for 60 damage!" },
		],
		"highlights": ["top_center"],
		"tip": "💡  The AI buys creeps every wave — watch the minimap for sudden pushes."
	},
	{
		"title": "🎮  CONTROLS REFERENCE",
		"sections": [
			{ "heading": "Movement & Combat",
			  "body": "WASD — Move  |  MOUSE — Aim  |  LMB — Shoot\nRMB — Scope/cancel  |  SPACE — Jump  |  SHIFT — Sprint\nC — Hold breath  |  R — Reload (or cycle enchant on sword)" },
			{ "heading": "Weapons & Abilities",
			  "body": "SCROLL / 1-5 — Switch weapons\nG — Enchant zombies with sword element\nQ / E / F — Ability slots\nTAB — Shop cycle (Shop → Play mode → FPS)\nSHIFT+Q — Wave deploy panel" },
			{ "heading": "Squad Commands",
			  "body": "Z — Selection mode  |  F / G — Select all\n1 Attack  2 Defend  3 Patrol  4 Stay  5 Follow\nESC — Pause menu (or advance TAB cycle from shop)\nSPACE / ENTER (prep) — Ready up" },
		],
		"highlights": [],
		"tip": "💡  All keybinds shown on the Ability Bar and Squad Panel — you never need to memorize everything."
	},
]

# ── STATE ─────────────────────────────────────────────────────
var _visible      : bool = false
var _current_page : int  = 0
var _built        : bool = false

var _root         : Control       = null
var _page_title   : Label         = null
var _page_counter : Label         = null
var _content_vbox : VBoxContainer = null
var _tip_label    : Label         = null
var _tip_panel    : Control       = null
var _prev_btn     : Button        = null
var _next_btn     : Button        = null
var _dots_row     : HBoxContainer = null
var _hl_nodes     : Array         = []
var _hl_tween     : Tween         = null


# ── LIFECYCLE ─────────────────────────────────────────────────
func _ready() -> void:
	layer        = 210
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[TutorialSystem] _ready — layer=%d" % layer)
	_build_ui()
	_root.visible = false
	print("[TutorialSystem] ready complete. _built=%s" % str(_built))


# ── PUBLIC ────────────────────────────────────────────────────
func show_tutorial() -> void:
	print("[TutorialSystem] show_tutorial called. _built=%s _root valid=%s" % [str(_built), str(is_instance_valid(_root))])
	if not _built:
		push_error("[TutorialSystem] UI not built — _build_ui may have failed")
		_build_ui()
	_visible = true
	_root.visible = true
	_show_page(0)
	print("[TutorialSystem] visible=true root.visible=%s" % str(_root.visible))


func hide_tutorial() -> void:
	print("[TutorialSystem] hide_tutorial called")
	_visible = false
	if is_instance_valid(_root): _root.visible = false
	_clear_highlights()


func toggle_tutorial() -> void:
	print("[TutorialSystem] toggle — currently visible=%s" % str(_visible))
	if _visible: hide_tutorial()
	else:        show_tutorial()


func _return_to_pause() -> void:
	print("[TutorialSystem] _return_to_pause")
	hide_tutorial()


# ── INPUT ─────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not _visible: return
	if not (event is InputEventKey): return
	var kev := event as InputEventKey
	if not kev.pressed or kev.echo: return
	match kev.keycode:
		KEY_ESCAPE:
			_return_to_pause()
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			_show_page(_current_page - 1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_show_page(_current_page + 1)
			get_viewport().set_input_as_handled()


# ── BUILD UI ─────────────────────────────────────────────────
func _build_ui() -> void:
	print("[TutorialSystem] _build_ui start")

	# Clear any old root
	if is_instance_valid(_root): _root.queue_free()

	_root = Control.new()
	_root.name = "TutRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	print("[TutorialSystem] root added, child count=%d" % get_child_count())

	# Dark backdrop
	var bd := ColorRect.new()
	bd.name = "Backdrop"
	bd.set_anchors_preset(Control.PRESET_FULL_RECT)
	bd.color = Color(0.0, 0.0, 0.0, 0.82)
	bd.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bd)

	# Outer panel
	var panel := PanelContainer.new()
	panel.name = "TutPanel"
	panel.anchor_left   = 0.03; panel.anchor_right  = 0.97
	panel.anchor_top    = 0.04; panel.anchor_bottom = 0.96
	panel.mouse_filter  = Control.MOUSE_FILTER_STOP
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = C_BG
	sbox.set_border_width_all(2); sbox.border_color = C_BORDER
	sbox.set_corner_radius_all(10)
	sbox.content_margin_left = 28; sbox.content_margin_right  = 28
	sbox.content_margin_top  = 18; sbox.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sbox)
	_root.add_child(panel)

	var root_vb := VBoxContainer.new()
	root_vb.add_theme_constant_override("separation", 12)
	panel.add_child(root_vb)

	# ── Header ───────────────────────────────────────────────
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 8)
	root_vb.add_child(hdr)

	var icon := Label.new()
	icon.text = "📖"
	icon.add_theme_font_size_override("font_size", 28)
	hdr.add_child(icon)

	_page_title = Label.new()
	_page_title.name = "PageTitle"
	_page_title.add_theme_font_size_override("font_size", 22)
	_page_title.add_theme_color_override("font_color", C_GOLD)
	_page_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(_page_title)

	_page_counter = Label.new()
	_page_counter.name = "PageCounter"
	_page_counter.add_theme_font_size_override("font_size", 12)
	_page_counter.add_theme_color_override("font_color", C_GOLD_DIM)
	_page_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_page_counter.custom_minimum_size.x = 55
	hdr.add_child(_page_counter)

	var back := _mk_btn("← MENU", Color(0.10, 0.12, 0.22, 0.95), func(): _return_to_pause())
	back.add_theme_color_override("font_color", Color(0.70, 0.78, 0.95))
	back.add_theme_font_size_override("font_size", 12)
	back.custom_minimum_size = Vector2(78, 32)
	hdr.add_child(back)

	var close := _mk_btn("✕", Color(0.32, 0.06, 0.06, 0.95), func(): _return_to_pause())
	close.custom_minimum_size = Vector2(32, 32)
	close.add_theme_font_size_override("font_size", 15)
	hdr.add_child(close)

	# Gold divider line
	var div := ColorRect.new()
	div.color = C_BORDER
	div.custom_minimum_size = Vector2(0, 2)
	root_vb.add_child(div)

	# ── Scroll / Content ─────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "ContentScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vb.add_child(scroll)

	_content_vbox = VBoxContainer.new()
	_content_vbox.name = "ContentVBox"
	_content_vbox.add_theme_constant_override("separation", 12)
	_content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content_vbox)

	# ── Tip panel ────────────────────────────────────────────
	_tip_panel = PanelContainer.new()
	_tip_panel.name = "TipPanel"
	var tp := StyleBoxFlat.new()
	tp.bg_color = Color(0.10, 0.08, 0.02, 0.95)
	tp.set_border_width_all(1); tp.border_color = Color(0.90, 0.70, 0.10, 0.6)
	tp.set_corner_radius_all(5)
	tp.content_margin_left = 12; tp.content_margin_right  = 12
	tp.content_margin_top  = 6;  tp.content_margin_bottom = 6
	_tip_panel.add_theme_stylebox_override("panel", tp)
	root_vb.add_child(_tip_panel)

	_tip_label = Label.new()
	_tip_label.name = "TipLabel"
	_tip_label.add_theme_font_size_override("font_size", 13)
	_tip_label.add_theme_color_override("font_color", C_GOLD)
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tip_panel.add_child(_tip_label)

	# ── Nav row ──────────────────────────────────────────────
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 10)
	root_vb.add_child(nav)

	_prev_btn = _mk_nav_btn("◀  PREV", func(): _show_page(_current_page - 1))
	nav.add_child(_prev_btn)

	_dots_row = HBoxContainer.new()
	_dots_row.name = "DotsRow"
	_dots_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots_row.add_theme_constant_override("separation", 8)
	nav.add_child(_dots_row)

	for i in PAGES.size():
		var dot := Label.new()
		dot.name = "Dot%d" % i
		dot.text = "●"
		dot.add_theme_font_size_override("font_size", 10)
		dot.add_theme_color_override("font_color", C_GOLD_DIM)
		dot.mouse_filter = Control.MOUSE_FILTER_STOP
		var _i := i
		dot.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
				_show_page(_i))
		_dots_row.add_child(dot)

	_next_btn = _mk_nav_btn("NEXT  ▶", func(): _show_page(_current_page + 1))
	nav.add_child(_next_btn)

	_built = true
	print("[TutorialSystem] _build_ui complete — refs: title=%s counter=%s content=%s prev=%s next=%s dots=%s" % [
		str(is_instance_valid(_page_title)),
		str(is_instance_valid(_page_counter)),
		str(is_instance_valid(_content_vbox)),
		str(is_instance_valid(_prev_btn)),
		str(is_instance_valid(_next_btn)),
		str(is_instance_valid(_dots_row)),
	])


# ── PAGE LOGIC ────────────────────────────────────────────────
func _show_page(idx: int) -> void:
	_current_page = clampi(idx, 0, PAGES.size() - 1)
	print("[TutorialSystem] _show_page %d / %d" % [_current_page, PAGES.size()-1])
	var pg : Dictionary = PAGES[_current_page]

	if not is_instance_valid(_page_title):
		push_error("[TutorialSystem] _page_title is null — rebuild"); _build_ui()
	if not is_instance_valid(_content_vbox):
		push_error("[TutorialSystem] _content_vbox is null"); return

	_page_title.text   = pg["title"]
	_page_counter.text = "%d / %d" % [_current_page + 1, PAGES.size()]

	# Clear old sections
	for ch in _content_vbox.get_children(): ch.queue_free()

	# Build sections
	for sec in pg["sections"]:
		_add_section(sec.get("heading",""), sec.get("body",""))

	# Tip
	var tip : String = pg.get("tip", "")
	if is_instance_valid(_tip_label):   _tip_label.text = tip
	if is_instance_valid(_tip_panel):   _tip_panel.visible = tip != ""

	# Nav buttons
	if is_instance_valid(_prev_btn): _prev_btn.disabled = _current_page == 0
	if is_instance_valid(_next_btn): _next_btn.disabled = _current_page >= PAGES.size() - 1

	# Dots
	if is_instance_valid(_dots_row):
		for i in _dots_row.get_child_count():
			var d := _dots_row.get_child(i) as Label
			if not is_instance_valid(d): continue
			d.add_theme_color_override("font_color",
				C_GOLD_GLOW if i == _current_page else C_GOLD_DIM)
			d.add_theme_font_size_override("font_size",
				16 if i == _current_page else 10)

	# Highlights
	_clear_highlights()
	var areas : Array = pg.get("highlights", [])
	if not areas.is_empty(): _spawn_highlights(areas)

	print("[TutorialSystem] page %d rendered OK" % _current_page)


func _add_section(heading: String, body: String) -> void:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sty := StyleBoxFlat.new()
	sty.bg_color = C_CARD
	sty.set_border_width_all(1); sty.border_color = C_BORDER_DIM
	sty.set_corner_radius_all(6)
	sty.content_margin_left = 16; sty.content_margin_right  = 16
	sty.content_margin_top  = 10; sty.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", sty)
	_content_vbox.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	card.add_child(col)

	# Heading
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 8)
	col.add_child(hdr_row)

	var bar := ColorRect.new()
	bar.color = C_GOLD
	bar.custom_minimum_size = Vector2(3, 0)
	bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(bar)

	var h := Label.new()
	h.text = heading
	h.add_theme_font_size_override("font_size", 14)
	h.add_theme_color_override("font_color", C_GOLD)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(h)

	# Body
	var b := Label.new()
	b.text = body
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", C_WHITE)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(b)


# ── HIGHLIGHTS ────────────────────────────────────────────────
func _spawn_highlights(areas: Array) -> void:
	var vp := get_viewport().get_visible_rect().size
	for area in areas:
		var r : Rect2 = _area_rect(area)
		if r == Rect2(): continue

		var fill := ColorRect.new()
		fill.position     = r.position; fill.size = r.size
		fill.color        = Color(C_GOLD.r, C_GOLD.g, C_GOLD.b, 0.0)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(fill); _hl_nodes.append(fill)

		for edge in [
			[r.position,                         Vector2(r.size.x, 2)],
			[Vector2(r.position.x, r.end.y-2),   Vector2(r.size.x, 2)],
			[r.position,                         Vector2(2, r.size.y)],
			[Vector2(r.end.x-2, r.position.y),   Vector2(2, r.size.y)],
		]:
			var er := ColorRect.new()
			er.position = edge[0]; er.size = edge[1]; er.color = C_GOLD
			er.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_root.add_child(er); _hl_nodes.append(er)

		var lbl := Label.new()
		lbl.text = "◀ HERE"
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", C_GOLD_GLOW)
		lbl.position = Vector2(
			clampf(r.end.x + 5, 0, vp.x - 85),
			clampf(r.position.y + r.size.y * 0.5 - 10, 0, vp.y - 26))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(lbl); _hl_nodes.append(lbl)

	if is_instance_valid(_hl_tween): _hl_tween.kill()
	_hl_tween = create_tween().set_loops()
	for n in _hl_nodes:
		if n is ColorRect and n.size.x > 10 and n.size.y > 10:
			_hl_tween.tween_property(n, "color:a", 0.18, 0.7).set_trans(Tween.TRANS_SINE)
			_hl_tween.tween_property(n, "color:a", 0.0,  0.7).set_trans(Tween.TRANS_SINE)


func _area_rect(area: String) -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	match area:
		"top_left":      return Rect2(0,           0,          vp.x*0.26, vp.y*0.13)
		"top_center":    return Rect2(vp.x*0.28,   0,          vp.x*0.44, vp.y*0.13)
		"top_right":     return Rect2(vp.x*0.77,   0,          vp.x*0.23, vp.y*0.24)
		"bottom":        return Rect2(0,           vp.y*0.83,  vp.x,      vp.y*0.17)
		"bottom_left":   return Rect2(0,           vp.y*0.86,  vp.x*0.28, vp.y*0.10)
		"bottom_right":  return Rect2(vp.x*0.73,  vp.y*0.82,  vp.x*0.27, vp.y*0.12)
		"bottom_center": return Rect2(vp.x*0.27,  vp.y*0.775, vp.x*0.46, vp.y*0.09)
	return Rect2()


func _clear_highlights() -> void:
	if is_instance_valid(_hl_tween): _hl_tween.kill()
	for n in _hl_nodes:
		if is_instance_valid(n): n.queue_free()
	_hl_nodes.clear()


# ── BUTTON HELPERS ────────────────────────────────────────────
func _mk_btn(text: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", C_WHITE)
	b.add_theme_font_size_override("font_size", 14)
	var n := StyleBoxFlat.new(); n.bg_color = col; n.set_corner_radius_all(4)
	var h := StyleBoxFlat.new(); h.bg_color = col.lightened(0.2); h.set_corner_radius_all(4)
	b.add_theme_stylebox_override("normal",  n)
	b.add_theme_stylebox_override("hover",   h)
	b.add_theme_stylebox_override("pressed", n)
	b.add_theme_stylebox_override("focus",   n)
	b.pressed.connect(cb)
	return b


func _mk_nav_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120, 40)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", C_GOLD)
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.10, 0.09, 0.02, 0.95)
	n.set_border_width_all(1); n.border_color = C_BORDER; n.set_corner_radius_all(5)
	var d := StyleBoxFlat.new()
	d.bg_color = Color(0.07, 0.07, 0.02, 0.5)
	d.set_border_width_all(1); d.border_color = C_BORDER_DIM; d.set_corner_radius_all(5)
	b.add_theme_stylebox_override("normal",   n)
	b.add_theme_stylebox_override("hover",    n)
	b.add_theme_stylebox_override("pressed",  n)
	b.add_theme_stylebox_override("focus",    n)
	b.add_theme_stylebox_override("disabled", d)
	b.pressed.connect(cb)
	return b
