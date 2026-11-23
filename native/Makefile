# Cross-build of the MuffledHelmets F4SE plugin on Linux with clang-cl + the
# xwin Windows SDK/CRT (see ../.toolchain), without xmake.
#
#   make libs     static libs: commonlib-shared + commonlibf4
#   make          plugin DLL

SHELL := /bin/bash

TOOLCHAIN ?= $(abspath ../.toolchain)
VERSION   ?= 0.0.0
XWIN      := $(TOOLCHAIN)/xwin
RUSTLLD   ?= $(shell rustc --print target-libdir)/../bin/rust-lld

CXX  := clang-cl
AR   := llvm-lib
LINK := $(RUSTLLD) -flavor link

EXT      := extern
CLF4     := $(EXT)/commonlibf4
SHARED   := $(CLF4)/lib/commonlib-shared
SPDLOG   := $(EXT)/spdlog

BUILD := build
INCLUDES := $(BUILD) $(CLF4)/include $(SHARED)/include $(SHARED)/src $(SPDLOG)/include
SYSINC   := $(XWIN)/crt/include $(XWIN)/sdk/include/ucrt $(XWIN)/sdk/include/um \
            $(XWIN)/sdk/include/shared
LIBPATHS := $(XWIN)/crt/lib/x86_64 $(XWIN)/sdk/lib/um/x86_64 $(XWIN)/sdk/lib/ucrt/x86_64

DEFINES  := SPDLOG_COMPILED_LIB SPDLOG_USE_STD_FORMAT SPDLOG_WCHAR_TO_UTF8_SUPPORT NOGDI NOMINMAX WIN32_LEAN_AND_MEAN

NOWARN := -Wno-delete-non-abstract-non-virtual-dtor -Wno-deprecated-volatile \
  -Wno-ignored-qualifiers -Wno-inconsistent-missing-override -Wno-invalid-offsetof \
  -Wno-microsoft-include -Wno-overloaded-virtual -Wno-pragma-system-header-outside-header \
  -Wno-reinterpret-base-class -Wno-switch -Wno-unused-local-typedef -Wno-unused-private-field \
  -Wno-nonportable-include-path -Wno-error=return-mismatch -Wno-return-mismatch -Wno-unknown-pragmas -Wno-msvc-not-found

CXXFLAGS := --target=x86_64-pc-windows-msvc /std:c++latest /MD /EHsc /permissive- /utf-8 /O2 /Zi \
  -fms-compatibility -fms-extensions /W0 $(NOWARN) \
  $(addprefix /I,$(INCLUDES)) $(addprefix /imsvc ,$(SYSINC)) $(addprefix /D,$(DEFINES))

VERSION_H := $(BUILD)/version.h
SPDLOG_SRCS := $(wildcard $(SPDLOG)/src/*.cpp)
LIB_SRCS := $(shell find $(CLF4)/src $(SHARED)/src -name '*.cpp') $(SPDLOG_SRCS)
LIB_OBJS := $(patsubst %.cpp,$(BUILD)/obj/%.obj,$(LIB_SRCS))

PLUGIN   := MuffledHelmetsNative
PLUGIN_SRCS := $(wildcard src/*.cpp)
PLUGIN_OBJS := $(patsubst %.cpp,$(BUILD)/obj/%.obj,$(PLUGIN_SRCS))
SYSLIBS  := advapi32.lib bcrypt.lib d3d11.lib d3dcompiler.lib dbghelp.lib dxgi.lib ole32.lib shell32.lib user32.lib version.lib ws2_32.lib

.PHONY: all libs dll clean FORCE
all: dll
dll: $(BUILD)/$(PLUGIN).dll
libs: $(BUILD)/commonlibf4.lib

$(VERSION_H): FORCE
	@mkdir -p $(dir $@)
	@v="$(VERSION)"; base="$${v%%-*}"; 	  IFS=. read -r major minor patch rest <<< "$$base"; 	  case "$$major" in ''|*[!0-9]*) major=0;; esac; 	  case "$$minor" in ''|*[!0-9]*) minor=0;; esac; 	  case "$$patch" in ''|*[!0-9]*) patch=0;; esac; 	  printf '#define MH_VERSION_MAJOR %s\n#define MH_VERSION_MINOR %s\n#define MH_VERSION_PATCH %s\n#define MH_VERSION_STRING "%s"\n' 	    "$$major" "$$minor" "$$patch" "$$v" > $@.tmp; 	  if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv $@.tmp $@; fi

FORCE:

# every library source gets its precompiled header force-included, like xmake does
$(BUILD)/obj/$(SHARED)/%.obj: $(SHARED)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) /FIREX/PCH.h /c $< /Fo$@

$(BUILD)/obj/$(SPDLOG)/%.obj: $(SPDLOG)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) /c $< /Fo$@

$(BUILD)/obj/$(CLF4)/src/%.obj: $(CLF4)/src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) /FIF4SE/Impl/PCH.h /c $< /Fo$@

$(BUILD)/commonlibf4.lib: $(LIB_OBJS)
	$(AR) /out:$@ $^

$(BUILD)/obj/src/%.obj: src/%.cpp $(VERSION_H)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) /c $< /Fo$@

$(BUILD)/$(PLUGIN).dll: $(PLUGIN_OBJS) $(BUILD)/commonlibf4.lib
	$(LINK) /dll /out:$@ /debug /pdbaltpath:MuffledHelmetsNative.pdb $(addprefix /libpath:,$(LIBPATHS)) $^ $(SYSLIBS)

clean:
	rm -rf $(BUILD)
