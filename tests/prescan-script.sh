#!/bin/sh
# Tests for the pre-scan shell script embedded in skipsilence.lua.
#
# The script under test is extracted live from skipsilence.lua instead of
# being duplicated here, so the embedded script cannot silently diverge from
# the tested copy. Fake yt-dlp and ffmpeg executables are placed on a
# temporary PATH and the extracted script is run through sh -c with the same
# argument shape prescan_start uses: sh -c <script> sh <yt-dlp> <ffmpeg>
# <url> <fifo> <log> <filter> <status> [yt-dlp options...]. The cases
# verify the ordering contract between the yt-dlp status file and the fifo
# EOF observed by ffmpeg: the brace group holds the fifo write end until
# the status is final, so when ffmpeg sees EOF the status file already
# holds yt-dlp's exit code.
#
# The later cases pass yt-dlp options after the status path and verify
# argument integrity (options forwarded as separate argv elements, no
# word-splitting) and flag precedence (the script's own trailing options win
# by yt-dlp's last-wins resolution of repeated scalar flags).

set -u

root=$( (unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd) )
self=$0
failures=0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/prescan-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 130' INT
trap 'rm -rf "$tmp"; exit 143' TERM

mkdir "$tmp/bin" || exit 1

cat > "$tmp/bin/yt-dlp" <<'EOF'
#!/bin/sh
# ok writes a payload and exits 0. partial writes a payload, goes quiet for
# a while (the fifo stays open but empty), then exits 7 like a fetch
# rejected mid-stream. midwrite is mid-download when ffmpeg dies: a chunk,
# a pause, then another chunk that hits the closed pipe. record writes its
# full argv, one token per line, to $FAKE_YTDL_ARGV and then behaves like
# ok.
case ${FAKE_YTDL_MODE:-} in
ok)
    printf 'fake audio payload\n'
    exit 0
    ;;
record)
    printf '%s\n' "$@" > "${FAKE_YTDL_ARGV:?}"
    printf 'fake audio payload\n'
    exit 0
    ;;
partial)
    printf 'fake audio payload\n'
    sleep 0.3
    exit 7
    ;;
midwrite)
    printf 'chunk one\n'
    sleep 1
    printf 'chunk two\n'
    sleep 5
    exit 0
    ;;
*)
    exit 9
    ;;
esac
EOF

cat > "$tmp/bin/ffmpeg" <<'EOF'
#!/bin/sh
# consume reads stdin to EOF, then records the yt-dlp status file contents
# observed at that moment; the exit code stays 0 so the ordering assertion
# lives in the observation file. hold signals readiness and then blocks on
# stdin until killed, reading with the read builtin so the fifo read end
# lives in this process alone (an external cat would survive the kill and
# keep the pipe open, unlike a real exec'd ffmpeg). fail exits 3 immediately
# like a broken ffmpeg invocation.
observed_file=${FAKE_OBSERVED:?}
case ${FAKE_FFMPEG_MODE:-} in
hold)
    : > "${FAKE_READY:?}"
    while IFS= read -r line; do :; done
    exit 0
    ;;
fail)
    printf 'no-eof\n' > "$observed_file"
    exit 3
    ;;
esac
cat > /dev/null
status=$(cat "${FAKE_STATUS_FILE:?}" 2>/dev/null) || status=unreadable
[ -n "$status" ] || status=empty
printf '%s\n' "$status" > "$observed_file"
exit 0
EOF

chmod +x "$tmp/bin/yt-dlp" "$tmp/bin/ffmpeg"

sed -n '/^local prescan_script = \[\[$/,/^\]\]$/p' "$root/skipsilence.lua" \
    | sed '1d;$d' > "$tmp/script.sh"
if [ ! -s "$tmp/script.sh" ]; then
    printf 'FAIL extract: prescan_script not found in skipsilence.lua\n'
    exit 1
fi

check() {
    # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        printf 'FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

show_log() {
    # show_log <path>, indented under a preceding FAIL line
    printf '  contents of %s:\n' "$1"
    sed 's/^/  /' "$1"
}

# Case 1: natural success. yt-dlp exits 0; at ffmpeg EOF the status file
# must already read 0.

case_dir=$tmp/case1
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
before=$failures

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=ok FAKE_FFMPEG_MODE=consume \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    'https://example.invalid/audio' "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status"
code=$?

check 'success: overall exit status' 0 "$code"
check 'success: yt-dlp status when ffmpeg sees EOF' 0 \
    "$(cat "$observed" 2>/dev/null)"
check 'success: final status file contents' 0 "$(cat "$status" 2>/dev/null)"
[ "$failures" = "$before" ] || show_log "$log"

# Case 2: partial scan. yt-dlp stops producing data, pauses, then exits 7;
# EOF must wait for the brace group so the status file reads 7 by the time
# ffmpeg sees it.

case_dir=$tmp/case2
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
before=$failures

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=partial FAKE_FFMPEG_MODE=consume \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    'https://example.invalid/audio' "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status"
code=$?

check 'partial: overall exit status' 0 "$code"
check 'partial: yt-dlp status when ffmpeg sees EOF' 7 \
    "$(cat "$observed" 2>/dev/null)"
check 'partial: final status file contents' 7 "$(cat "$status" 2>/dev/null)"
[ "$failures" = "$before" ] || show_log "$log"

# Case 3: ffmpeg failure. The shell execs ffmpeg, so its exit status is the
# overall exit status.

case_dir=$tmp/case3
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
before=$failures

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=ok FAKE_FFMPEG_MODE=fail \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    'https://example.invalid/audio' "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status"
code=$?

check 'ffmpeg-fail: overall exit status' 3 "$code"
[ "$failures" = "$before" ] || show_log "$log"

# Case 4: abort. ffmpeg is killed mid-stream the way mp.abort_async_command
# kills the subprocess (the sh pid, since sh execs ffmpeg). The brace group
# survives the killed ffmpeg; the test unlinks the status file the way
# prescan_stop's cleanup does, and the group's later status write must go
# through its held fd instead of recreating the file by name. The test holds
# its own read fd on the status inode so it can observe that the write
# happened even though the path is gone (the group cannot be waited on
# directly; the settle sleep runs past its remaining yt-dlp pause).

case_dir=$tmp/case4
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
ready=$case_dir/ffmpeg-ready
before=$failures

: > "$status"
exec 9<"$status"

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=midwrite FAKE_FFMPEG_MODE=hold \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" FAKE_READY="$ready" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    'https://example.invalid/audio' "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status" &
pid=$!

i=0
while [ ! -f "$ready" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done

kill -9 "$pid" 2> /dev/null
wait "$pid" 2> /dev/null
rm -f "$status"
sleep 2

orphan=absent
[ -e "$status" ] && orphan=present
check 'abort: no orphan status file' absent "$orphan"

held_status=$(cat <&9)
case $held_status in
''|*[!0-9]*)
    printf 'FAIL abort: status not written to the held fd (got <%s>)\n' \
        "$held_status"
    failures=$((failures + 1))
    ;;
*)
    printf 'PASS abort: status <%s> written to the held fd\n' "$held_status"
    ;;
