#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Each tier is a strict superset of the one below it, so no package can leave a hole in an
# Avalonia render-backend fallback chain: whatever a tier claims, it also claims everything
# under it. The names are part of the cross-repo contract - they become the payload
# directory, the PackageId suffix and the OptrisStaticGraphicsBackends property.
#
# On macOS the top tier is spelled "Vulkan" like everywhere else, but it is delivered by
# Metal: Vulkan only reaches Apple hardware through MoltenVK, which Skia does not vendor,
# whereas Metal is the platform's first-class GPU backend and is what Avalonia asks for
# first. The tier therefore means "this platform's best GPU backend, plus everything below".
TIER="${TIER:-Vulkan}"
case "$TIER" in
  Vulkan) BACKENDS="Vulkan OpenGL Software" ;;
  OpenGL) BACKENDS="OpenGL Software" ;;
  Software) BACKENDS="Software" ;;
  *)
    echo "Unknown tier '$TIER'. Expected one of: Vulkan, OpenGL, Software (case-sensitive)." >&2
    exit 1
    ;;
esac

WORK_DIR="${WORK_DIR:-$ROOT_DIR/External/NativeStatic/.work}"
TARGET_CPU="${TARGET_CPU:-arm64}"
RID="${RID:-osx-$TARGET_CPU}"
# Tiers differ only in what is compiled in, so they share WORK_DIR - the multi-GB
# depot_tools/SkiaSharp checkout is cloned once and reused by every tier - while the payload
# is kept apart per tier so one tier can never overwrite another's archives.
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/static-$TIER/$RID/native}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-4.150.1}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"

usage() {
  cat <<'USAGE'
Usage: scripts/build-macos-static-graphics.sh [skia|all]

Environment:
  TIER                Graphics tier: Vulkan, OpenGL or Software. Default: Vulkan
                      On macOS the Vulkan tier is delivered by Metal.
  WORK_DIR            Source/build cache directory, shared by all tiers.
                      Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory.
                      Default: External/NativeStatic/static-$TIER/$RID/native
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 4.150.1
  TARGET_CPU          GN target_cpu. Default: arm64. Supported: x64, arm64
  RID                 Output RID. Default: osx-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: sysctl hw.ncpu
  LLVM_NM             llvm-nm used to verify the tier contract. Default: autodetected

ANGLE is not built on macOS: the consumer targets' macOS ItemGroup never references it, so
nothing would ever pull the archive in.
USAGE
}

