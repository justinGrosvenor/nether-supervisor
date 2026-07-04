set -u
# Observability gate: /status + /metrics behind constant-time service-key auth.
# Boots one tenant so the gauges are non-zero, then checks auth + payloads.
NS=~/nether-supervisor/zig-out/bin/nether-supervisor
NETHER_BIN=$HOME/nether/zig-out/bin/nether
WORK=/tmp/nsup
KEY=testkey123
PORT=9190
pkill -f "nether-supervisor" 2>/dev/null; pkill -f "$NETHER_BIN" 2>/dev/null; sleep 0.3
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/nether-supervisor.conf" <<CONF
control_socket = /tmp/nsup/ctl.sock
socket_dir = /tmp/nsup
work_root = /tmp/nsup/vms
kernels_dir = $HOME/nether/kernels
nether_bin = $NETHER_BIN
ram_mb = 512
cpus = 1
app_port = 8080
boot_budget_ms = 40000
status_addr = 127.0.0.1:$PORT
status_service_key = $KEY
CONF
( cd "$WORK" && exec "$NS" >"$WORK/sup.log" 2>&1 ) & SUP=$!
for i in $(seq 1 50); do [ -S "$WORK/ctl.sock" ] && break; sleep 0.1; done
for i in $(seq 1 50); do grep -q "status surface listening" "$WORK/sup.log" && break; sleep 0.1; done

echo "=== boot alpha so gauges are non-zero ==="
python3 - <<'PY'
import socket
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(45);s.connect("/tmp/nsup/ctl.sock")
s.sendall(b"ensure alpha\n")
b=b""
while b"\x1e" not in b:
    d=s.recv(4096)
    if not d: break
    b+=d
print("ensure alpha ->", b.split(b"\x1e")[0].decode())
PY

echo "=== A) /metrics WITHOUT key -> expect 401 ==="
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$PORT/metrics)
echo "no-auth code: $NOAUTH"
echo "=== B) /metrics WITH key -> expect 200 + gauges ==="
MBODY=$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:$PORT/metrics)
MCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:$PORT/metrics)
echo "auth code: $MCODE"; echo "$MBODY" | grep -E "nsup_(vms_warm|ensures_total)"
echo "=== C) /status WITH key -> expect JSON ==="
SBODY=$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:$PORT/status)
echo "status: $SBODY"
echo "=== D) wrong key -> expect 401 ==="
WCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer wrong" http://127.0.0.1:$PORT/metrics)
echo "wrong-key code: $WCODE"

kill -TERM "$SUP" 2>/dev/null; for i in $(seq 1 30); do kill -0 "$SUP" 2>/dev/null || break; sleep 0.1; done; kill -9 "$SUP" 2>/dev/null
pkill -f "$NETHER_BIN" 2>/dev/null

echo "--- verdict ---"
PASS=1
[ "$NOAUTH" = "401" ] || { echo "FAIL: no-auth not 401 ($NOAUTH)"; PASS=0; }
[ "$MCODE" = "200" ] || { echo "FAIL: authed metrics not 200 ($MCODE)"; PASS=0; }
echo "$MBODY" | grep -q "nsup_ensures_total 1" || { echo "FAIL: ensures gauge not 1"; PASS=0; }
echo "$SBODY" | grep -q '"vms_warm":1' || { echo "FAIL: status vms_warm not 1"; PASS=0; }
[ "$WCODE" = "401" ] || { echo "FAIL: wrong-key not 401 ($WCODE)"; PASS=0; }
[ "$PASS" = "1" ] && echo "STATUS GATE: PASS" || echo "STATUS GATE: FAIL"
