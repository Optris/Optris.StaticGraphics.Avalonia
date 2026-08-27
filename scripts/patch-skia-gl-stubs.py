#!/usr/bin/env python3
"""Teach SkiaSharp's C API to stub out OpenGL, so a GPU-less tier can be built at all.

WHY THIS EXISTS
---------------
SkiaSharp's C API stubs a backend it was not built with rather than dropping the entry point:
`gr_direct_context_make_vulkan` returns nullptr when skia_use_vulkan is false, so the ABI stays
constant and a caller gets a null context instead of a missing export. That mechanism is spelled
`SK_ONLY_VULKAN` / `SK_ONLY_METAL` / `SK_ONLY_DIRECT3D` in src/c/sk_types_priv.h.

There is no `SK_ONLY_GL`. OpenGL is the one backend the C API assumes is always present whenever
Ganesh is, so every GL entry point in src/c/gr_context.cpp is guarded by `SK_ONLY_GPU` - which is
keyed on SK_GANESH, not on SK_GL. Building with skia_use_gl=false therefore does not stub those
functions; it leaves them compiling against declarations that are no longer there:

    include/gpu/ganesh/GrDirectContext.h:65   #if defined(SK_GL) ...
        static sk_sp<GrDirectContext> MakeGL(sk_sp<const GrGLInterface>);
    -> error: no member named 'MakeGL' in 'GrDirectContext'

and BUILD.gn:978-979 adds `SK_GL` to public_defines only `if (skia_use_gl)`, so the whole GL
implementation goes with it.

The other way round is no better. skia_enable_ganesh=false makes `SK_ONLY_GPU(x)` expand to
nothing, and gr_context.cpp:46 is a single-argument use in a non-void function:

    return SK_ONLY_GPU(ToGrDirectContext(GrAsDirectContext(AsGrRecordingContext(context))));
    -> error: non-void function 'gr_recording_context_get_direct_context' should return a value

and it would also strip SkSurfaces::WrapBackendRenderTarget / SkImages::BorrowTextureFrom and
friends out from under src/c/sk_surface.cpp and src/c/sk_image.cpp, which reference them with no
guard at all - a break that only surfaces at the consumer's final link.

Upstream never hits either wall because it never builds either configuration: `SUPPORT_GPU`
(native/*/build.cake) defaults true and no pipeline sets it, and `skia_use_gl` appears nowhere in
mono/SkiaSharp at all. That is why the stub is missing rather than broken - the code path has no
CI behind it.

So this adds the macro the file's own design implies, and re-guards exactly the GL entry points
with it. That is the smaller and more faithful of the two repairs: it stays inside the idiom
already used for Vulkan, Metal and Direct3D, touches one header and one .cpp, and is the shape a
patch would have to take to be worth sending upstream - which is the only thing that would ever
retire it.

WHY IT RUNS FOR EVERY TIER, NOT JUST THE GPU-LESS ONE
-----------------------------------------------------
`SK_ONLY_GL` collapses to `SK_ONLY_GPU`'s behaviour whenever SK_GL is defined, so applying this
to a Vulkan or OpenGL build changes nothing it compiles. That matters because the tiers SHARE one
SkiaSharp checkout to avoid re-syncing gigabytes per tier: a patch applied only for some tiers
would leave the shared tree in a state that depends on which tier built last. Unconditional and
idempotent is the only form that is safe against that.

FAILURE POLICY
--------------
Loudly, always. This edits a pinned third-party checkout, so the thing to fear is a SkiaSharp
version bump silently changing the code out from under a regex and this quietly patching nothing
- which would come back as the same confusing MakeGL error hours into a build. Every anchor is
asserted, and a miss is a non-zero exit naming what was not found. Same policy as
Patch-WinX86SkiaLinker in build-windows-static-graphics.ps1, for the same reason.
"""

import pathlib
import re
import sys

# Every GL-specific entry point in the C API, identified by name rather than by line number so a
# version bump shifts nothing. Verified against SkiaSharp 3.119.4 (mono/skia
# 7dbfc07dd33181f84e0958afb7ee805c6c769f0b): the file holds 66 top-level functions, of which
# exactly these 14 carry 'gl' in their name and exactly these 14 contain any GL token at all. The
# partition is clean in both directions - no GL-named function is GL-free, and no other function
# so much as mentions MakeGL, GrGLInterface, GrGLMake*, Get*GL*Info or AsGrGL* - which is what
# makes selecting by name safe here.
GL_FUNCTION_PATTERN = re.compile(r"gl")

# A GL token appearing outside a GL-named function would mean the partition above no longer holds
# and this script is patching the wrong set.
GL_TOKEN_PATTERN = re.compile(
    r"MakeGL|GrGLInterface|GrGLMake|GetGLTextureInfo|GetGLFramebufferInfo|AsGrGL"
)

FUNCTION_HEADER_PATTERN = re.compile(
    r"^[A-Za-z_].*?\b([a-z_][a-z0-9_]*)\s*\([^;]*\)\s*\{\s*$"
)

