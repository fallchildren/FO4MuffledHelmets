# MuffledHelmets — Papyrus review TODO

Review of `Data/Scripts/Source/MuffledHelmets.psc` and `native/src/plugin.cpp`
against the archived CK Wiki (`fallout.wiki/wiki/Resource:Creation_Kit`).

Nothing here has been implemented yet. Items are grouped by kind; the priority
order at the bottom is the suggested fix sequence.

Reference IDs (`B…` bug, `C…` correctness, `P…` performance, `S…` structure,
`D…` docs) are stable so we can say "fix B2" in commits and issues.

---

## Bugs

### [x] B1 — A stimpak (or any non-armour) un-muffles the player
`OnItemEquipped` passes `akBaseObject as Armor` to `apply_player_voice_helmet()`,
i.e. a single item instead of the worn state. Equipping a potion or a weapon
passes `None` -> `SetPlayerVoice(0, 0)` and the mask stops muffling until the
next equip event. `OnItemUnequipped` already does the right thing
(`update_player_voice()`).

Fix: make both handlers re-evaluate the worn state, e.g.
`if native_ok && (akBaseObject as Armor) != None` -> `update_player_voice()`.

### [ ] B2 — The NPC lease dies during VATS / menus

Papyrus mitigation implemented: the lease now has a 20 s floor. Native
game-time expiry remains open.
`StartTimer`/`OnTimer` are affected by the global time modifier and never fire
in menu mode (`Resource:Creation Kit/StartTimer - ScriptObject`,
`OnTimer - ScriptObject`), while the plugin expires leases on
`std::chrono::steady_clock`, i.e. real time. A menu/VATS pause longer than the
lease pops muffled NPCs back to vanilla. The lease is `(interval * 4) + 1` =
5 s at the 1.0 s default.

Fixes:
- Papyrus (cheap): a lease with a floor that absorbs dilation, e.g.
  `max(interval * 4, 15) + 5`, computed in one helper.
- Native (correct): base expiry on game/`RE::Calendar` time, not steady_clock.

See also D3 — the contract is split across two files.

### [x] B3 — Double MCM registration across loads
`startup()` runs from both `OnQuestInit` and `OnPlayerLoadGame` and calls
`RegisterForExternalEvent("OnMCMSettingChange|MuffledHelmets", ...)` every
time, with no matching unregister (none exists in the API). After N loads the
handler fires N times.

Fix: guard with a `mcm_registered` bool.

### [x] B4 — The script can go permanently dead if F4SE/MCM loads late
`native_ok` and `mcm_read` are latched once in `startup()`. If
`F4SE.GetPluginVersion("MuffledHelmetsNative")` is not ready at that instant,
`native_ok` stays false for the session and `read_mcm_settings()` bails too.
No retry, no recovery.

Fix: re-check on a timer (or on a later message) until the plugin is seen.

### [x] B5 — Stale-save unregister block is unsafe for the future
`startup()` unconditionally unregisters `PipboyMenu` open/close,
`OnMenuOpenCloseEvent` and `OnRaceSwitchComplete` remote events. This version
never registers them, so it is a migration workaround — but it silently breaks
if a later version needs any of them.

Fix: gate on a `save_version` marker (see S5) and retire the block once the
migration window closes.

### [x] B6 — Lookups on possibly-empty arrays
`blacklist`, `forcelist`, `clothlist` are only filled by `initialize_lists()`.
If `should_muffle()` ever runs first (old save with a live quest script, partial
re-init), `array.Find(...)` runs on an empty/None array.

Fix: `if blacklist.Length > 0 && ...` (same for the other two).

### [x] B7 — `-1` sentinel can match in FormID lists
`get_form_id_maybe()` returns `-1` for an absent mod, and those values are put
into `blacklist`/`forcelist`/`clothlist` and searched with `Find`.

Fix: use `0` for "absent" and guard with `> 0` at the lookup sites.

---

## Correctness / semantics

### [ ] C1 — `has_slot_mask(...)` fallback is dead or redundant
`GetWornItem` (`Resource:Creation Kit/GetWornItem - Actor`) documents armor slot
precedence head-to-toe: an armour only exists on its *highest* covered biped
slot. So an EYE+MOUTH item is returned on slot 17 and the
`kw_mouth_slot && kw_eye_slot` branch already covers it; the trailing
`has_slot_mask(armo, kSlotMask49) && has_slot_mask(armo, kSlotMask47)` duplicates
it (or the keyword branch does).

Fix: keep exactly one path, add a comment explaining slot 17, and point out that
`kSlotMask47`/`kSlotMask49` are slot *masks*, not biped slot indices.

### [ ] C2 — Equip handler ignores that a helmet swap is really an unequip
Equipping helmet B displaces A in the same slot. It currently resolves only
because the engine also fires `OnItemUnequipped`; relying on event ordering is
fragile. `update_player_voice()` on both events removes the assumption (also
fixes B1).

### [ ] C3 — MCM settings can silently fall back to defaults forever
If `F4MCM` is present but not yet loaded during `startup()`,
`read_mcm_settings()` bails, `mcm_read` stays false, and every getter returns
defaults for the whole session with no retry and no notification.

