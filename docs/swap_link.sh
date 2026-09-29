set -euo pipefail
umask 022
app_root=$1
new_rel=$2
cur="$app_root/current"
new="$app_root/releases/$new_rel"

[ -d "$new" ] || { echo "no such release: $new" >&2; exit 10; }
[ -f "$new/.shipyard-ready" ] || { echo "release $new_rel not marked ready" >&2; exit 10; }

prev=$(readlink -f "$cur" 2>/dev/null || true)
prev_num=${prev##*/}

tmp="$app_root/.current.$$.tmp"
ln -s "releases/$new_rel" "$tmp"
mv -Tf "$tmp" "$cur"

if [ -n "$prev_num" ] && [ "$prev_num" != "$new_rel" ]; then
  ptmp="$app_root/.previous.$$.tmp"
  ln -s "releases/$prev_num" "$ptmp"
  mv -Tf "$ptmp" "$app_root/previous"
fi
sync -f "$app_root" 2>/dev/null || sync
