# Shared helpers for the build and release scripts. Source it, don't run it.
#
#   . "$(dirname "$0")/common.sh"

DIVOICE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Settings from project.env; variables already set in the environment win.
load_project_env() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    if [ -z "${!key+x}" ]; then export "$key=$value"; fi
  done < "$DIVOICE_ROOT/project.env"
}

# Version being built: $DIVOICE_VERSION (test builds) or app/VERSION.
divoice_version() {
  local version="${DIVOICE_VERSION:-$(tr -d '[:space:]' < "$DIVOICE_ROOT/app/VERSION")}"
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version '$version': expected MAJOR.MINOR.PATCH" >&2
    return 1
  fi
  echo "$version"
}

# CFBundleVersion and sparkle:version: MAJOR*10000 + MINOR*100 + PATCH (0.3.0 -> 300).
# It only depends on the version, never on the git history, so it keeps growing
# across repositories. MINOR and PATCH must stay below 100.
divoice_build_number() {
  local version="$1" major minor patch
  IFS=. read -r major minor patch <<< "$version"
  if [ "$minor" -ge 100 ] || [ "$patch" -ge 100 ]; then
    echo "Version $version: MINOR and PATCH must be below 100" >&2
    return 1
  fi
  echo $((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
}