### [ ] C4 — The 3-NPC cap is applied in scan order, not by relevance
`npc_scan()` accepts the first 3 muffled NPCs in `FindAllReferencesWithKeyword`
order. With 4+ muffled NPCs nearby, *which* 3 are muffled is arbitrary and can
change between ticks.

### [ ] C5 — No hysteresis on the watch list
The accepted set is rebuilt from scratch every tick, so an NPC at the boundary
of the cap flickers instead of being sticky.

---

## Performance

### [ ] P1 — `FindAllReferencesWithKeyword` allocates a full actor array every second
Every tick builds an array of every actor in a ~36 m sphere (dozens to hundreds
in dense areas) on the main thread, forever. The `GetDistance` page recommends
distance registration over polling.

Possible redesign: track a `RefCollectionAlias` of nearby NPCs (`OnLoad` /
`OnUnload` / `OnDeath`) and `RegisterForDistanceLessThanEvent` rather than
rescanning. Keep the quest timer for re-leasing only.

### [ ] P2 — `should_muffle()` does ~10 native `HasKeyword` calls per candidate per tick
It is a pure function of the form. Cache the result keyed by FormID in parallel
`Form[]` / `int[]` arrays (0 unknown, 1 muffled, 2 cloth, -1 ignore), filled
lazily inside `should_muffle()`. Turns the per-tick cost into one int compare.
Biggest single win, ~40 lines.

### [ ] P3 — `SetActorVoice` is called every tick even when nothing changed
Idempotent on the C++ side, but it still crosses the script->native boundary and
takes the plugin mutex for each of the 3 NPCs, every tick.

Fix: remember the last model per NPC and only call when it changes; let the
lease renewal be the only periodic call.

### [ ] P4 — Up to 23 `GetWornItem` calls per NPC per tick
`head_only` already narrows this to 11 slots, but it is still called for every
loaded NPC, including the majority with no helmet. Mostly fixed by P2.

### [ ] P5 — Four setting-getter calls per tick
`setting_npc_voices()`, `npc_radius()`, `npc_interval()`, `setting_all_slots()`
are each called (and re-evaluated) inside `npc_scan()`. Cache into locals at the
top of the scan.

### [ ] P6 — Redundant recomputation of `npc_interval()`
It is called inside the lease expression *and* for `StartTimer`, plus
`npc_radius()` in the keyword search. Compute once per scan.

---

## Structure / maintainability

### [ ] S1 — Hardcoded FormID lists belong in the ESP
`blacklist` / `forcelist` / `clothlist` (~90 lines, plus a new entry for every
mod-support request) are data, not logic. Move them to `FLST`/`KYWD` forms in
`muffledhelmets.esp`: removes the code, slashes `.pex` churn, and lets users
patch compatibility without a script recompile.

### [ ] S2 — Manual index assignment instead of array literals
`arr = new int[32]` followed by `arr[0] = ...; arr[1] = ...` is noisy and
error-prone (size vs. number of assignments). Build them in a loop from a list,
or retire them entirely via S1.

### [ ] S3 — `should_muffle()` casts `item as Armor` three times
Cast once, keep the result in `armo`, and pass it to
`is_blacklisted()` / `is_force()` / `is_cloth()`.

### [ ] S4 — `has_slot_mask()` naming
It is `Global` only for calling convenience, but the name reads like a biped
slot test. Rename and/or comment (see C1).

### [ ] S5 — No `save_version` / migration marker
The "unregister what older versions registered" block is undated and grows every
release. Add an `int save_version` bumped on breaking changes, and decide
cleanup explicitly per version (also enables B5).

### [ ] S6 — No diagnostic when the ESP forms fail to resolve
`get_form_id_maybe()` returning `0`/`-1` for a missing DLC or a broken
`muffledhelmets.esp` is silent. If the SOPM forms do not resolve, the script
keeps calling native functions with `0` and muffles nothing, with no trace
message.

---

## Docs

### [ ] D1 — README vs. plugin comment disagree on the NPC limit
README says 3 NPCs is "the limit of the engine's audio table"; the plugin
comment says it is hash-table headroom in `outputOverrideMap`. Make them agree.

### [ ] D2 — `MuffledHelmetsNative.psc` documents a lease default the script never uses
It says "default 10s", but the script always passes an explicit lease. Either
state the contract ("always pass a lease") or drop the default.

### [ ] D3 — The lease time-base assumption is undocumented
The Papyrus timer (game time, paused in menus) and the plugin expiry
(steady_clock) are combined with no shared statement of the assumption — which
is how B2 slipped in. Document it in both files.

---

## Suggested order

1. **B1, B2, B3, B4** — user-visible breakage.
2. **P2, P3** — removes most of the per-tick cost, small diff.
3. **B6, B7, C1** — cheap hygiene in `should_muffle()`.
4. **S1, S5** — payoff compounds on every release.
5. **P1 / C4 / C5** — watch-list redesign, only if profiling justifies it.
6. Everything else as cleanup.

## Not planned

Attaching an `Actor Script` to NPCs to get per-actor `OnItemEquipped` is **not**
planned: alias fill still needs the distance query, equip events also fire for
potions/weapons/ammo (more events, not fewer), a helmet swap still has to be
resolved with `GetWornItem`, and every attached script is serialised into the
save. Actor/alias events are worth using only as the *membership feed* for the
watch list in P1 (`OnLoad` / `OnUnload` / `OnDeath`), not as the classifier.
