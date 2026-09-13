###############################################################################
# Compiler and base flags
###############################################################################
CXXFLAGS := -std=c++17 -Wall -Wextra -MMD -MP
CPPFLAGS :=
LDFLAGS  :=

###############################################################################
# Host detection (the machine running make) -> RM / RMDIR / MKDIR / default TARGET
###############################################################################
ifeq ($(OS),Windows_NT)
    HOST_OS := windows
    RM      := del /Q
    RMDIR   := rmdir /S /Q
    MKDIR   := mkdir
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Linux)
        HOST_OS := linux
    else ifeq ($(UNAME_S),Darwin)
        HOST_OS := macos
    endif
    RM      := rm -f
    RMDIR   := rm -rf
    MKDIR   := mkdir -p
endif

###############################################################################
# Target OS selection (enables cross-compiling from any host).
###############################################################################
TARGET ?= $(HOST_OS)

ifeq ($(TARGET),windows)
    OS_NAME    := Windows
    EXE_SUFFIX := .exe
    STACK_FLAG := -Wl,--stack,8388608
    LDFLAGS += -static -static-libgcc -static-libstdc++
    ifeq ($(origin CXX),default)
        CXX := x86_64-w64-mingw32-g++
    endif
else ifeq ($(TARGET),linux)
    OS_NAME    := Linux
    EXE_SUFFIX :=
    STACK_FLAG :=
    LDFLAGS += -static-libgcc -static-libstdc++
else ifeq ($(TARGET),android)
    OS_NAME    := Android
    EXE_SUFFIX :=
    STACK_FLAG :=
    LDFLAGS += -static-libstdc++
else
    OS_NAME    := macOS
    EXE_SUFFIX :=
    STACK_FLAG :=
endif

