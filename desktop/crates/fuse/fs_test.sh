#!/bin/bash
# FUSE integration test. Runs inside the Linux VM. Needs SKYFOLDER_TOKEN / SKYFOLDER_SERVER.
set -u
B=$HOME/target-sky/debug/skyfolder-cli
M=$HOME/Skyfolder
T="_skyfolder fuse test"
export SKYFOLDER_CONFIG_DIR=$HOME/.sky-test-cfg SKYFOLDER_CACHE_DIR=$HOME/.sky-test-cache
pass=0; fail=0
ok(){ if [ "$1" = 0 ]; then echo "PASS $2"; pass=$((pass+1)); else echo "FAIL $2 ${3:-}"; fail=$((fail+1)); fi; }
$B rmtree "$T" >/dev/null 2>&1
$B mount "$M" > /tmp/mount.log 2>&1 &
MP=$!
for i in $(seq 1 30); do mountpoint -q "$M" && break; sleep 0.5; done
mountpoint -q "$M"; ok $? "mounted"
SERVER_ROOT=$($B ls | cut -f1 | sed 's|/$||' | sort)
LOCAL_ROOT=$(ls -A "$M" | sort)
[ "$SERVER_ROOT" = "$LOCAL_ROOT" ]; ok $? "root listing matches server" "$(diff <(echo "$SERVER_ROOT") <(echo "$LOCAL_ROOT") | head -3)"
mkdir "$M/$T"; ok $? "mkdir"
$B ls | grep -q "^$T/"; ok $? "mkdir visible on server"
echo "hello from linux" > "$M/$T/note.txt"; ok $? "create+write"
sleep 2
[ "$($B cat "$T/note.txt")" = "hello from linux" ]; ok $? "uploaded content on server"
[ "$(cat "$M/$T/note.txt")" = "hello from linux" ]; ok $? "read back"
echo "line 2" >> "$M/$T/note.txt"; sleep 2
[ "$($B cat "$T/note.txt")" = "$(printf 'hello from linux\nline 2')" ]; ok $? "append uploaded"
[ "$(stat -c %s "$M/$T/note.txt")" = "24" ]; ok $? "size after append" "$(stat -c %s "$M/$T/note.txt")"
ID1=$($B ls "$T" | grep '^note.txt' | cut -f3)
# Safe-save: write temp, rename over original (gedit/LibreOffice pattern)
printf 'safe saved' > "$M/$T/.goutputstream-ABC123"; mv "$M/$T/.goutputstream-ABC123" "$M/$T/note.txt"; sleep 2
[ "$($B cat "$T/note.txt")" = "safe saved" ]; ok $? "safe-save replaces content"
[ "$($B ls "$T" | grep -c goutputstream)" = "0" ]; ok $? "temp file never uploaded"
# Lock files stay local
touch "$M/$T/.~lock.note.txt#"; sleep 1
[ "$($B ls "$T" | grep -c '~lock')" = "0" ]; ok $? "lock file not uploaded"
ls -A "$M/$T" | grep -q '~lock'; ok $? "lock file visible locally"
rm "$M/$T/.~lock.note.txt#"; ok $? "lock file removable"
mv "$M/$T/note.txt" "$M/$T/renamed.txt"; ok $? "rename"
$B ls "$T" | grep -q '^renamed.txt'; ok $? "rename on server"
mkdir "$M/$T/sub" && mv "$M/$T/renamed.txt" "$M/$T/sub/"; ok $? "move into subfolder"
$B ls "$T/sub" | grep -q '^renamed.txt'; ok $? "move on server"
cp "$M/$T/sub/renamed.txt" "$M/$T/copy.txt"; sleep 2
[ "$($B cat "$T/copy.txt")" = "safe saved" ]; ok $? "cp creates server copy"
dd if=/dev/urandom of=/tmp/big.bin bs=1M count=12 status=none
cp /tmp/big.bin "$M/$T/big.bin"; sleep 4
[ "$($B ls "$T" | grep '^big.bin' | cut -f2)" = "12582912" ]; ok $? "12 MB upload size on server"
find "$HOME/.sky-test-cache/files" -type f ! -name 'index.json' -delete   # force a fresh download
cmp -s /tmp/big.bin "$M/$T/big.bin"; ok $? "12 MB downloaded on demand, identical"
[ "$(find "$HOME/.sky-test-cache/files" -type f -size +10M | wc -l)" = "1" ]; ok $? "downloaded file is cached"
: > "$M/$T/copy.txt"; sleep 2
[ "$($B ls "$T" | grep '^copy.txt' | cut -f2)" = "0" ]; ok $? "truncate uploads empty file"
rmdir "$M/$T/sub" 2>/dev/null; [ $? != 0 ]; ok $? "rmdir non-empty refused"
rm "$M/$T/sub/renamed.txt" && rmdir "$M/$T/sub"; ok $? "rm + rmdir"
! $B ls "$T" | grep -q '^sub/'; ok $? "deleted on server"
df -h "$M" | tail -1 | grep -q skyfolder; ok $? "statfs/df works"
fusermount3 -u "$M"; kill $MP 2>/dev/null; wait $MP 2>/dev/null
$B rmtree "$T" >/dev/null
echo "== $pass passed, $fail failed"
grep -iE "error|panic" /tmp/mount.log | head -5
