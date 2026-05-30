#!/usr/bin/env bash
# audit_adversarial_coverage.sh — enforce the ARY-1887 AF taxonomy.
#
# For each of the 7 canonical AF classes (see
# docs/release-gate/af-taxonomy.md), this script verifies that at least
# one Rust fixture AND at least one Python fixture exists, OR an
# explicit deferral stub is present (only AF-tee qualifies in v1.0).
#
# Exit codes:
#   0  All 7 classes have evidence (fixtures or deferral stub)
#   1  At least one class is missing required coverage
#   2  Usage error / script ran in the wrong directory
#
# Run from repo root:
#   bash scripts/audit_adversarial_coverage.sh
#
# Wire into CI as a separate job; depends only on bash + find.

set -euo pipefail

# The 7 canonical AF class identifiers, in the order they appear in
# docs/release-gate/af-taxonomy.md. The script enforces evidence for
# EACH of these — adding a new class requires updating both this list
# AND the taxonomy doc.
AF_CLASSES=(
  AF-contracts
  AF-sdk
  AF-image
  AF-reconciler
  AF-tlog
  AF-tee
  AF-key
)

# Repo root is the directory containing this script's parent (scripts/).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "${REPO_ROOT}/Cargo.toml" ]; then
  echo "error: ${REPO_ROOT}/Cargo.toml not found." >&2
  echo "       This script must run from a checkout of unfireable-safety-kernel." >&2
  exit 2
fi
cd "${REPO_ROOT}"

# ----------------------------------------------------------------------
# Discovery rules.
#
# For a given AF class (e.g. AF-image), we look for:
#
#   Rust fixtures:
#     - Files matching tests/adversarial/seed/${class_underscored}_*.rs
#     - Files matching crates/*/tests/seed_${class_underscored}*.rs
#     - Pre-existing Rust files documented in af-taxonomy.md (e.g.
#       AF-sdk maps to crates/adapters/safety_kernel_client/tests/
#       adversarial.rs; AF-tlog maps to crates/services/transparency-log/
#       tests/purple_*.rs). These are listed below in EXISTING_RUST.
#
#   Python fixtures:
#     - Files matching tests/adversarial/python/${class_underscored}_*.py
#     - Files matching tests/adversarial/seed/${class_underscored}_*.py
#     - Pre-existing Python files documented in af-taxonomy.md (e.g.
#       AF-sdk maps to examples/testing/adversarial_fixtures.py).
#       Listed in EXISTING_PY below.
#
#   Deferral stub:
#     - A file at tests/adversarial/seed/${class_underscored}_DEFERRED.md
#       satisfies the class even if no fixture exists.
#
# All translations from "AF-image" to "af_image" use simple s/-/_/g.
# ----------------------------------------------------------------------

# Pre-existing files that count as Rust coverage for each class.
# This list comes from docs/release-gate/af-taxonomy.md's coverage matrix.
# Each entry is a (class, glob) pair. Update both this list AND the
# taxonomy doc when new files are recognized.
declare -A EXISTING_RUST=(
  [AF-contracts]="crates/services/transparency-log/tests/purple_idempotency_collision.rs"
  [AF-sdk]="crates/adapters/safety_kernel_client/tests/adversarial.rs"
  [AF-reconciler]="crates/services/safety-kernel-reconciler/tests/purple_manifest_replay.rs"
  [AF-tlog]="crates/services/transparency-log/tests/purple_forged_sth.rs"
)

declare -A EXISTING_PY=(
  [AF-contracts]="examples/testing/adversarial_fixtures.py"
  [AF-sdk]="examples/testing/adversarial_fixtures.py"
)

# Find matching files. Empty result is a missed class.
find_seed() {
  local pattern="$1"
  # shellcheck disable=SC2086
  find tests/adversarial crates -type f -name "${pattern}" 2>/dev/null || true
}

# ----------------------------------------------------------------------
# Main loop.
# ----------------------------------------------------------------------
status=0
echo "audit_adversarial_coverage.sh — release-gate AF taxonomy enforcement"
echo "------------------------------------------------------------------"
echo "repo root: ${REPO_ROOT}"
echo ""

for class in "${AF_CLASSES[@]}"; do
  # Normalize "AF-image" → "af_image" (lowercase, hyphen→underscore) so
  # the file lookups match the actual on-disk naming convention.
  underscored="$(echo "${class//-/_}" | tr '[:upper:]' '[:lower:]')"

  # Deferral stub short-circuits everything else.
  deferral="tests/adversarial/seed/${underscored}_DEFERRED.md"
  if [ -f "${deferral}" ]; then
    printf '  [DEFERRED] %-16s  %s\n' "${class}" "${deferral}"
    continue
  fi

  rust_hits=""
  py_hits=""

  # Rust: seed/<class>_*.rs anywhere in tests/, crates/*/tests/seed_<class>_*.rs,
  # plus declared EXISTING_RUST.
  rust_seed=$(find_seed "${underscored}_*.rs")
  rust_crate=$(find_seed "seed_${underscored}*.rs")
  rust_existing="${EXISTING_RUST[${class}]:-}"
  if [ -n "${rust_existing}" ] && [ -f "${rust_existing}" ]; then
    rust_hits="${rust_hits}${rust_existing}"$'\n'
  fi
  if [ -n "${rust_seed}" ]; then
    rust_hits="${rust_hits}${rust_seed}"$'\n'
  fi
  if [ -n "${rust_crate}" ]; then
    rust_hits="${rust_hits}${rust_crate}"$'\n'
  fi

  # Python: tests/adversarial/python/<class>_*.py, tests/adversarial/seed/<class>_*.py,
  # plus declared EXISTING_PY.
  py_seed=$(find_seed "${underscored}_*.py")
  py_existing="${EXISTING_PY[${class}]:-}"
  if [ -n "${py_existing}" ] && [ -f "${py_existing}" ]; then
    py_hits="${py_hits}${py_existing}"$'\n'
  fi
  if [ -n "${py_seed}" ]; then
    py_hits="${py_hits}${py_seed}"$'\n'
  fi

  rust_count=$(printf '%s' "${rust_hits}" | grep -c . || true)
  py_count=$(printf '%s' "${py_hits}" | grep -c . || true)

  if [ "${rust_count}" -eq 0 ] || [ "${py_count}" -eq 0 ]; then
    printf '  [MISSING]  %-16s  rust=%d  python=%d\n' \
      "${class}" "${rust_count}" "${py_count}"
    if [ "${rust_count}" -eq 0 ]; then
      echo "             needs: a Rust fixture at tests/adversarial/seed/${underscored}_*.rs"
      echo "                    OR crates/<crate>/tests/seed_${underscored}*.rs"
    fi
    if [ "${py_count}" -eq 0 ]; then
      echo "             needs: a Python fixture at tests/adversarial/python/${underscored}_*.py"
    fi
    status=1
  else
    printf '  [ok]       %-16s  rust=%d  python=%d\n' \
      "${class}" "${rust_count}" "${py_count}"
  fi
done

echo ""
if [ "${status}" -eq 0 ]; then
  echo "All 7 AF classes have evidence (fixtures or deferral stub)."
  echo "Release-gate AF coverage: PASS"
else
  echo "Release-gate AF coverage: FAIL — see [MISSING] entries above."
  echo "See docs/release-gate/af-taxonomy.md for the canonical class definitions."
fi
exit "${status}"
