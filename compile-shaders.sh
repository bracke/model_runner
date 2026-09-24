#!/bin/sh
#  Compile every device shader and write src/library/model_runner-shaders.ads.
#
#  The Ada package holds each compiled shader as a Word_Array named for the
#  compiled file, with the digest of its source beside it; `tests shader`
#  writes the package whole from the (source, compiled) pairs it is given, so
#  every variant must be named on one call or the package loses the ones left
#  out.  A shader source is compiled once, or several times with different
#  defines where the engine binds it as several pipelines -- attention.comp
#  six ways, matrix_product.comp six, and the two subgroup pairs.
#
#  The defines and the SPIR-V version each variant needs are below.  This
#  recipe was checked by regenerating the package from it and finding it byte
#  for byte the one in the tree, so a build from here is the build that is
#  committed.  glslangValidator picks the SPIR-V version from --target-env:
#  vulkan1.0 gives 1.0, vulkan1.1 gives 1.3 (the subgroup and fp16 kernels),
#  vulkan1.3 gives 1.6 (the cooperative-matrix kernels).
#
#  Run from the repository root.  Needs glslangValidator and a built tests
#  tool (tests/bin/tests).

set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
SPV=$(mktemp -d)
trap 'rm -rf "$SPV"' EXIT

TESTS="$ROOT/tests/bin/tests"
if [ ! -x "$TESTS" ]; then
    echo "build the tests tool first: (cd tests && alr build)" >&2
    exit 1
fi

PAIRS=""

#  compile NAME SOURCE TARGET [DEFINE ...]
#    NAME is the compiled file's stem, which is the Ada constant's name; the
#    source is named to `tests shader` so the digest is the source's.
compile () {
    name=$1; src=$2; target=$3; shift 3
    out="$SPV/$name.spv"
    defs=""
    for d in "$@"; do defs="$defs -D$d"; done
    # shellcheck disable=SC2086
    glslangValidator --target-env "$target" $defs "$ROOT/src/shaders/$src" -o "$out"
    PAIRS="$PAIRS ../src/shaders/$src $out"
}

compile attention                    attention.comp        vulkan1.0
compile attention_subgroups          attention.comp        vulkan1.1 SUBGROUPS WIDE
compile attention_tiled              attention.comp        vulkan1.1 SUBGROUPS QUERY_TILE
compile attention_halved             attention.comp        vulkan1.1 SUBGROUPS HALVED WIDE
compile attention_bundled            attention.comp        vulkan1.1 SUBGROUPS HALVED WIDE GROUPED
compile attention_bundle_exact       attention.comp        vulkan1.1 SUBGROUPS WIDE FOURS GROUPED
compile combine                      combine.comp          vulkan1.0
compile row_product                  row_product.comp      vulkan1.0
compile row_product_low              row_product.comp      vulkan1.0 LOW_BITS
compile row_product_super            row_product_super.comp vulkan1.1 NUM_ROWS=2u
compile row_product_super5           row_product_super5.comp vulkan1.1 NUM_ROWS=2u
compile row_product_super6           row_product_super6.comp vulkan1.1 NUM_ROWS=2u
compile half_batch                   half_batch.comp       vulkan1.0
compile matrix_product               matrix_product.comp   vulkan1.3
compile matrix_extra                 matrix_product.comp   vulkan1.3 MORE_FORMATS
compile matrix_narrow                matrix_product.comp   vulkan1.3 NARROW
compile matrix_narrow_extra          matrix_product.comp   vulkan1.3 MORE_FORMATS NARROW
compile matrix_listed                matrix_product.comp   vulkan1.3 LISTED
compile matrix_listed_extra          matrix_product.comp   vulkan1.3 MORE_FORMATS LISTED
compile attention_matrix             attention_matrix.comp vulkan1.3
compile attention_matrix_wide        attention_matrix.comp vulkan1.3 WIDE_HEAD
compile norm                         norm.comp             vulkan1.0
compile rotate                       rotate.comp           vulkan1.0
compile place                        place.comp            vulkan1.0
compile route                        route.comp            vulkan1.0
compile mix                          mix.comp              vulkan1.0
compile heads                        heads.comp            vulkan1.0
compile merge                        merge.comp            vulkan1.0
compile thin                         thin.comp             vulkan1.0
compile invert                       invert.comp           vulkan1.0
compile attention_packed             attention_packed.comp vulkan1.0
compile pack                         pack.comp             vulkan1.0
compile unpack                       unpack.comp           vulkan1.1
compile bias                         bias.comp             vulkan1.0
compile attention_packed_subgroups   attention_packed.comp vulkan1.1 SUBGROUPS
compile pack_subgroups               pack.comp             vulkan1.1 SUBGROUPS
compile pick                         pick.comp             vulkan1.0
compile conv                         conv.comp             vulkan1.0
compile rule                         rule.comp             vulkan1.0

# shellcheck disable=SC2086
(cd "$ROOT/tests" && "$TESTS" shader $PAIRS)
