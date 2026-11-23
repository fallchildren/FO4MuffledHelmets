# MuffledHelmets
#
# A plain `make` builds everything, bootstrapping what is missing on the way:
#
#   checks prerequisites -> submodules -> Windows SDK/CRT (xwin) -> Caprica ->
#   merged Papyrus headers -> .pex -> F4SE plugin (native/) -> release .7z
#
# First run on a new box (accepts the Microsoft SDK license, see README):
#
#   make ACCEPT_MS_LICENSE=1
#
# Targets:
#   all        everything below (default)
#   bootstrap  only fetch/build the external pieces (no mod build)
#   pex        compile the Papyrus scripts
#   native     build the F4SE plugin
#   package    build/MuffledHelmets-<version>.7z
#   clean      remove build outputs (keeps Caprica, headers and toolchain)
#   distclean  clean + Caprica/headers
#   mrproper   distclean + the downloaded toolchain (.toolchain/)

.DEFAULT_GOAL := all
SHELL := /bin/bash

NAME    ?= MuffledHelmets
# single source of truth: the nearest Git tag (the plugin's version in plugin.cpp
# must match, checked when packaging); "-dirty" marks uncommitted changes
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo 0.0.0)
JOBS    ?= $(shell nproc 2>/dev/null || echo 4)

ACCEPT_MS_LICENSE ?=

ROOT  := $(CURDIR)
BUILD := build
STAMP := $(BUILD)/.stamp

# --- external pieces ---------------------------------------------------------
TOOLCHAIN    := $(ROOT)/.toolchain
XWIN_VERSION ?= 0.10.0
XWIN_CACHE   ?= $(TOOLCHAIN)/xwin-cache
XWIN         := $(TOOLCHAIN)/bin/xwin
XWIN_DONE    := $(TOOLCHAIN)/xwin/.splat-done

CAPRICA_SRC   := third_party/Caprica
CAPRICA_BUILD := $(BUILD)/caprica
CAPRICA       := $(CAPRICA_BUILD)/Caprica/Caprica

F4SE_SCRIPTS := third_party/f4se/scripts
HEADERS      := $(BUILD)/headers
FLAGS        := $(HEADERS)/Institute_Papyrus_Flags.flg

# --- mod ---------------------------------------------------------------------
SRCDIR  := Data/Scripts/Source
SRC     := $(SRCDIR)/$(NAME).psc
SRC_NAT := $(SRCDIR)/$(NAME)Native.psc
ESP     := Data/muffledhelmets.esp
MCM_DIR := Data/MCM
MCM     := $(shell find $(MCM_DIR) -type f 2>/dev/null)
STUBS   := tools/stubs
STAGE   := $(BUILD)/stage
PEX     := $(STAGE)/Data/Scripts/$(NAME).pex
PEX_NAT := $(STAGE)/Data/Scripts/$(NAME)Native.pex
DLL     := native/build/$(NAME)Native.dll
ARCHIVE := $(BUILD)/$(NAME)-$(VERSION).7z
SEVENZ  := $(firstword $(shell command -v 7z 7zz 7za 2>/dev/null))

.PHONY: all bootstrap check-deps submodules toolchain caprica headers pex \
        native package clean distclean mrproper

all: pex native package

bootstrap: check-deps submodules toolchain caprica headers

# --- bootstrap ---------------------------------------------------------------
check-deps: $(STAMP)/deps
$(STAMP)/deps: tools/check-deps.sh
	@mkdir -p $(STAMP)
	@tools/check-deps.sh
	@touch $@

submodules: $(STAMP)/submodules
$(STAMP)/submodules: .gitmodules | $(STAMP)/deps
	git submodule update --init --recursive
	@touch $@

toolchain: $(XWIN_DONE)

$(XWIN): | $(STAMP)/deps
	@mkdir -p $(TOOLCHAIN)
	CARGO_HOME=$(TOOLCHAIN)/cargo cargo install xwin --version $(XWIN_VERSION) \
	    --locked --root $(TOOLCHAIN)

