#!/usr/bin/env bash
# Tests for bin/ferries-run (the output cap between providers and Quickshell's
# unbounded StdioCollector), bin/ferries-fetch (provider dispatch) and
# bin/ferries-camera (host allow-list).

here=$(cd "$(dirname "$0")/.." && pwd)
run="$here/bin/ferries-run"
fetch="$here/bin/ferries-fetch"
camera="$here/bin/ferries-camera"
keyfile="$here/bin/ferries-keyfile"
fail=0

eq() { # label got want
  if [ "$2" = "$3" ]; then echo "ok   $1 = $2"
  else echo "FAIL $1"; echo "  got  $2"; echo "  want $3"; fail=$((fail + 1)); fi
}

small=$(bash "$run" bash -c 'printf "{\"schema\":1}\n"')
eq 'passes small output through' "$small" '{"schema":1}'

out=$(bash "$run" bash -c 'yes AAAAAAAA | head -c 900000' | wc -c)
eq 'caps stdout' "$out" 262144
err=$(bash "$run" bash -c 'yes BBBBBBBB | head -c 900000 >&2' 2>&1 >/dev/null | wc -c)
eq 'caps stderr' "$err" 262144
both=$(bash "$run" bash -c 'yes A | head -c 900000; yes B | head -c 900000 >&2' 2>/dev/null | wc -c)
eq 'stderr flood does not shrink stdout' "$both" 262144
eq 'limit is overridable' "$(FERRIES_MAX_BYTES=100 bash "$run" bash -c 'yes | head -c 5000' | wc -c)" 100

bash "$run" true; eq 'exit 0 survives' "$?" 0
bash "$run" bash -c 'exit 3'; eq 'exit 3 survives' "$?" 3
bash "$run" definitely-not-a-real-binary 2>/dev/null; eq 'exit 127 survives' "$?" 127
bash "$run" bash -c 'yes | head -c 900000' >/dev/null 2>&1
eq 'truncated call is non-zero' "$([ $? -ne 0 ] && echo yes || echo no)" yes
bash "$run" >/dev/null 2>&1; eq 'no command is a usage error' "$?" 2

# Dispatcher: a provider id is a directory name and nothing more.
bad=$(bash "$fetch" --provider '../../etc' --route x 2>/dev/null)
eq 'rejects a path as a provider id' "$bad" '{"schema":1,"ok":false,"error":"invalid provider id"}'
missing=$(bash "$fetch" --provider nope --route x 2>/dev/null)
eq 'reports a missing provider' "$missing" '{"schema":1,"ok":false,"provider":"nope","error":"no such provider: nope"}'
tmp=$(mktemp -d)
keyless=$(HOME="$tmp" XDG_CONFIG_HOME="$tmp" WSDOT_ACCESS_CODE= bash "$fetch" --provider wsdot --route 'BBI - P52' --no-network --cache-dir "$tmp" | head -c 60)
eq 'dispatches to wsdot' "${keyless:0:32}" '{"schema":1,"provider":"wsdot","'

# Camera downloader: only the operators' image hosts, only https, and never
# a destination it did not create itself.
"$camera" 'https://evil.example/x.jpg' "$tmp/x.jpg" 2>/dev/null; eq 'camera refuses unknown host' "$?" 3
"$camera" 'https://images.wsdot.wa.gov.evil.example/x.jpg' "$tmp/x.jpg" 2>/dev/null; eq 'camera refuses a lookalike host' "$?" 3
"$camera" 'http://images.wsdot.wa.gov/x.jpg' "$tmp/x.jpg" 2>/dev/null; eq 'camera refuses plain http' "$?" 3
"$camera" 2>/dev/null; eq 'camera without args is a usage error' "$?" 2
ln -s /etc/hostname "$tmp/link.jpg"
"$camera" 'https://images.wsdot.wa.gov/wsf/Bainbridge/Bainbridge.jpg' "$tmp/link.jpg" 2>/dev/null
eq 'camera refuses to replace a symlink' "$([ -L "$tmp/link.jpg" ] && echo still-a-link)" still-a-link
mkdir -p "$tmp/shared" && chmod 777 "$tmp/shared"
symdir=$(mktemp -d) && ln -s "$symdir" "$tmp/linkdir"
"$camera" 'https://images.wsdot.wa.gov/wsf/Bainbridge/Bainbridge.jpg' "$tmp/linkdir/cam.jpg" 2>/dev/null; eq 'camera refuses a symlinked directory' "$?" 1
rm -rf "$symdir"

# Key file writer: the code arrives on stdin, never argv, and lands 0600.
keyhome=$(mktemp -d)
saved=$(printf 'abc-123\n' | XDG_CONFIG_HOME="$keyhome" "$keyfile")
eq 'keyfile writes the key file' "$saved" "$keyhome/omarchy-ferries/wsdot-access-code"
eq 'keyfile content' "$(cat "$keyhome/omarchy-ferries/wsdot-access-code")" abc-123
eq 'keyfile mode' "$(stat -c %a "$keyhome/omarchy-ferries/wsdot-access-code")" 600
eq 'keyfile dir mode' "$(stat -c %a "$keyhome/omarchy-ferries")" 700
printf 'has space\n' | XDG_CONFIG_HOME="$keyhome" "$keyfile" >/dev/null 2>&1; eq 'keyfile rejects whitespace' "$?" 2
printf '' | XDG_CONFIG_HOME="$keyhome" "$keyfile" >/dev/null 2>&1; eq 'keyfile rejects empty input' "$?" 2
rm -f "$keyhome/omarchy-ferries/wsdot-access-code"; ln -s /etc/hostname "$keyhome/omarchy-ferries/wsdot-access-code"
printf 'abc\n' | XDG_CONFIG_HOME="$keyhome" "$keyfile" >/dev/null 2>&1; eq 'keyfile refuses to replace a symlink' "$?" 1
rm -rf "$keyhome"

# The provider reads the code from stdin when told to, and never from argv.
stdinkey=$(printf 'from-stdin\n' | HOME="$tmp" XDG_CONFIG_HOME="$tmp" WSDOT_ACCESS_CODE= python3 -c '
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
p = sys.argv[1]
spec = importlib.util.spec_from_file_location("f", p, loader=importlib.machinery.SourceFileLoader("f", p))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.find_key("", True))' "$here/providers/wsdot/fetch")
eq 'provider takes the key from stdin' "$stdinkey" from-stdin
rm -rf "$tmp"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "$fail FAILED"; exit 1; fi