###############################################################################
# Source and object files (sources live in src/; objects sit beside them)
###############################################################################
SOURCES := $(wildcard src/*.cpp)
OBJECTS := $(SOURCES:.cpp=.o)
DEPS    := $(OBJECTS:.o=.d)

###############################################################################
# Embedded default NNUE network
###############################################################################
NNUE_FILE ?= $(abspath nn/thrawn-nn-2.nnue)
NNUE_NAME := $(basename $(notdir $(NNUE_FILE)))
EMBED_OBJ := src/nnue_embedded_data.o

CPPFLAGS += -DNNUE_EMBED_NAME='"$(NNUE_NAME)"'

ifeq ($(filter clean distclean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(NNUE_FILE)),)
$(error NNUE network not found at '$(NNUE_FILE)'. Place the .nnue file there, \
or build with `make NNUE_FILE=/path/to/net.nnue`)
endif
endif

OBJECTS += $(EMBED_OBJ)

###############################################################################
# Build type and flags
###############################################################################
BUILD ?= release
ARCH  ?= native

OPT_FLAGS  := -O3 -flto=auto
ARCH_FLAGS :=
MACOS_MIN_VERSION := 10.15

ifeq ($(HOST_OS),windows)
    ARCH_DETECTED := $(PROCESSOR_ARCHITECTURE)
else
    ARCH_DETECTED := $(shell uname -m)
endif

# Target-OS-specific compile/link additions.
ifeq ($(TARGET),linux)
    CXXFLAGS += -pthread
    LDFLAGS  += -pthread
else ifeq ($(TARGET),android)
    # Bionic libc provides POSIX threads directly inside libc
else ifeq ($(TARGET),macos)
    ifeq ($(ARCH_DETECTED),arm64)
        MACOS_MIN_VERSION := 11.0
    endif
    ARCH_FLAGS += -mmacosx-version-min=$(MACOS_MIN_VERSION)
else ifeq ($(TARGET),windows)
    CPPFLAGS += -DWIN32
endif

# -----------------------------------------------------------------------------
# Architecture specific flags
# -----------------------------------------------------------------------------
ifeq ($(ARCH),native)
    ifeq ($(ARCH_DETECTED),x86_64)
        CPPFLAGS += -DUSE_AVX2
        ARCH_FLAGS += -march=native -mfma -mbmi -mbmi2 -mpopcnt
        DIST_TAG := x64-avx2
    else ifeq ($(ARCH_DETECTED),AMD64)
        CPPFLAGS += -DUSE_AVX2
        ARCH_FLAGS += -march=native -mfma -mbmi -mbmi2 -mpopcnt
        DIST_TAG := x64-avx2
    else ifeq ($(ARCH_DETECTED),arm64)
        CPPFLAGS += -DUSE_NEON
        ARCH_FLAGS += -march=native
        DIST_TAG := arm-neon
    else ifeq ($(ARCH_DETECTED),aarch64)
        CPPFLAGS += -DUSE_NEON
        ARCH_FLAGS += -march=native
        DIST_TAG := arm-neon
    else ifeq ($(ARCH_DETECTED),ARM64)
        CPPFLAGS += -DUSE_NEON
        ARCH_FLAGS += -march=native
        DIST_TAG := arm-neon
    endif
else ifeq ($(ARCH),x86-64-avx512)
    CPPFLAGS += -DUSE_AVX512
    ARCH_FLAGS += -mavx512f -mavx512bw -mavx512dq -mavx512vnni -mavx2 -mfma -mbmi -mbmi2 -mpopcnt
    DIST_TAG := x64-avx512
else ifeq ($(ARCH),x86-64-avx2)
    CPPFLAGS += -DUSE_AVX2
    ARCH_FLAGS += -mavx2 -mfma -mbmi -mbmi2 -mpopcnt
    DIST_TAG := x64-avx2
else ifeq ($(ARCH),arm64-neon)
    CPPFLAGS += -DUSE_NEON
    DIST_TAG := arm-neon
else ifeq ($(ARCH),arm64-neon-dotprod)
    CPPFLAGS += -DUSE_NEON
    ifeq ($(OS_NAME),macOS)
        ARCH_FLAGS += -march=native
    else
        ARCH_FLAGS += -march=armv8.2-a+dotprod
    endif
    DIST_TAG := arm-neon
else
    $(error Unsupported ARCH '$(ARCH)'. Use native, x86-64-avx512, x86-64-avx2, arm64-neon, or arm64-neon-dotprod)
endif

# -----------------------------------------------------------------------------
# PEXT bitboards (opt-in: `make PEXT=1`)
# -----------------------------------------------------------------------------
ifeq ($(PEXT),1)
    CPPFLAGS += -DUSE_PEXT
    ifneq ($(filter x86_64 AMD64,$(ARCH_DETECTED)),)
        ARCH_FLAGS += -mbmi2
    endif
endif

# -----------------------------------------------------------------------------
# Build Types
# -----------------------------------------------------------------------------
ifeq ($(BUILD),debug)
    CPPFLAGS += -DDEBUG_BUILD
    CXXFLAGS += -g $(ARCH_FLAGS)
else ifeq ($(BUILD),release)
    CPPFLAGS += -DRELEASE_BUILD -DNDEBUG
    CXXFLAGS += $(OPT_FLAGS) $(ARCH_FLAGS)
    LDFLAGS  += $(OPT_FLAGS)
endif

###############################################################################
# Distribution output
###############################################################################
VERSION     ?= 3.2
BUILD_DIR   ?= $(abspath $(CURDIR)/build)
OUTPUT_NAME ?= thrawn-v$(VERSION)-$(TARGET)-$(DIST_TAG)$(EXE_SUFFIX)
OUTPUT      := $(BUILD_DIR)/$(OUTPUT_NAME)

###############################################################################
# Targets
###############################################################################
.PHONY: all clean distclean release

all: $(OUTPUT)

$(OUTPUT): $(OBJECTS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(STACK_FLAG) -o $@ $^

$(BUILD_DIR):
	$(MKDIR) "$(BUILD_DIR)"

%.o: %.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c -o $@ $<

$(EMBED_OBJ): src/nnue_embedded_data.S $(NNUE_FILE)
	$(CXX) $(CPPFLAGS) -DNNUE_EMBED_PATH='"$(NNUE_FILE)"' $(ARCH_FLAGS) -c -o $@ $<

clean:
	$(RM) $(OBJECTS) $(DEPS)

distclean: clean
	$(RMDIR) "$(BUILD_DIR)"

release:
	$(MAKE) clean
	$(MAKE) TARGET=macos   ARCH=native
	$(MAKE) clean
	$(MAKE) TARGET=windows ARCH=x86-64-avx2   CXX=x86_64-w64-mingw32-g++
	$(MAKE) clean
	$(MAKE) TARGET=windows ARCH=x86-64-avx512 CXX=x86_64-w64-mingw32-g++
	$(MAKE) clean
	$(MAKE) TARGET=linux   ARCH=x86-64-avx2   CXX=x86_64-unknown-linux-gnu-g++
	$(MAKE) clean
	$(MAKE) TARGET=linux   ARCH=x86-64-avx512 CXX=x86_64-unknown-linux-gnu-g++
	$(MAKE) clean
	@echo "==> Distributable binaries in $(BUILD_DIR):"
	@ls -la "$(BUILD_DIR)"

-include $(DEPS)
