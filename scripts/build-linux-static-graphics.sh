#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Each tier is a strict superset of the one below it, so no package can leave a hole in an
# Avalonia render-backend fallback chain: whatever a tier claims, it also claims everything
# under it. The names are part of the cross-repo contract - they become the payload
# directory, the PackageId suffix and the OptrisStaticGraphicsBackends property.
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
TARGET_CPU="${TARGET_CPU:-x64}"
RID="${RID:-linux-$TARGET_CPU}"
# Tiers differ only in what is compiled in, so they share WORK_DIR - the multi-GB
# depot_tools/SkiaSharp checkout is cloned once and reused by every tier - while the payload
# is kept apart per tier so one tier can never overwrite another's archives.
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/External/NativeStatic/static-$TIER/$RID/native}"
SKIASHARP_VERSION="${SKIASHARP_VERSION:-4.150.1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
SKIA_DEPS_RETRIES="${SKIA_DEPS_RETRIES:-3}"

usage() {
  cat <<'USAGE'
Usage: scripts/build-linux-static-graphics.sh [skia|all]

Environment:
  TIER                Graphics tier: Vulkan, OpenGL or Software. Default: Vulkan
  WORK_DIR            Source/build cache directory, shared by all tiers.
                      Default: External/NativeStatic/.work
  OUTPUT_DIR          Final static library directory.
                      Default: External/NativeStatic/static-$TIER/$RID/native
  SKIASHARP_VERSION   SkiaSharp release branch version. Default: 4.150.1
  TARGET_CPU          GN target_cpu. Default: x64. Supported: x64, arm64
  RID                 Output RID. Default: linux-$TARGET_CPU
  BUILD_JOBS          Ninja parallelism. Default: nproc
  LLVM_NM             llvm-nm used to verify the tier contract. Default: autodetected

ANGLE is not built on Linux: the consumer targets never reference av_libglesv2 outside
Windows, so nothing would ever pull the archive in.
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

is_musl_rid() {
  [[ "$RID" == linux-musl-* ]]
}

ensure_tools() {
  require_cmd git
  require_cmd python3
  require_cmd clang
  require_cmd clang++
  require_cmd ar
  require_cmd ninja
  require_cmd pkg-config
}

ensure_depot_tools() {
  local depot_dir="$WORK_DIR/depot_tools"
  local python_bin_dir
  python_bin_dir="$(dirname "$(command -v python3)")"
  if [[ ! -d "$depot_dir/.git" ]]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_dir"
  else
    git -C "$depot_dir" pull --ff-only
  fi
  if is_musl_rid; then
    initialize_depot_tools_system_python "$depot_dir"
    patch_depot_tools_python_deps "$depot_dir"
  fi
  export PATH="$python_bin_dir:$depot_dir:$PATH"
}

initialize_depot_tools_system_python() {
  local depot_dir="$1"
  local python_bin_dir
  python_bin_dir="$(dirname "$(command -v python3)")"

  if [[ -d "$depot_dir" ]]; then
    python3 - "$depot_dir" "$python_bin_dir" <<'PY'
import os
import pathlib
import sys

depot_dir = pathlib.Path(sys.argv[1]).resolve()
python_bin_dir = pathlib.Path(sys.argv[2]).resolve()
marker = depot_dir / "python3_bin_reldir.txt"
marker.write_text(os.path.relpath(python_bin_dir, depot_dir) + "\n")
PY
  fi
}

patch_depot_tools_python_deps() {
  local depot_dir="$1"
  local gsutil_dir="$depot_dir/external_bin/gsutil/gsutil_4.68/gsutil"
  local gsutil_third_party="$gsutil_dir/third_party"

  if [[ -d "$gsutil_dir" && ! -f "$gsutil_dir/six.py" ]]; then
    python3 - "$gsutil_dir/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi

  if [[ -d "$gsutil_third_party" && ! -f "$gsutil_third_party/six.py" ]]; then
    python3 - "$gsutil_third_party/six.py" <<'PY'
import pathlib
import shutil
import six
import sys

src = pathlib.Path(six.__file__)
dest = pathlib.Path(sys.argv[1])
shutil.copyfile(src, dest)
PY
  fi
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
  # own checkout. A distro llvm-nm reads these archives fine too, but a much older one can
  # choke on newer LLVM bitcode.
  if [[ -n "$SKIA_CHECKOUT_DIR" ]]; then
    candidates+=(
      "$SKIA_CHECKOUT_DIR/third_party/externals/llvm-build/Release+Asserts/bin/llvm-nm"
      "$SKIA_CHECKOUT_DIR/third_party/llvm-build/Release+Asserts/bin/llvm-nm"
      "$SKIA_CHECKOUT_DIR/bin/llvm-nm"
    )
  fi
  candidates+=("$WORK_DIR/depot_tools/llvm-build/Release+Asserts/bin/llvm-nm")

  # Alpine's llvm package installs only a versioned tree - /usr/lib/llvm19/bin/llvm-nm and no
  # /usr/bin/llvm-nm - so every name below misses it and resolution falls through to GNU nm,
  # which cannot read the LTO bitcode archives is_official_build produces. That fallback is how
  # musl came to report backends missing from an archive that demonstrably contained them.
  # Newest first, so a box with several LLVM versions gets the one most likely to match clang.
  local versioned
  while IFS= read -r versioned; do
    [[ -n "$versioned" ]] && candidates+=("$versioned")
  done < <(ls -1d /usr/lib/llvm*/bin/llvm-nm /usr/lib/llvm-*/bin/llvm-nm 2>/dev/null | sort -Vr)

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      LLVM_NM_RESOLVED="$candidate"
      echo "$LLVM_NM_RESOLVED"
      return 0
    fi
  done

  # Distro LLVM installs versioned binaries; the clang in use names the version to try.
  local clang_major names=(llvm-nm)
  clang_major="$(clang -dumpversion 2>/dev/null | cut -d. -f1 || true)"
  if [[ -n "$clang_major" ]]; then
    names+=("llvm-nm-$clang_major")
  fi
  names+=(nm)

  local name
  for name in "${names[@]}"; do
    if command -v "$name" >/dev/null 2>&1; then
      LLVM_NM_RESOLVED="$(command -v "$name")"
      echo "$LLVM_NM_RESOLVED"
      return 0
    fi
  done

  echo "Could not find llvm-nm. Set LLVM_NM, or install LLVM. Searched:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  printf '  %s on PATH\n' "${names[@]}" >&2
  return 1
}

# Every name the tier contract cares about. One nm pass over a multi-hundred-MB archive is
# expensive, so the output is filtered down to these once and then queried in memory.
# SkCanvas/SkSurface/SkImage are not part of the contract; they are the reader's own proof of
# life, and they have to survive this filter for assert_tier_symbols to be able to check it.
TIER_SYMBOL_PATTERN='GrVkGpu|GrVkCaps|GrVkBackendContext|AMDMemoryAllocator|GrGLGpu|GrGLInterface|vkCreateInstance|SkCanvas|SkSurface|SkImage'
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
  # This is the whole reason the fork exists. Upstream shipped a package that advertised
  # Vulkan while SkiaSharp had only stubbed it out (gr_direct_context_make_vulkan returns
  # nullptr when skia_use_vulkan is false), so an app that asked for Vulkan rendered a blank
  # window with no crash, no log and no fallback. Presence alone is not enough: a reduced
  # tier that quietly contains a backend is just as wrong, because the consumer guard and
  # the published backend list would then be lying in the other direction.
  local library="$1"
  local lines failures=() name
  lines="$(tier_symbol_lines "$library")"

  # A reader that returns nothing is the dangerous case, not an obvious one: every "must be
  # defined" check fails, which looks like a broken build, while every "must not contain" check
  # PASSES - so the Software tier would sail through on an empty read and ship unverified. That
  # is the same silent-pass shape this repository exists to prevent.
  if [ -z "$lines" ]; then
    echo "Symbol reader returned nothing for $library." >&2
    echo "That is a broken reader, not a verdict: even a Software build contains Skia's own" >&2
    echo "symbols, so the pattern should always match something. Reader was: $(resolve_llvm_nm)" >&2
    return 1
  fi

  # Non-empty is not the same as trustworthy, and the difference has already cost us. On musl
  # this function reported GrVkGpu, GrGLGpu and GrGLInterface all missing from an archive whose
  # own build log showed GrVkGpu.cpp and GrGLGpu.cpp compiling - 32 Vulkan and 32 GL sources,
  # the identical 1194-target build that passed on glibc. The verdict was false, it read exactly
  # like a real backend gap, and a RID was dropped on the strength of it. The earlier "no nm at
  # all" fix made this worse rather than better: installing binutils satisfied the emptiness
  # check with a GNU nm that cannot parse LTO bitcode archives, turning a loud failure into a
  # confident wrong answer.
  # So the reader must prove itself on this archive before any of its "not defined" verdicts
  # count. SkCanvas/SkSurface/SkImage are in every Skia build ever configured; if none of them
  # reads back as *defined* - the same predicate the contract checks use, so this exercises the
  # whole pipeline and not just "nm emitted bytes" - then the tool cannot read this file and it
  # has told us nothing about which backends are in it.
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
    echo "The usual cause is GNU nm on an LTO archive: is_official_build compiles to LLVM" >&2
    echo "bitcode, which only a matching llvm-nm can read. Set LLVM_NM to one." >&2
    return 1
  fi

  if tier_claims Vulkan; then
    # GrVkAMDMemoryAllocator/skgpu::VulkanAMDMemoryAllocator is not optional: Skia's Vulkan
    # backend without VMA fails exactly like a stubbed one, silently.
    for name in GrVkGpu AMDMemoryAllocator; do
      if ! symbol_defined "$lines" "$name"; then
        failures+=("tier '$TIER' claims Vulkan but '$name' is not defined in $library")
      fi
    done
  else
    for name in GrVkGpu GrVkCaps GrVkBackendContext AMDMemoryAllocator vkCreateInstance; do
      if symbol_mentioned "$lines" "$name"; then
        failures+=("tier '$TIER' must not contain Vulkan but '$name' appears in $library")
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

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "Tier contract violated (tier '$TIER', backends $BACKENDS):" >&2
    printf '  %s\n' "${failures[@]}" >&2
    return 1
  fi

  echo "Tier '$TIER' symbol contract verified in $library: backends $BACKENDS."
}

