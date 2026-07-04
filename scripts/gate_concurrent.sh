set -u
# Async gate: proves the north loop no longer serializes on bring-up.
#   A) DEDUPE      - N concurrent `ensure alpha` (cold) share ONE boot: every
#                    caller gets the same data_socket and the log shows a single
#                    "cold boot vm=".
#   B) PARALLELISM - three distinct cold tenants launched at once finish in about
#                    one boot's wall time, not three (they boot concurrently).
# Cold mode (no base_snap) makes the multi-second boots observable.
NS=~/nether-supervisor/zig-out/bin/nether-supervisor
WORK=/tmp/nsup
pkill -f "nether-supervisor" 2>/dev/null; pkill -f "/tmp/nsup/vms" 2>/dev/null; sleep 0.3
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/nether-supervisor.conf" <<CONF
control_socket = /tmp/nsup/ctl.sock
socket_dir = /tmp/nsup
work_root = /tmp/nsup/vms
kernels_dir = $HOME/nether/kernels
nether_bin = $HOME/nether/zig-out/bin/nether
ram_mb = 512
cpus = 1
app_port = 8080
boot_budget_ms = 40000
CONF

cat > "$WORK/ensure.py" <<'PY'
import socket,sys,time
t=sys.argv[1].encode()
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(45); s.connect("/tmp/nsup/ctl.sock")
t0=time.time(); s.sendall(b"ensure "+t+b"\n")
buf=b""
while b"\x1e" not in buf:
    d=s.recv(4096)
    if not d: break
    buf+=d
print("%d %s"%(int((time.time()-t0)*1000), buf.split(b"\x1e")[0].decode()))
PY

( cd "$WORK" && exec "$NS" >"$WORK/sup.log" 2>&1 ) & SUP=$!
for i in $(seq 1 50); do [ -S "$WORK/ctl.sock" ] && break; sleep 0.1; done
[ -S "$WORK/ctl.sock" ] || { echo "FAIL: north socket never appeared"; tail -20 "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }

echo "=== A) DEDUPE: 4 concurrent 'ensure alpha' ==="
rm -f "$WORK"/a.*.out
PIDS=""
for i in 1 2 3 4; do ( python3 "$WORK/ensure.py" alpha > "$WORK/a.$i.out" 2>&1 ) & PIDS="$PIDS $!"; done
wait $PIDS
A_SOCKS=$(awk '{print $2}' "$WORK"/a.*.out | sort -u)
A_COUNT=$(echo "$A_SOCKS" | grep -c . )
BOOTS=$(grep -c "alpha: cold boot vm=" "$WORK/sup.log")
echo "distinct data_sockets returned: $A_COUNT -> $A_SOCKS"
echo "cold boots logged for alpha: $BOOTS"

echo "=== B) PARALLELISM: baseline single cold boot (tenant s) ==="
read S_MS S_SOCK < <(python3 "$WORK/ensure.py" s)
echo "single cold boot: ${S_MS}ms"

echo "=== B) three distinct tenants at once (p,q,r) ==="
rm -f "$WORK"/b.*.out
T0=$(python3 -c 'import time;print(int(time.time()*1000))')
PIDS=""
for t in p q r; do ( python3 "$WORK/ensure.py" $t > "$WORK/b.$t.out" 2>&1 ) & PIDS="$PIDS $!"; done
wait $PIDS
T1=$(python3 -c 'import time;print(int(time.time()*1000))')
BATCH_MS=$((T1-T0))
B_SOCKS=$(awk '{print $2}' "$WORK"/b.*.out | sort -u | grep -c . )
echo "batch of 3 wall time: ${BATCH_MS}ms (distinct socks: $B_SOCKS)"
echo "=== supervisor log tail ==="; tail -6 "$WORK/sup.log"
kill $SUP 2>/dev/null; pkill -f "/tmp/nsup/vms" 2>/dev/null

echo "--- verdict ---"
PASS=1
[ "$A_COUNT" = "1" ] && [ "$BOOTS" = "1" ] || { echo "DEDUPE FAIL (sockets=$A_COUNT boots=$BOOTS, want 1/1)"; PASS=0; }
[ "$B_SOCKS" = "3" ] || { echo "PARALLEL FAIL (distinct socks=$B_SOCKS, want 3)"; PASS=0; }
# Overlap proof: 3 concurrent boots finish in well under 3x a single boot.
if [ "$BATCH_MS" -lt $((S_MS * 2)) ]; then echo "OVERLAP OK: 3-batch ${BATCH_MS}ms < 2x single ${S_MS}ms"; else echo "OVERLAP FAIL: 3-batch ${BATCH_MS}ms not < 2x single ${S_MS}ms (serialized?)"; PASS=0; fi
[ "$PASS" = "1" ] && echo "ASYNC GATE: PASS" || echo "ASYNC GATE: FAIL"