GANESH_ANCHOR = "#    define SK_ONLY_GPU(...) SK_FIRST_ARG(__VA_ARGS__)"
NO_GANESH_ANCHOR = "#    define SK_ONLY_GPU(...) SK_SKIP_ARG(__VA_ARGS__)"

# Keyed on defined(SK_GL) to match how include/gpu/ganesh/GrDirectContext.h guards MakeGL itself,
# and nested inside SK_GANESH the same way SK_ONLY_VULKAN is: GL cannot be present without Ganesh.
GANESH_INSERT = """#    if defined(SK_GL)
#        define SK_ONLY_GL(...) SK_FIRST_ARG(__VA_ARGS__)
#    else
#        define SK_ONLY_GL(...) SK_SKIP_ARG(__VA_ARGS__)
#    endif"""

NO_GANESH_INSERT = "#    define SK_ONLY_GL(...) SK_SKIP_ARG(__VA_ARGS__)"


def fail(message):
    sys.exit(f"patch-skia-gl-stubs: {message}")


def split_functions(text):
    """Yield (name, start, end) for each top-level function body, by brace matching."""
    lines = text.split("\n")
    offsets, running = [], 0
    for line in lines:
        offsets.append(running)
        running += len(line) + 1

    for index, line in enumerate(lines):
        match = FUNCTION_HEADER_PATTERN.match(line)
        if not match:
            continue
        depth = 0
        for scan in range(index, len(lines)):
            depth += lines[scan].count("{") - lines[scan].count("}")
            if depth == 0:
                yield match.group(1), offsets[index], offsets[scan] + len(lines[scan])
                break


def patch_types_priv(path):
    text = path.read_text(encoding="utf-8")
    if "SK_ONLY_GL(" in text:
        return False

    for anchor in (GANESH_ANCHOR, NO_GANESH_ANCHOR):
        if text.count(anchor) != 1:
            fail(
                f"expected exactly one occurrence of\n    {anchor}\nin {path}, found "
                f"{text.count(anchor)}. SkiaSharp's stub macros have been restructured; rework "
                f"this patch against the new shape rather than loosening the match."
            )

    text = text.replace(GANESH_ANCHOR, GANESH_ANCHOR + "\n" + GANESH_INSERT, 1)
    text = text.replace(NO_GANESH_ANCHOR, NO_GANESH_ANCHOR + "\n" + NO_GANESH_INSERT, 1)
    path.write_text(text, encoding="utf-8")
    return True


def patch_gr_context(path):
    text = path.read_text(encoding="utf-8")
    if "SK_ONLY_GL(" in text:
        return False, 0, 0

    functions = list(split_functions(text))
    if not functions:
        fail(
            f"found no top-level function definitions in {path}. The file's formatting has "
            f"changed enough that this patch cannot locate anything; rework it."
        )

    stray = [
        name
        for name, start, end in functions
        if not GL_FUNCTION_PATTERN.search(name) and GL_TOKEN_PATTERN.search(text[start:end])
    ]
    if stray:
        fail(
            "these functions are not GL-named yet use the GL API: "
            + ", ".join(sorted(stray))
            + ". Selecting GL entry points by name is no longer sound - re-derive the list "
            "before letting this patch run."
        )

    pieces, cursor, replaced, touched = [], 0, 0, []
    for name, start, end in functions:
        if not GL_FUNCTION_PATTERN.search(name):
            continue
        body = text[start:end]
        count = body.count("SK_ONLY_GPU(")
        if count == 0:
            continue
        pieces.append(text[cursor:start])
        pieces.append(body.replace("SK_ONLY_GPU(", "SK_ONLY_GL("))
        cursor = end
        replaced += count
        touched.append(name)
    pieces.append(text[cursor:])

    if replaced == 0:
        fail(
            f"found no SK_ONLY_GPU uses inside the GL entry points of {path}. Either they are "
            f"already guarded some other way or the file has been restructured; either way this "
            f"patch must not silently do nothing."
        )

    path.write_text("".join(pieces), encoding="utf-8")
    return True, replaced, len(touched)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch-skia-gl-stubs.py <skia-checkout-dir>")

    skia_dir = pathlib.Path(sys.argv[1])
    types_priv = skia_dir / "src" / "c" / "sk_types_priv.h"
    gr_context = skia_dir / "src" / "c" / "gr_context.cpp"
    for path in (types_priv, gr_context):
        if not path.is_file():
            fail(f"{path} does not exist. Is '{skia_dir}' really a skia checkout?")

    header_patched = patch_types_priv(types_priv)
    source_patched, replaced, functions = patch_gr_context(gr_context)

    if not header_patched and not source_patched:
        print("SK_ONLY_GL already present; nothing to patch.")
        return

    # A half-applied patch is worse than none: the macro without the call sites changes nothing,
    # and the call sites without the macro will not compile in any configuration.
    if header_patched != source_patched:
        fail(
            f"patched only one of the two files (header={header_patched}, "
            f"source={source_patched}). The checkout is now inconsistent - delete it and re-sync."
        )

    print(
        f"Added SK_ONLY_GL and re-guarded {replaced} call site(s) across {functions} GL entry "
        f"point(s) in {gr_context.name}."
    )


if __name__ == "__main__":
    main()
