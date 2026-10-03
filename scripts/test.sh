#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_python="$(conda run -n kora python -c 'import sys; print(sys.executable)')"
fixture_port="$($fixture_python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
"$fixture_python" Tests/Fixtures/gateway.py --port "$fixture_port" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
export QUENDA_FIXTURE_URL="http://127.0.0.1:$fixture_port"
"$fixture_python" - <<'PY'
import os, time, urllib.request
for i in range(50):
    try:
        urllib.request.urlopen(os.environ['QUENDA_FIXTURE_URL']+'/api/health',timeout=.2)
        break
    except OSError: time.sleep(.1)
else: raise SystemExit('Fixture did not start')
PY
swift test "$@"
