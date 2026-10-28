# Reading a channel on the remote. publish-artifact, unpublish-packages and
# promote-channel all decide from a channel's listing whether it has a
# database, so a listing that failed must never read as an empty channel: a
# publish would start a new database holding only its own batch and upload it
# over the real one.
# Source after message-helpers.sh.

# remote_listing <rclone dir>: the names in the directory, one per line. A
# directory that does not exist yet (rclone exit 3) is a valid first publish
# and lists as nothing. Any other failure leaves the remote's state unknown:
# say so and return 1.
remote_listing() {
  local listing status=0
  listing=$(rclone lsf "$1/" --s3-no-head) || status=$?
  case $status in
  0) [[ -z $listing ]] || printf '%s\n' "$listing" ;;
  3) ;;
  *)
    print_error "Cannot read remote repository at $1 (rclone exit $status)" >&2
    return 1
    ;;
  esac
}

# db_entries <file>: how many packages a pulled database holds, 0 when there
# is no file. repo-remove leaves a valid empty database when a channel's last
# package goes, and grep -c exits 1 on it. A database that cannot be read
# still fails, and so does a zero-byte one: bsdtar lists it as empty, but even
# an empty database is a compressed archive with a header.
db_entries() {
  local list
  [[ -f $1 ]] || { echo 0; return; }
  [[ -s $1 ]] || { print_error "The database $1 is zero bytes" >&2; return 1; }
  list=$(bsdtar -tf "$1") || { print_error "Cannot read the database $1" >&2; return 1; }
  grep -c '/$' <<<"$list" || true
}

# pacman reads omarchy.db and omarchy.files. The repo-add archives beside them
# (omarchy.db.tar.zst, omarchy.files.tar.zst) hold the same bytes but are
# separate objects on the remote, so an upload that stopped part way can leave
# the two apart. The tools that write a channel start from the names pacman
# reads, and upload_database <local dir> <remote dir> writes those first and
# the archives after them. A run that stops in between leaves the archives
# behind what is served, never ahead: the release tooling, which reads the
# archives, may wait for a version that is already out but never takes one
# for served that is not. Every run that finds nothing to write calls
# sync_archives, so a retry brings the archives back in step.
upload_database() {
  rclone copy "$1" "$2" --s3-no-head --checksum --copy-links --filter '+ omarchy.db' --filter '+ omarchy.files' --filter '- *'
  rclone copy "$1" "$2" --s3-no-head --checksum --filter '+ omarchy.db.tar.zst*' --filter '+ omarchy.files.tar.zst*' --filter '- *'
}

# sync_archives <remote dir>: copy what pacman is served over the archives
# beside it, on the remote. Objects that already match are skipped, so a
# channel in step writes nothing.
sync_archives() {
  local listing name
  listing=$(remote_listing "$1") || return 1
  for name in omarchy.db omarchy.files; do
    grep -qx "$name" <<<"$listing" || continue
    rclone copyto "$1/$name" "$1/$name.tar.zst" --s3-no-head --checksum || return 1
  done
}
