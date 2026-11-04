# MuffledHelmets-native

The F4SE plugin of MuffledHelmets. It provides two generic functions to Papyrus:
* `bool MuffledHelmetsNative.SetPlayerVoice(int aiModel2D, int aiModel3D)`
  (passing 0, 0 restores the vanilla player voice models 0x87E40, 0x87E41).
* `bool MuffledHelmetsNative.SetActorVoice(int aiActorFormID, int aiModel3D, int aiLeaseSeconds = 0)`
  (passing aiModel3D = 0 removes the override).

The plugin is completely decoupled from any game forms or ESP files: Papyrus resolves
and passes the exact sound output model (SOPM) FormIDs to apply.

* the player's two voice entries ("Root" nodes) in
  `BSAudioManager::outputOverrideMap` get their output model replaced in place;
  the plugin re-asserts them every second because the engine rewrites them when
  the player's 3D is rebuilt. Only entries that currently hold one of the known
  voice models are touched, so voice changes by other mods are left alone;
* for other actors it registers `Head node -> muffled 3D output model` as a
  *lease* (default 10 s, renewed by calling again). Expired, unloaded or changed
  entries are removed by the plugin; at most 3 at a time because
  the table must never rehash while the audio thread reads it;
* all writes happen on the game thread (F4SE task) and are SEH-guarded.

No configuration file; the NPC settings are in the MCM.
Log: `Documents/My Games/Fallout4/F4SE/MuffledHelmetsNative.log`.

## Build (Linux, cross-compile)

From the repository root, `make native` (or plain `make`) bootstraps the toolchain
and builds the DLL; see the top-level README. Directly from this directory:

Needs `clang-cl`, `llvm-lib`, and the toolchain in `../.toolchain`
(`xwin` splat of the Windows SDK/CRT, `rust-lld` as linker).

    git submodule update --init --recursive
    make            # build/MuffledHelmetsNative.dll
    make libs       # only commonlibf4 + commonlib-shared + spdlog

The DLL is a normal Windows PE; it runs under Proton like any F4SE plugin.

## Test under Steam/Proton

Requirements on the game machine:
* Next-Gen/current Fallout 4 and a matching F4SE (`f4se_loader.exe` start)
* Address Library for F4SE with a `version-1-11-<build>-0.bin` for the
  installed game build in `Data/F4SE/Plugins/`

Copy `build/MuffledHelmetsNative.dll` to `Data/F4SE/Plugins/` and start the game
via F4SE. The plugin log is written inside the Proton prefix:

    <steam library>/steamapps/compatdata/377160/pfx/drive_c/users/steamuser/
        Documents/My Games/Fallout4/F4SE/MuffledHelmetsNative.log

(F4SE's own `f4se.log` is in the same folder and shows load errors, e.g. an
unsupported runtime version.)

The plugin declares `F4SE::RUNTIME_LATEST` (currently 1.11.240) as compatible;
adjust `CompatibleVersions` in `src/plugin.cpp` if the installed build differs.

## How it was found (engine notes, game 1.11.240, F4SE 0.7.9)

* `BSAudioManager::outputOverrideMap` is a node -> output model map. Layout
  verified on this build: capacity at +0x0C, free count at +0x10, entries
  pointer at +0x28, slots of key/value/next = 24 bytes (`next != 0` = slot in
  use). The library's own iterator faults; the raw walk works. In the vanilla
  state it has 4 entries, all for the player; the capacity of 8 leaves room for 3
  more entries before it would rehash, hence the NPC limit.
* Two entries are keyed by `"Root"` nodes and hold the player's voice output
  models: vanilla `00087E41` (3D) and `00087E40` (2D). Replacing the values in
  place changes the player's voice.
* An NPC's voice line follows the actor's `"Head"` node (parent `"Neck"`).
  Inserting `Head -> muffled 3D output model` muffles it; inserts and erases
  from an F4SE main-thread task are safe.
* Earlier versions had a read-only "probe" mode (dumps of the audio tables around
  equip events and while NPCs speak); it was removed once the above was known.
