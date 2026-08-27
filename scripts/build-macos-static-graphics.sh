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
# SkCanvas/SkSurface/SkImage are not part of the contract; they are the reader's own proof of
# life, and they have to survive this filter for assert_tier_symbols to be able to check it.
TIER_SYMBOL_PATTERN='GrMtlGpu|GrMtlCaps|GrVkGpu|AMDMemoryAllocator|GrGLGpu|GrGLInterface|vkCreateInstance|SkCanvas|SkSurface|SkImage'
READER_SANITY_SYMBOLS=(SkCanvas SkSurface SkImage)

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
  # Deliberately NOT one pipeline. `grep -q` exits at its first match, the upstream grep then
  # dies writing to a closed pipe, and `set -o pipefail` turns that into a non-zero status - so
  # this reports "not defined" for a symbol that is plainly defined. It only bites once the
  # filtered set is big enough for the reader to still be writing when the tester quits, which is
  # why a narrow TIER_SYMBOL_PATTERN hid it: the moment the reader's own proof-of-life symbols
  # joined the filter, every glibc build started failing its own sanity check.
  local matches
  matches="$(grep -F -- "$2" <<<"$1")" || return 1
  grep -Eq '^[0-9a-fA-F]+[[:space:]]+[^Uu[:space:]][[:space:]]' <<<"$matches"
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

  # A reader that returns nothing is the dangerous case, not an obvious one: every "must be
  # defined" check fails, which looks like a broken build, while every "must not contain" check
  # PASSES - so the Software tier would sail through on an empty read and ship unverified. That is
  # the same shape as the defect this repository exists to prevent, so an empty result is treated
  # as a broken tool rather than as evidence about the archive.
  if [ -z "$lines" ]; then
    echo "Symbol reader returned nothing for $library." >&2
    echo "That is a broken reader, not a verdict: even a Software build contains Skia's own" >&2
    echo "symbols, so the pattern should always match something. Reader was: $(resolve_llvm_nm)" >&2
    return 1
  fi

  # Non-empty is not the same as trustworthy. macOS is the platform that showed this first: it
  # reported every backend missing from an archive that had just compiled cleanly, which reads
  # exactly like a real gap and is why macOS is currently built out of the release path. The
  # same shape then appeared on musl, where the build log proved GrVkGpu.cpp and GrGLGpu.cpp had
  # compiled and the reader still said they were absent.
  # So the reader must prove itself on this archive before any "not defined" verdict counts.
  # SkCanvas/SkSurface/SkImage are in every Skia build ever configured; if none reads back as
  # *defined* - the same predicate the contract checks use, so this exercises the whole pipeline
  # rather than just "nm emitted bytes" - the tool cannot read this file and has told us nothing.
  local probe reader_proved=""
  for probe in "${READER_SANITY_SYMBOLS[@]}"; do
    if symbol_defined "$lines" "$probe"; then
      reader_proved="$probe"
      break
    fi
  done
  if [ -z "$reader_proved" ]; then
    echo "Symbol reader cannot be trusted for $library." >&2
    echo "It produced output, but none of ${READER_SANITY_SYMBOLS[*]} came back as a defined" >&2
    echo "symbol. Every Skia build contains all of them, so this is a reader that cannot parse" >&2
    echo "this archive - not a verdict about which backends the archive holds." >&2
    echo "Reader was: $(resolve_llvm_nm)" >&2
    echo "Set LLVM_NM to an llvm-nm matching the clang that produced the archive." >&2
    return 1
  fi

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