tier_claims() {
  [[ " $BACKENDS " == *" $1 "* ]]
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_tools() {
  require_cmd git
  require_cmd python3
  require_cmd clang
  require_cmd clang++
  require_cmd ar
  require_cmd ninja
}

ensure_depot_tools() {
  local depot_dir="$WORK_DIR/depot_tools"
  if [[ ! -d "$depot_dir/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  export PATH="$depot_dir:$PATH"
}

copy_first_existing() {
  local dest="$1"
  shift
  for src in "$@"; do
    if [[ -f "$src" ]]; then
      cp "$src" "$dest"
      echo "Wrote $dest"
      return 0
    fi
  done
  echo "None of the expected files exist for $dest:" >&2
  printf '  %s\n' "$@" >&2
  return 1
}

SKIA_CHECKOUT_DIR=""
LLVM_NM_RESOLVED=""

resolve_llvm_nm() {
  if [[ -n "$LLVM_NM_RESOLVED" ]]; then
    echo "$LLVM_NM_RESOLVED"
    return 0
  fi

  local candidates=()
  if [[ -n "${LLVM_NM:-}" ]]; then
    candidates+=("$LLVM_NM")
  fi
  # Prefer the clang that produced the archives: the Chromium toolchain Skia syncs into its
  # own checkout. Xcode's own nm is llvm-nm and reads these archives fine as a fallback.
  if [[ -n "$SKIA_CHECKOUT_DIR" ]]; then
    candidates+=(
      "$SKIA_CHECKOUT_DIR/third_party/externals/llvm-build/Release+Asserts/bin/llvm-nm"
      "$SKIA_CHECKOUT_DIR/third_party/llvm-build/Release+Asserts/bin/llvm-nm"
      "$SKIA_CHECKOUT_DIR/bin/llvm-nm"
    )
  fi
  candidates+=("$WORK_DIR/depot_tools/llvm-build/Release+Asserts/bin/llvm-nm")
  if command -v xcrun >/dev/null 2>&1; then
    candidates+=("$(xcrun --find llvm-nm 2>/dev/null || true)" "$(xcrun --find nm 2>/dev/null || true)")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      LLVM_NM_RESOLVED="$candidate"
      echo "$LLVM_NM_RESOLVED"
      return 0
    fi
  done

  local name
  for name in llvm-nm nm; do
    if command -v "$name" >/dev/null 2>&1; then
      LLVM_NM_RESOLVED="$(command -v "$name")"
      echo "$LLVM_NM_RESOLVED"
      return 0
    fi
  done

  echo "Could not find llvm-nm. Set LLVM_NM, or install LLVM. Searched:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  printf '  %s on PATH\n' "llvm-nm" "nm" >&2
  return 1
}

# Every name the tier contract cares about. One nm pass over a multi-hundred-MB archive is
# expensive, so the output is filtered down to these once and then queried in memory.
TIER_SYMBOL_PATTERN='GrMtlGpu|GrMtlCaps|GrVkGpu|AMDMemoryAllocator|GrGLGpu|GrGLInterface|vkCreateInstance'

tier_symbol_lines() {
  local library="$1"
  local nm dump
  nm="$(resolve_llvm_nm)"
  dump="$(mktemp)"
  if ! "$nm" "$library" >"$dump" 2>/dev/null; then
    rm -f "$dump"
    echo "llvm-nm could not read $library" >&2
    return 1
  fi
  grep -E "$TIER_SYMBOL_PATTERN" "$dump" || true
  rm -f "$dump"
}

# nm prints "<address> <type> <name>" for a defined symbol and leaves the address blank with
# type U for an undefined one. Only a defined symbol proves the code is really compiled into
# the archive rather than merely referenced by it.
symbol_defined() {
  grep -F -- "$2" <<<"$1" | grep -Eq '^[0-9a-fA-F]+[[:space:]]+[^Uu[:space:]][[:space:]]'
}

symbol_mentioned() {
  grep -qF -- "$2" <<<"$1"
}

assert_tier_symbols() {
  # This is the whole reason the fork exists. Upstream shipped a package that advertised a
  # GPU backend SkiaSharp had only stubbed out, so an app that asked for it rendered a blank
  # window with no crash, no log and no fallback. Presence alone is not enough: a reduced
  # tier that quietly contains a backend is just as wrong, because the consumer guard and the
  # published backend list would then be lying in the other direction.
  local library="$1"
  local lines failures=() name
  lines="$(tier_symbol_lines "$library")"

  if tier_claims Vulkan; then
    if ! symbol_defined "$lines" "GrMtlGpu"; then
      failures+=("tier '$TIER' claims the top GPU backend but 'GrMtlGpu' is not defined in $library")
    fi
  else
    for name in GrMtlGpu GrMtlCaps; do
      if symbol_mentioned "$lines" "$name"; then
        failures+=("tier '$TIER' must not contain Metal but '$name' appears in $library")
      fi
    done
  fi

  if tier_claims OpenGL; then
    for name in GrGLGpu GrGLInterface; do
      if ! symbol_defined "$lines" "$name"; then
        failures+=("tier '$TIER' claims OpenGL but '$name' is not defined in $library")
      fi
    done
  else
    for name in GrGLGpu GrGLInterface; do
      if symbol_mentioned "$lines" "$name"; then
        failures+=("tier '$TIER' must not contain OpenGL but '$name' appears in $library")
      fi
    done
  fi

  # Vulkan is never compiled in on macOS - Skia would need MoltenVK - so it must be absent
  # from every tier, including the top one.
  for name in GrVkGpu AMDMemoryAllocator vkCreateInstance; do
    if symbol_mentioned "$lines" "$name"; then
      failures+=("tier '$TIER' must not contain Vulkan on macOS but '$name' appears in $library")
    fi
  done

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "Tier contract violated (tier '$TIER', backends $BACKENDS):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    return 1
  fi

  echo "Tier '$TIER' symbol contract verified in $library: backends $BACKENDS."
}

sync_skiasharp() {
  local src="$WORK_DIR/SkiaSharp-$SKIASHARP_VERSION"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch "release/$SKIASHARP_VERSION" https://github.com/mono/SkiaSharp.git "$src"
  else
    git -C "$src" fetch --depth 1 origin "release/$SKIASHARP_VERSION"
    git -C "$src" checkout -q FETCH_HEAD
  fi
  git -C "$src" submodule update --init --depth 1 externals/skia >&2
  echo "$src"
}

prepare_skia_git_sync_deps() {
  local sync_deps="$1/tools/git-sync-deps"
  python3 - "$sync_deps" <<'PY'
import re
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
deps_path = path.with_name("DEPS")
if deps_path.exists():
    deps = deps_path.read_text()
    deps = re.sub(r'^\s*"third_party/externals/dng_sdk"\s*:\s*"[^"]+",\s*\n', '', deps, flags=re.MULTILINE)
    deps_path.write_text(deps)
old = "  multithread(git_checkout_to_directory, list_of_arg_lists)"
new = "  for args in list_of_arg_lists:\n    git_checkout_to_directory(*args)"
if old in text:
    path.write_text(text.replace(old, new))
PY
}

sync_skia_deps() {
  local skia_dir="$1"
  prepare_skia_git_sync_deps "$skia_dir"

  local attempt
  for attempt in $(seq 1 "$SKIA_DEPS_RETRIES"); do
    if python3 "$skia_dir/tools/git-sync-deps"; then
      return 0
    fi
    if [[ "$attempt" == "$SKIA_DEPS_RETRIES" ]]; then
      return 1
    fi
    echo "git-sync-deps failed; retrying ($attempt/$SKIA_DEPS_RETRIES)..." >&2
    sleep 10
  done
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  local src
  src="$(sync_skiasharp)"
  local skia_dir="$src/externals/skia"
  SKIA_CHECKOUT_DIR="$skia_dir"
  if [[ ! -x "$skia_dir/bin/gn" ]]; then
    sync_skia_deps "$skia_dir"
  fi

  # Ganesh stays ON for every tier, including Software, and skia_use_gl is what actually
  # distinguishes them.
  # This was skia_enable_ganesh = false for Software, which is the tidier expression of "no GPU
  # pipeline at all" and does not compile - this platform is where it was caught:
  #   src/c/gr_context.cpp:46: error: non-void function
  #   'gr_recording_context_get_direct_context' should return a value
  # SkiaSharp's C API assumes Ganesh exists; SK_ONLY_GPU collapses to nothing and leaves the
  # function with no return. The C API stubs absent BACKENDS but not an absent pipeline.
  # Turning GL off instead keeps the API compiling and still satisfies assert_tier_symbols,
  # because GrGLGpu and GrGLInterface are compiled only when skia_use_gl is true.
  local skia_enable_ganesh="true"
  local skia_use_gl="false"
  if tier_claims OpenGL; then
    skia_use_gl="true"
  fi
  # Metal is this platform's top GPU backend, so it tracks the Vulkan tier. Turning it off
  # for the reduced tiers is what makes them genuinely smaller, and the assertion below
  # refuses to ship a reduced tier that still contains it.
  local skia_use_metal="false"
  if tier_claims Vulkan; then
    skia_use_metal="true"
  fi

  # Per-tier build directory inside the shared checkout: switching tiers must not force a
  # full re-sync, and two tiers building concurrently must not fight over one ninja dir.
  local out_dir="$skia_dir/out/mac-static-$TIER-$TARGET_CPU"
  mkdir -p "$out_dir" "$OUTPUT_DIR"
  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "mac"
target_cpu = "$TARGET_CPU"
min_macos_version = "10.13"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = $skia_enable_ganesh
skia_use_gl = $skia_use_gl
skia_use_metal = $skia_use_metal
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = false
skia_use_freetype = false
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_sfntly = false
skia_use_system_expat = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_xps = false
cc = "clang"
cxx = "clang++"
ar = "ar"
extra_cflags = [ "-DSKIA_C_DLL" ]
extra_cflags_cc = [ "-frtti" ]
EOF_ARGS

  (cd "$skia_dir" && "$skia_dir/bin/gn" gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp
  copy_first_existing "$OUTPUT_DIR/libskia.a" "$out_dir/libskia.a" "$out_dir/obj/libskia.a"
  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.a" "$out_dir/libSkiaSharp.a" "$out_dir/obj/libSkiaSharp.a"
  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.a" "$out_dir/libHarfBuzzSharp.a" "$out_dir/obj/libHarfBuzzSharp.a"

  assert_tier_symbols "$OUTPUT_DIR/libskia.a"
}

main() {
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  echo "Building tier '$TIER' (backends $BACKENDS) for $RID into $OUTPUT_DIR"
  case "${1:-all}" in
    skia|all) build_skia ;;
    angle)
      echo "ANGLE is not built on macOS: the consumer targets' macOS ItemGroup never references it, so nothing would pull the archive in." >&2
      exit 1
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