# Everything above is about Skia's own backend implementation - GrVkGpu, GrGLGpu - which is
# necessary and not sufficient. The defect this fork exists for lives one layer up, in SkiaSharp's
# C API, and none of the checks above can see it: gr_direct_context_make_vulkan keeps its symbol
# and returns nullptr when the backend was not compiled into that translation unit (SK_ONLY_VULKAN,
# in src/c/sk_types_priv.h), so "the entry point is defined" is precisely the evidence a stub
# produces too. Avalonia then creates a Vulkan device, hands it to Skia, gets nothing back, and the
# window opens, stays responsive, logs nothing and never paints.
#
# What tells a wired entry point from a stub is what its own object file references:
#     return SK_ONLY_VULKAN(ToGrDirectContext(GrDirectContext::MakeVulkan(
#         AsGrVkBackendContext(&vkBackendContext)).release()), nullptr);
# leaves one mangled reference carrying both MakeVulkan and GrVkBackendContext, while the stub body
# is `return nullptr` and references neither.
#
# Measured on the payload already in this tree rather than assumed: in
# External/NativeStatic/static-Vulkan/win-x64/native/skia.lib, member obj/src/c/skia.gr_context.obj
# holds gr_direct_context_make_vulkan beside MakeVulkan and GrVkBackendContext and
# gr_direct_context_make_gl beside MakeGL and GrGLInterface - and holds gr_direct_context_make_metal,
# stubbed there because Metal is not built on Windows, with not one Metal name anywhere in that
# member. One archive, one object file, opposite verdicts.
#
# Because the discriminator is per object file this takes its own nm pass with -A. The archive-wide
# dump above cannot say which member a name came from, and GrDirectContext::MakeVulkan is *defined*
# elsewhere in libskia.a whether or not gr_context.cpp ever calls it - so an archive-wide grep
# would answer a different question and answer it wrongly.
#
# Both payload archives are read. src/c compiles into the skia target today - that member is inside
# skia.lib, and libSkiaSharp.a carries only src/xamarin - but that is SkiaSharp's layout, not a
# contract we control. Searching both means a version that relocates the C API comes out as a loud
# "cannot certify" here instead of an archive that ships with nobody having looked inside it.
#
#   backend : the entry point the managed side P/Invokes : names its real body must reference
C_API_CONTRACT=(
  "Vulkan:gr_direct_context_make_vulkan:MakeVulkan|GrVkBackendContext"
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
  local skia_dir="$1/externals/skia"
  if [[ ! -x "$skia_dir/bin/gn" ]]; then
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
  fi
}