# Everything above is about Skia's own backend implementation - GrMtlGpu, GrGLGpu - which is
# necessary and not sufficient. The defect this fork exists for lives one layer up, in SkiaSharp's
# C API, and none of the checks above can see it: gr_direct_context_make_metal keeps its symbol and
# returns nullptr when the backend was not compiled into that translation unit (SK_ONLY_METAL, in
# src/c/sk_types_priv.h - the same mechanism as the SK_ONLY_VULKAN that started all this), so "the
# entry point is defined" is precisely the evidence a stub produces too. Avalonia then creates a
# device, hands it to Skia, gets nothing back, and the window opens, stays responsive, logs nothing
# and never paints.
#
# What tells a wired entry point from a stub is what its own object file references:
#     return SK_ONLY_METAL(ToGrDirectContext(GrDirectContext::MakeMetal(
#         device, queue).release()), nullptr);
# leaves a mangled reference carrying MakeMetal - and GrMtlBackendContext as well on the newer
# GrDirectContexts::MakeMetal(const GrMtlBackendContext&) spelling - while the stub body is
# `return nullptr` and references neither.
#
# Measured on the payload already in this tree rather than assumed, and Metal is what it was
# measured on: in External/NativeStatic/static-Vulkan/win-x64/native/skia.lib, member
# obj/src/c/skia.gr_context.obj defines gr_direct_context_make_metal - stubbed there, because Metal
# is not built on Windows - with not one Metal name anywhere in that member, while
# gr_direct_context_make_gl in the same object sits beside MakeGL and GrGLInterface. One archive,
# one object file, opposite verdicts.
#
# Because the discriminator is per object file this takes its own nm pass with -A. The archive-wide
# dump above cannot say which member a name came from, and GrDirectContext::MakeMetal is *defined*
# elsewhere in libskia.a whether or not gr_context.cpp ever calls it - so an archive-wide grep
# would answer a different question and answer it wrongly.
#
# Both payload archives are read. src/c compiles into the skia target today - that member is inside
# skia.lib, and libSkiaSharp.a carries only src/xamarin - but that is SkiaSharp's layout, not a
# contract we control. Searching both means a version that relocates the C API comes out as a loud
# "cannot certify" here instead of an archive that ships with nobody having looked inside it.
#
#   backend : the entry point the managed side P/Invokes : names its real body must reference
# The Vulkan tier is delivered by Metal here, as the header explains, so it is the Metal entry
# point that has to be real.
C_API_CONTRACT=(
  "Vulkan:gr_direct_context_make_metal:MakeMetal|GrMtlBackendContext"
  "OpenGL:gr_direct_context_make_gl:MakeGL|GrGLInterface"
)

# nm -A prefixes every symbol line with the archive and member it came from. GNU nm glues the
# address straight onto that prefix, llvm-nm leaves a space, Apple's spells it archive(member): -
# so the portable member key is the first column with its last colon-separated field dropped. A
# first column with no colon in it means the reader ignored -A: there is then no member to key on,
# and the caller has to say it cannot certify rather than produce a verdict. Mach-O prefixes C
# symbols with an underscore, hence the second name. Every defining member is returned, not just
# the first, so a second copy of the entry point cannot hide behind a good one.
c_api_defining_members() {
  local dump="$1" entry="$2"
  awk -v want="$entry" '
    NF >= 3 && ($NF == want || $NF == "_" want) {
      type = $(NF - 1)
      if (type == "U" || type == "u" || type == "w" || type == "v") next
      key = $1
      if (key !~ /:/) next
      sub(/:[^:]*$/, "", key)
      if (!seen[key]++) print key
    }
  ' "$dump"
}

c_api_member_references() {
  local dump="$1" key="$2" tokens="$3"
  local lines
  # Not one pipeline, for the reason symbol_defined gives above: grep -q quits at its first match,
  # the reader dies writing to the closed pipe, and pipefail turns that into "no match".
  lines="$(grep -F -- "$key:" "$dump")" || return 1
  grep -Eq -- "$tokens" <<<"$lines"
}

