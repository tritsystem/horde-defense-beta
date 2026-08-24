# ⚠ Nothing in this folder is live (2026-07-25)

All ~20 scripts here (`archer.gd`, `brute.gd`, `elite.gd`, `frost.gd`, `ghost.gd`,
`magnet.gd`, `mirror.gd`, `necromancer.gd`, `plaguecreep.gd`, `rocketeer.gd`,
`scout.gd`, `shieldbearer.gd`, `snipercreep.gd`, `spitter.gd`, `stealth.gd`,
`summoner.gd`, `swarm.gd`, `thorns.gd`, `titan.gd`, `trapper.gd`, `vampire.gd`,
`witch.gd`) `extend BaseZombie` (`zombie/zombie.gd`), which is itself not
attached to any scene.

`Creepdeckmanager.gd`'s `ALL_CREEPS` table points at `.tscn` paths
(`res://scripts/RocketeerCreep.gd`, etc.) that don't exist anywhere in the
repo, and `get_scene_for_creep()` only ever tries to load a `.tscn`, never
falling back to attaching one of these `.gd` files directly — so it always
returns `null`. None of these creeps can currently be spawned in real
gameplay.

The creeps actually reachable in the live game (`main.tscn`'s
`attack_creep_scenes` / `defend_creep_scenes`) are: the base zombie, `tank.gd`,
`shaman.gd`, `berserk.gd`, and `leaper.gd` — all of which extend the **live**
`assets/weapons/resources/Player/zombie.gd` directly, not `BaseZombie`.

Editing files in this folder has no effect on gameplay right now. Some of
them (e.g. `brute.gd`) have real uncommitted work in progress (stagger
mechanics) — nothing here has been deleted — but if you want a creep's
ability to actually appear in-game, it needs to be ported to extend the live
zombie script and wired into `Creepdeckmanager.gd` / `main.tscn` for real.
