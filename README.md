# MuffledHelmets

Fallout 4 mod that muffles the voice of the player **and of nearby NPCs** while
they wear a helmet, mask or hood. It consists of a Papyrus script, which decides
who sounds muffled, and an F4SE plugin (`native/`), which changes the voice.
Requires F4SE and the Address Library for your game build.

This repository builds the release archive on Linux from a bare checkout:

    git clone --recurse-submodules <repo-url> MuffledHelmets
    cd MuffledHelmets
    make ACCEPT_MS_LICENSE=1      # first run only, see "Microsoft license"
    # later runs: just `make`

The result is `build/MuffledHelmets-<version>.7z` with the same layout as the
released mod:

    Data/Scripts/MuffledHelmets.pex, MuffledHelmetsNative.pex
    Data/Scripts/Source/MuffledHelmets.psc, MuffledHelmetsNative.psc
    Data/muffledhelmets.esp
    Data/F4SE/Plugins/MuffledHelmetsNative.dll
    Data/MCM/Config/MuffledHelmets/config.json, settings.ini

## What `make` does

`make` (= `make all`) runs these steps, doing only what is out of date:

1. **check prerequisites** (`tools/check-deps.sh`, installs nothing)
2. **submodules** (`git submodule update --init --recursive`)
3. **toolchain**: `cargo install xwin` into `.toolchain/`, then downloads the
   Windows SDK + MSVC CRT with it (needed to cross-compile the F4SE plugin)
4. **Caprica**: builds the submodule (`fallchildren/Caprica`, Linux-ported fork)
   with cmake into `build/caprica/`
5. **headers**: merges the Bethesda base scripts and F4SE's additions from
   `third_party/f4se` into `build/headers/` (`tools/merge_headers.py`)
6. **pex**: compiles `Data/Scripts/Source/MuffledHelmets.psc` with Caprica
7. **native**: cross-builds the F4SE plugin DLL (`native/`)
8. **package**: builds the `.7z`

Everything it downloads or builds stays inside this directory
(`.toolchain/`, `build/`, `native/build/`); nothing is installed system-wide.

## Prerequisites

Install these yourself; `make` only checks for them
(`make check-deps` runs just the check).

| Need | Used for |
|------|----------|
| `git`, `make`, `python3`, `pkg-config` | everything |
| `cmake`, `g++` with C++23 (GCC 13+) | building Caprica |
| `boost` (filesystem, program_options, container), `fmt`, `pugixml` (dev packages) | Caprica's libraries |
| Rust via **rustup** (`cargo`, `rustc`) | builds `xwin`; its bundled `rust-lld` is the linker for the plugin |
| `clang` (provides `clang-cl`) and `llvm` (provides `llvm-lib`) | cross-compiling the plugin |
| `7z` (7-Zip; `7z`, `7zz` or `7za`) | packaging |

Arch Linux:

    sudo pacman -S --needed base-devel git cmake boost fmt pugixml clang llvm \
        rustup 7zip python pkgconf
    rustup default stable

Other distributions need the equivalent packages (names differ, e.g.
`libboost-all-dev libfmt-dev libpugixml-dev` on Debian/Ubuntu); rustup comes
from <https://rustup.rs>.

Tested with GCC 16.2, clang 22.1, cmake 4.4, boost 1.92, fmt 12.2,
pugixml 1.16, Rust 1.97, 7-Zip 26.03.

## Microsoft license

The plugin is built for Windows (it runs under Proton/Wine), so the build
needs the Windows SDK and MSVC CRT headers/libraries. `xwin` downloads them
from Microsoft. Their license has to be accepted by you, so the toolchain step
refuses to run until you pass `ACCEPT_MS_LICENSE=1`:

    make ACCEPT_MS_LICENSE=1

Only needed the first time (while `.toolchain/xwin/.splat-done` does not exist).
Use `XWIN_CACHE=/path` to keep the download cache elsewhere.

## Targets and variables

| Target | |
|--------|-|
| `all` (default) | everything: pex, native, package |
| `bootstrap` | only the external pieces (steps 1-5), no mod build |
| `pex` | compile the Papyrus script |
| `native` | build the F4SE plugin DLL (`native/build/MuffledHelmetsNative.dll`) |
| `package` | build the `.7z` |
| `clean` | remove build outputs, keep Caprica/headers/toolchain |
| `distclean` | `clean` + Caprica build, headers |
| `mrproper` | `distclean` + delete `.toolchain/` |

| Variable | Default | |
|----------|---------|-|
| `ACCEPT_MS_LICENSE` | (empty) | set to `1` to accept the Microsoft SDK license |
| `VERSION` | nearest Git tag | archive name; must match the plugin version in `plugin.cpp` |
| `JOBS` | `nproc` | parallelism |
| `XWIN_VERSION`, `XWIN_CACHE` | `0.10.0`, `.toolchain/xwin-cache` | xwin install |

## Layout

    Makefile                    build entry point
    Data/                       mod files as they appear in the game directory
      Scripts/Source/MuffledHelmets.psc, MuffledHelmetsNative.psc
      MCM/Config/MuffledHelmets/config.json, settings.ini
      muffledhelmets.esp
    native/                     F4SE plugin (own Makefile and README)
      extern/commonlibf4        submodule (libxse/commonlibf4)
      extern/spdlog             submodule
    third_party/Caprica         submodule (fallchildren/Caprica fork, Linux port)
    third_party/f4se            submodule (ianpatt/f4se, source of the script headers)
    tools/                      check-deps.sh, merge_headers.py, stubs/ (compile-time MCM.psc)
    .toolchain/                 downloaded tools (ignored): xwin, Windows SDK/CRT
    build/                      outputs (ignored)

## How the voice is changed

The Papyrus script (`MuffledHelmets.psc`) decides *which* actors should sound
muffled (keywords, slots, lists). The F4SE plugin (`native/`,
`MuffledHelmetsNative.dll`) provides a decoupled, generic mechanism to apply
sound output model (SOPM) overrides directly to the audio engine:
* `MuffledHelmetsNative.SetPlayerVoice(model2DFormID, model3DFormID)`
* `MuffledHelmetsNative.SetActorVoice(actorFormID, model3DFormID, leaseSeconds)`

* **Player:** the audio manager's output-model map is updated in place when the
  player equips or unequips something.
* **NPCs:** every second (configurable) the script lists the NPCs around the
  player with the vanilla keyword search, applies the same rules as for the
  player, and gives those that wear a muffling item a short *lease* that the next
  scan renews; the plugin removes entries that are not renewed. Up to 3 NPCs at
  the same time (the limit of the engine's audio table).

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0-only).
See LICENSE for details.

See also the licenses of the submodules (Caprica: MIT; CommonLibF4 and
commonlib-shared: GPL-3.0-or-later with modding exceptions; spdlog: MIT; F4SE:
see its repository). The Windows SDK/CRT are fetched under Microsoft's license,
which you accept when running the toolchain step.