build_skia() {
  ensure_tools
  ensure_depot_tools
  local src
  src="$(sync_skiasharp)"
  sync_skia_deps "$src"

  local skia_dir="$src/externals/skia"
  SKIA_CHECKOUT_DIR="$skia_dir"

  # SkiaSharp's C API has no SK_ONLY_GL, so skia_use_gl=false does not stub the GL entry points
  # and they fail to compile against declarations that are gone. This adds the missing macro.
  # It runs for every tier because it is a no-op wherever SK_GL is defined, and the tiers share
  # this checkout. See the header of the script for the full story.
  python3 "$ROOT_DIR/scripts/patch-skia-gl-stubs.py" "$skia_dir"

  # Ganesh stays ON for every tier, and skia_use_gl is what separates them.
  # The tidier expression of "no GPU pipeline at all" would be skia_enable_ganesh = false, and it
  # does not compile: SK_ONLY_GPU collapses to nothing, so the single-argument use at
  # src/c/gr_context.cpp:46 leaves 'gr_recording_context_get_direct_context' with no return. It
  # would also strip SkSurfaces::WrapBackendRenderTarget and SkImages::BorrowTextureFrom out from
  # under src/c/sk_surface.cpp and src/c/sk_image.cpp, which use them with no guard at all - and
  # that break surfaces at the CONSUMER's link, not here, which is the worst place to find it.
  # Keeping Ganesh and dropping GL leaves only the raster path, drops ANGLE - much the larger
  # part of the size win - and satisfies assert_tier_symbols, because GrGLGpu and GrGLInterface
  # are compiled only when skia_use_gl is true.
  local skia_enable_ganesh="true"
  local skia_use_gl="false"
  if tier_claims OpenGL; then
    skia_use_gl="true"
  fi
  # Skia vendors the Vulkan headers and gn/skia.gni derives skia_use_vma from skia_use_vulkan,
  # so no new dependency is needed here. Skia never links a Vulkan library either - it
  # resolves entry points through a caller-supplied proc-address getter that Avalonia
  # provides - which is why nothing below adds vulkan-1.
  local skia_use_vulkan="false"
  if tier_claims Vulkan; then
    skia_use_vulkan="true"
  fi

  # Per-tier build directory inside the shared checkout: switching tiers must not force a
  # full re-sync, and two tiers building concurrently must not fight over one ninja dir.
  local out_dir="$skia_dir/out/linux-static-$TIER-$TARGET_CPU"
  mkdir -p "$out_dir" "$OUTPUT_DIR"

  cat >"$out_dir/args.gn" <<EOF_ARGS
target_os = "linux"
target_cpu = "$TARGET_CPU"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = $skia_enable_ganesh
skia_use_gl = $skia_use_gl
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = true
skia_use_freetype = true
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_sfntly = false
skia_use_system_expat = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = $skia_use_vulkan
skia_use_xps = false
cc = "clang"
cxx = "clang++"
ar = "ar"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DHAVE_SYSCALL_GETRANDOM",
  "-DXML_DEV_URANDOM",
]
extra_cflags_cc = [ "-frtti" ]
extra_ldflags = [ "-static-libstdc++", "-static-libgcc" ]
EOF_ARGS

  (cd "$skia_dir" && "$skia_dir/bin/gn" gen "$out_dir")
  ninja -C "$out_dir" -j "$BUILD_JOBS" skia SkiaSharp HarfBuzzSharp

  copy_first_existing "$OUTPUT_DIR/libskia.a" \
    "$out_dir/libskia.a" \
    "$out_dir/obj/libskia.a"
  copy_first_existing "$OUTPUT_DIR/libSkiaSharp.a" \
    "$out_dir/libSkiaSharp.a" \
    "$out_dir/obj/libSkiaSharp.a"
  copy_first_existing "$OUTPUT_DIR/libHarfBuzzSharp.a" \
    "$out_dir/libHarfBuzzSharp.a" \
    "$out_dir/obj/libHarfBuzzSharp.a"

  assert_tier_symbols "$OUTPUT_DIR/libskia.a"
  assert_c_api_entry_points "$OUTPUT_DIR/libskia.a" "$OUTPUT_DIR/libSkiaSharp.a"
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

main() {
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  echo "Building tier '$TIER' (backends $BACKENDS) for $RID into $OUTPUT_DIR"
  case "${1:-all}" in
    skia|all) build_skia ;;
    angle)
      echo "ANGLE is not built on Linux: the consumer targets never reference av_libglesv2 outside Windows, so nothing would pull the archive in." >&2
      exit 1
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