# The Windows SDK/CRT come from Microsoft and need their license accepted.
$(XWIN_DONE): $(XWIN)
	@if [ -z "$(ACCEPT_MS_LICENSE)" ]; then \
	    echo "error: the Windows SDK/CRT download (via xwin) requires you to accept"; \
	    echo "       Microsoft's license terms for those files; see README.md."; \
	    echo "       Re-run with:  make ACCEPT_MS_LICENSE=1"; \
	    exit 1; \
	fi
	$(XWIN) --accept-license --cache-dir $(XWIN_CACHE) --arch x86_64 \
	    splat --output $(TOOLCHAIN)/xwin
	@touch $@

caprica: $(CAPRICA)
$(CAPRICA): $(STAMP)/submodules
	cmake -S $(CAPRICA_SRC) -B $(CAPRICA_BUILD) -DCMAKE_BUILD_TYPE=Release -Wno-dev
	cmake --build $(CAPRICA_BUILD) -j$(JOBS)
	@test -x $@

headers: $(FLAGS)
$(FLAGS): $(STAMP)/submodules tools/merge_headers.py
	python3 tools/merge_headers.py $(F4SE_SCRIPTS) $(HEADERS)

# --- build -------------------------------------------------------------------
pex: $(PEX)
# -p: parallel mode (serial mode produces no output with the port)
# --anonymize: no build path, user or host name in the .pex (patched into Caprica)
# the native stub (declares MuffledHelmetsNative.SetVoiceMuffle) is compiled
# first; the main script imports it from the source directory. The MCM script
# (optional runtime dependency) is only declared in $(STUBS) for the compiler.
$(PEX): $(SRC) $(SRC_NAT) $(wildcard $(STUBS)/*.psc) $(CAPRICA) $(FLAGS)
	@mkdir -p $(dir $@)
	@rm -f $@ $(PEX_NAT)
	$(CAPRICA) -p --ignorecwd --anonymize -g fallout4 -f $(abspath $(FLAGS)) -i $(abspath $(HEADERS)) \
	    -o $(abspath $(dir $@)) $(abspath $(SRC_NAT))
	$(CAPRICA) -p --ignorecwd --anonymize -g fallout4 -f $(abspath $(FLAGS)) -i $(abspath $(HEADERS)) \
	    -i $(abspath $(SRCDIR)) -i $(abspath $(STUBS)) -o $(abspath $(dir $@)) $(abspath $(SRC))
	@test -f $@ -a -f $(PEX_NAT) || { echo "error: compiler produced no $@"; exit 1; }

# F4SE plugin; always delegates, the sub-make decides what is out of date
native: $(XWIN_DONE) $(STAMP)/submodules
	$(MAKE) -C native -j$(JOBS) TOOLCHAIN=$(TOOLCHAIN)

package: $(ARCHIVE)
$(ARCHIVE): $(PEX) $(SRC) $(SRC_NAT) $(ESP) $(MCM) native
	@test -n "$(SEVENZ)" || { echo "error: 7z not found"; exit 1; }
	@v="$$(sed 's/-dirty$$//' <<< '$(VERSION)')"; want="$$(sed -E 's/\./, /g' <<< "$$v")"; \
	  grep -q "PluginVersion({ $$want, 0 })" native/src/plugin.cpp || \
	  { echo "error: plugin version in native/src/plugin.cpp does not match Git tag $$v"; exit 1; }
	rm -rf $(STAGE)/Data/F4SE $(STAGE)/Data/Scripts/Source $(STAGE)/Data/muffledhelmets.esp $(STAGE)/Data/MCM
	mkdir -p $(STAGE)/Data/Scripts/Source
	cp $(SRC) $(SRC_NAT) $(STAGE)/Data/Scripts/Source/
	cp $(ESP) $(STAGE)/Data/
	cp -r $(MCM_DIR) $(STAGE)/Data/
	mkdir -p $(STAGE)/Data/F4SE/Plugins
	cp $(DLL) $(STAGE)/Data/F4SE/Plugins/
	rm -f $@
	cd $(STAGE) && $(SEVENZ) a -t7z -mx=9 -bd $(abspath $@) Data >/dev/null
	@echo "created $@"; $(SEVENZ) l $@ | tail -8

# --- cleaning ----------------------------------------------------------------
clean:
	rm -rf $(STAGE) $(BUILD)/*.7z
	-$(MAKE) -C native clean

distclean: clean
	rm -rf $(BUILD)

mrproper: distclean
	rm -rf $(TOOLCHAIN)
