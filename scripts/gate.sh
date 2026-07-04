set -u
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
echo "=== booting supervisor (cwd=$WORK) ==="
( cd "$WORK" && exec "$NS" >"$WORK/sup.log" 2>&1 ) &
SUP=$!
# wait for north socket
for i in $(seq 1 50); do [ -S "$WORK/ctl.sock" ] && break; sleep 0.1; done
[ -S "$WORK/ctl.sock" ] || { echo "FAIL: north socket never appeared"; cat "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }
echo "=== north up; sending 'ensure alpha' (cold boot, up to 40s) ==="
DATASOCK=$(python3 - <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(45); s.connect("/tmp/nsup/ctl.sock")
s.sendall(b"ensure alpha\n")
buf=b""
while b"\x1e" not in buf:
    d=s.recv(4096)
    if not d: break
    buf+=d
print(buf.split(b"\x1e")[0].decode())
PY
)
echo "supervisor replied data_socket = '$DATASOCK'"
[ -n "$DATASOCK" ] && [ -S "$DATASOCK" ] || { echo "FAIL: no/invalid data_socket"; tail -20 "$WORK/sup.log"; kill $SUP 2>/dev/null; exit 1; }
echo "=== curling the data_socket over the real VM bridge ==="
BODY=$(curl -s --max-time 10 --unix-socket "$DATASOCK" http://localhost/ )
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$DATASOCK" http://localhost/ )
echo "HTTP $CODE  body: '$BODY'"
echo "=== supervisor log tail ==="; tail -8 "$WORK/sup.log"
kill $SUP 2>/dev/null; pkill -f "/tmp/nsup/vms" 2>/dev/null
case "$CODE:$BODY" in
  200:IID=*) echo "GATE: PASS";;
  *) echo "GATE: FAIL";;
esac
