# MuffledHelmets
#
# A plain `make` builds everything, bootstrapping what is missing on the way:
#
#   checks prerequisites -> submodules -> Windows SDK/CRT (xwin) ->
#   merged Papyrus headers -> PSL/PEX -> F4SE plugin -> release .7z
#
# First run on a new box (accepts the Microsoft SDK license, see README):
#
#   make ACCEPT_MS_LICENSE=1
#
# Targets:
#   all        everything below (default)
#   bootstrap  only fetch/build the external pieces (no mod build)
#   pex        compile the Papyrus/PSL scripts with Jezebel
#   native     build the F4SE plugin
#   package    build/MuffledHelmets-<version>.7z
#   clean      remove build outputs (keeps headers and toolchain)
#   distclean  clean + headers/runtime build outputs
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

LOCAL_JEZEBEL := ../jezebel/bin/jezebel
JEZEBEL_VERSION ?= 0.1.0
JEZEBEL ?= $(if $(wildcard $(LOCAL_JEZEBEL)),$(LOCAL_JEZEBEL),$(TOOLCHAIN)/jezebel/jezebel)
JEZEBEL_ASSET := jezebel-$(JEZEBEL_VERSION)-linux-amd64.tar.gz
JEZEBEL_URL   := https://github.com/fallchildren/jezebel/releases/download/$(JEZEBEL_VERSION)/$(JEZEBEL_ASSET)

F4SE_SCRIPTS := third_party/f4se/scripts
HEADERS      := $(BUILD)/headers
FLAGS        := $(HEADERS)/Institute_Papyrus_Flags.flg

# --- mod ---------------------------------------------------------------------
SRCDIR  := Data/Scripts/Source
SRC     := $(SRCDIR)/$(NAME).psl
SRC_NAT := $(SRCDIR)/$(NAME)Native.psc
ESP     := Data/muffledhelmets.esp
MCM_DIR := Data/MCM
MCM     := $(shell find $(MCM_DIR) -type f 2>/dev/null)
STUBS   := tools/stubs
STAGE   := $(BUILD)/stage
SCRIPT_BUILD := $(BUILD)/scripts
PEX     := $(SCRIPT_BUILD)/$(NAME).pex
PEX_NAT := $(SCRIPT_BUILD)/$(NAME)Native.pex
PSC     := $(SCRIPT_BUILD)/$(NAME).psc
DLL     := native/build/$(NAME)Native.dll
ARCHIVE := $(BUILD)/$(NAME)-$(VERSION).7z
SEVENZ  := $(firstword $(shell command -v 7z 7zz 7za 2>/dev/null))

.PHONY: all bootstrap check-deps check-native-deps submodules toolchain headers pex native package \
        clean distclean mrproper

all: pex native package

bootstrap: check-deps submodules toolchain headers

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

headers: $(FLAGS)
$(FLAGS): $(STAMP)/submodules tools/merge_headers.py
	python3 tools/merge_headers.py $(F4SE_SCRIPTS) $(HEADERS)

$(LOCAL_JEZEBEL):
	@if [ -x "$(LOCAL_JEZEBEL)" ]; then :; else \
	  echo "error: $(LOCAL_JEZEBEL) not found"; \
	  echo "       set JEZEBEL=/path/to/jezebel or JEZEBEL_VERSION=<release>"; \
	  exit 1; \
	fi

$(TOOLCHAIN)/jezebel/jezebel:
	@set -eu; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "downloading Jezebel $(JEZEBEL_VERSION)"; \
	curl -fsSL "$(JEZEBEL_URL)" -o "$$tmp/$(JEZEBEL_ASSET)"; \
	curl -fsSL "$(JEZEBEL_URL).sha256" -o "$$tmp/$(JEZEBEL_ASSET).sha256"; \
	(cd "$$tmp" && sha256sum -c "$(JEZEBEL_ASSET).sha256"); \
	mkdir -p "$(TOOLCHAIN)/jezebel"; \
	tar -xzf "$$tmp/$(JEZEBEL_ASSET)" -C "$(TOOLCHAIN)/jezebel"; \
	chmod +x "$@"

# --- build -------------------------------------------------------------------
pex: $(PEX)

$(PEX): $(SRC) $(SRC_NAT) $(wildcard $(STUBS)/*.psc) $(JEZEBEL) $(FLAGS)
	@mkdir -p $(SCRIPT_BUILD)
	@rm -f $(PEX) $(PEX_NAT) $(PSC)
	$(JEZEBEL) -q -I $(abspath $(HEADERS)) -I $(abspath $(SRCDIR)) -I $(abspath $(STUBS)) \
	    -f $(abspath $(FLAGS)) -o $(abspath $(SCRIPT_BUILD)) $(abspath $(SRC_NAT))
	$(JEZEBEL) -q -I $(abspath $(HEADERS)) -I $(abspath $(SRCDIR)) -I $(abspath $(STUBS)) \
	    -f $(abspath $(FLAGS)) -o $(abspath $(SCRIPT_BUILD)) $(abspath $(SRC))
	@test -f $(PEX) -a -f $(PEX_NAT) -a -f $(PSC) || { echo "error: compiler produced no PEX/PSC"; exit 1; }

# F4SE plugin; always delegates, the sub-make decides what is out of date
native: check-native-deps $(XWIN_DONE) $(STAMP)/submodules
	$(MAKE) -C native -j$(JOBS) TOOLCHAIN=$(TOOLCHAIN)

check-native-deps:
	@tools/check-native-deps.sh

package: $(ARCHIVE)
$(ARCHIVE): $(PEX) $(SRC) $(SRC_NAT) $(ESP) $(MCM) native
	@test -n "$(SEVENZ)" || { echo "error: 7z not found"; exit 1; }
	@v="$$(sed -E 's/-.*$$//' <<< '$(VERSION)')"; want="$$(sed -E 's/\./, /g' <<< "$$v")"; \
	  grep -q "PluginVersion({ $$want, 0 })" native/src/plugin.cpp || \
	  { echo "error: plugin version in native/src/plugin.cpp does not match Git tag $$v"; exit 1; }
	rm -rf $(STAGE)/Data/F4SE $(STAGE)/Data/Scripts/Source $(STAGE)/Data/muffledhelmets.esp $(STAGE)/Data/MCM
	mkdir -p $(STAGE)/Data/Scripts/Source
	cp $(PEX) $(PEX_NAT) $(STAGE)/Data/Scripts/
	cp $(SRC) $(SRC_NAT) $(STAGE)/Data/Scripts/Source/
	cp $(PSC) $(STAGE)/Data/Scripts/Source/
	cp $(ESP) $(STAGE)/Data/
	cp -r $(MCM_DIR) $(STAGE)/Data/
	mkdir -p $(STAGE)/Data/F4SE/Plugins
	cp $(DLL) $(STAGE)/Data/F4SE/Plugins/
	rm -f $@
	cd $(STAGE) && $(SEVENZ) a -t7z -mx=9 -bd $(abspath $@) Data >/dev/null
	@echo "created $@"; $(SEVENZ) l $@ | tail -8

# --- cleaning ----------------------------------------------------------------
clean:
	rm -rf $(STAGE) $(SCRIPT_BUILD) $(BUILD)/*.7z
	-$(MAKE) -C native clean

distclean: clean
	rm -rf $(BUILD)

mrproper: distclean
	rm -rf $(TOOLCHAIN)
