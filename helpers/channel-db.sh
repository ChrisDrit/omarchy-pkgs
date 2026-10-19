# Read a published channel database (omarchy.db, as repo-add writes it).
#
# channel_db_entries <url> <channel> <arch> prints one tab-separated line per
# entry: channel, arch, pkgbase, name, version, build date. A unique query
# string gets past a CDN copy of the previous database.
#
# It fails, saying why, when the database can't be downloaded or unpacked,
# or when an entry is not a record repo-add writes: a directory without a
# desc, or a desc without %NAME%, %BASE% or %VERSION%. unpublish-packages
# finds entries by %BASE%, and an entry that can't be read would otherwise
# drop out of every check without a word.
channel_db_entries() (
  set -o pipefail
  shopt -s dotglob nullglob
  url=$1 channel=$2 arch=$3
  work=$(mktemp -d) || exit 1
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/db.d"
  if ! curl -fsSL --retry 3 --max-time 60 -o "$work/db" "$url?$(date +%s%N)" ||
    ! tar --zstd -xf "$work/db" -C "$work/db.d"; then
    echo "::error::Could not read $url" >&2
    exit 1
  fi

  descs=()
  for entry in "$work/db.d"/*; do
    if [[ ! -s $entry/desc ]]; then
      echo "::error::$channel/$arch holds ${entry##*/} without a desc" >&2
      exit 1
    fi
    descs+=("$entry/desc")
  done
  (( ${#descs[@]} )) || exit 0

  awk -v c="$channel" -v a="$arch" '
    function flush() {
      n = split(file, part, "/")
      if (name == "" || base == "" || ver == "") {
        print "::error::" c "/" a " holds " part[n - 1] " without a %NAME%, %BASE% or %VERSION%" > "/dev/stderr"
        bad = 1
      } else {
        print c "\t" a "\t" base "\t" name "\t" ver "\t" built
      }
      name = base = ver = built = ""
    }
    FNR == 1 && NR > 1 { flush() }
    FNR == 1 { file = FILENAME }
    /^%NAME%$/ { getline name }
    /^%BASE%$/ { getline base }
    /^%VERSION%$/ { getline ver }
    /^%BUILDDATE%$/ { getline built }
    END { flush(); exit bad }' "${descs[@]}" | LC_ALL=C sort
)