assert_c_api_entry_points() {
  local applicable=() spec
  for spec in "${C_API_CONTRACT[@]}"; do
    if tier_claims "${spec%%:*}"; then
      applicable+=("$spec")
    fi
  done
  if [[ ${#applicable[@]} -eq 0 ]]; then
    echo "Tier '$TIER' claims no GPU backend, so it has no C entry point to certify."
    return 0
  fi

  local nm dump lib
  nm="$(resolve_llvm_nm)"
  dump="$(mktemp)"
  for lib in "$@"; do
    if ! "$nm" -A "$lib" >>"$dump" 2>/dev/null; then
      rm -f "$dump"
      echo "Symbol reader could not list $lib per member (nm -A)." >&2
      echo "Without per-member output a wired entry point and a stub are indistinguishable, so" >&2
      echo "this is a reader failure and not a verdict about the archive. Reader was: $nm" >&2
      return 1
    fi
  done

  local failures=() verified=() backend rest entry tokens members member wired
  for spec in "${applicable[@]}"; do
    backend="${spec%%:*}"
    rest="${spec#*:}"
    entry="${rest%%:*}"
    tokens="${rest#*:}"

    members="$(c_api_defining_members "$dump" "$entry")"
    if [ -z "$members" ]; then
      rm -f "$dump"
      echo "Cannot certify the $backend backend of tier '$TIER': nothing in the payload came back" >&2
      echo "as a definition of $entry, the entry point the managed side P/Invokes. Either no" >&2
      echo "archive defines it, or the reader ignored -A and there is no member to attribute it to." >&2
      echo "Either way this is 'could not check' and not 'checked and fine', and must not be" >&2
      echo "reported as the latter. Archives read: $*" >&2
      echo "If a SkiaSharp version moved src/c into another target, add that archive here - do" >&2
      echo "not drop the check." >&2
      return 1
    fi

    wired=1
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      if ! c_api_member_references "$dump" "$member" "$tokens"; then
        failures+=("tier '$TIER' claims $backend but $entry is a stub - its object ($member) references none of ${tokens//|/, }")
        wired=0
      fi
    done <<<"$members"

    if [[ "$wired" -eq 1 ]]; then
      verified+=("$entry")
    fi
  done
  rm -f "$dump"

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "C API entry points contradict tier '$TIER' (backends $BACKENDS):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    echo "A stub keeps its symbol and returns nullptr, which is exactly how a package comes to" >&2
    echo "advertise a backend and paint nothing. Get the backend's macro into SkiaSharp's C compile," >&2
    echo "or stop claiming the backend - do not relax this." >&2
    return 1
  fi

  echo "C API entry points wired, not stubbed, for tier '$TIER': ${verified[*]}."
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

  # SkiaSharp's C API has no SK_ONLY_GL, so skia_use_gl=false does not stub the GL entry points
  # and they fail to compile against declarations that are gone. This adds the missing macro.
  # It runs for every tier because it is a no-op wherever SK_GL is defined, and the tiers share
  # this checkout. See the header of the script for the full story.
  python3 "$ROOT_DIR/scripts/patch-skia-gl-stubs.py" "$skia_dir"

  # Ganesh stays ON for every tier, and skia_use_gl is what separates them.
  # The tidier expression of "no GPU pipeline at all" would be skia_enable_ganesh = false, and it
  # does not compile - this platform is where it was caught:
  #   src/c/gr_context.cpp:46: error: non-void function
  #   'gr_recording_context_get_direct_context' should return a value
  # SK_ONLY_GPU collapses to nothing, leaving that single-argument use with no return. It would
  # also strip SkSurfaces::WrapBackendRenderTarget and SkImages::BorrowTextureFrom out from under
  # src/c/sk_surface.cpp and src/c/sk_image.cpp, which use them with no guard at all - and that
  # break surfaces at the CONSUMER's link, not here, which is the worst place to find it.
  # Keeping Ganesh and dropping GL leaves only the raster path and satisfies assert_tier_symbols,
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
  assert_c_api_entry_points "$OUTPUT_DIR/libskia.a" "$OUTPUT_DIR/libSkiaSharp.a"
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