esac
[ "$failures" = "$before" ] || show_log "$log"

# Case 5: argument integrity. prescan_start appends yt-dlp options after the
# status path, and the script must forward them to yt-dlp as separate argv
# elements without word-splitting. A cookie path containing a space must
# arrive as one token, and a flag/value pair must survive intact.

case_dir=$tmp/case5
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
argv=$case_dir/ytdl-argv
cookies="$case_dir/co okies.txt"
before=$failures

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=record FAKE_FFMPEG_MODE=consume \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" \
    FAKE_YTDL_ARGV="$argv" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    'https://example.invalid/audio' "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status" \
    --cookies-from-browser firefox --cookies "$cookies"
code=$?

check 'integrity: overall exit status' 0 "$code"
check 'integrity: yt-dlp status when ffmpeg sees EOF' 0 \
    "$(cat "$observed" 2>/dev/null)"
check 'integrity: spaced cookie path stays one argv element' 1 \
    "$(grep -cx -e "$cookies" "$argv" 2>/dev/null)"
check 'integrity: --cookies-from-browser value follows the flag' firefox \
    "$(awk '$0 == "--cookies-from-browser" { getline; print; exit }' \
        "$argv" 2>/dev/null)"
[ "$failures" = "$before" ] || show_log "$log"

# Case 6: flag precedence. prescan_start appends inherited and user options
# first and its own -f last, and the script adds its critical options after
# all of them. yt-dlp resolves repeated scalar options last-wins, so the
# recorded argv must carry both -f occurrences with bestaudio/best last, and
# end with the script's own -o -, -- and URL (its -o wins the same way).

case_dir=$tmp/case6
mkdir "$case_dir" || exit 1
fifo=$case_dir/stream.fifo
log=$case_dir/ffmpeg.log
status=$case_dir/ytdl.status
observed=$case_dir/observed-at-eof
argv=$case_dir/ytdl-argv
url='https://example.invalid/audio'
before=$failures

PATH="$tmp/bin:$PATH" FAKE_YTDL_MODE=record FAKE_FFMPEG_MODE=consume \
    FAKE_STATUS_FILE="$status" FAKE_OBSERVED="$observed" \
    FAKE_YTDL_ARGV="$argv" \
    sh -c "$(cat "$tmp/script.sh")" sh yt-dlp ffmpeg \
    "$url" "$fifo" "$log" \
    'silencedetect=noise=-30dB:duration=0.05' "$status" \
    -f custom -o /tmp/x -f bestaudio/best
code=$?

check 'precedence: overall exit status' 0 "$code"
check 'precedence: yt-dlp status when ffmpeg sees EOF' 0 \
    "$(cat "$observed" 2>/dev/null)"
check 'precedence: both -f flags present' 2 \
    "$(grep -cx -e '-f' "$argv" 2>/dev/null)"
last_f=$(awk 'prev == "-f" { value = $0 } { prev = $0 } \
    END { print value }' "$argv" 2>/dev/null)
check 'precedence: last -f value' bestaudio/best "$last_f"
last_o=$(awk 'prev == "-o" { value = $0 } { prev = $0 } \
    END { print value }' "$argv" 2>/dev/null)
check 'precedence: last -o value' - "$last_o"
expected_tail="-o
-
--
$url"
check 'precedence: argv ends with -o - -- URL' "$expected_tail" \
    "$(tail -n 4 "$argv" 2>/dev/null)"
[ "$failures" = "$before" ] || show_log "$log"

if command -v shellcheck > /dev/null 2>&1; then
    if shellcheck --shell=sh "$tmp/script.sh"; then
        printf 'PASS shellcheck: extracted script\n'
    else
        printf 'FAIL shellcheck: extracted script\n'
        failures=$((failures + 1))
    fi
    if shellcheck "$self"; then
        printf 'PASS shellcheck: test file\n'
    else
        printf 'FAIL shellcheck: test file\n'
        failures=$((failures + 1))
    fi
else
    printf 'SKIP shellcheck: not available\n'
fi

if [ "$failures" -gt 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all checks passed\n'
exit 0
