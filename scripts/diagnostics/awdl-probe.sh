#!/bin/bash
# Physical-device diagnostic only. Requires the signed DEBUG iPhone build.
# Keeps the screen awake for this bounded probe; returns to normal on next launch.
set -euo pipefail
if [[ $# -ne 4 || ! "$2" =~ ^(idle|traffic)$ || ! "$3" =~ ^(scoped|unscoped)$ ]]; then
    echo 'Usage: awdl-probe.sh DEVICE_UDID idle|traffic scoped|unscoped OUTPUT_JSON' >&2
    exit 2
fi
probe_device="$1"; probe_mode="$2"; probe_scope="$3"; probe_output="$4"
probe_env='{"COMPANION_DIAGNOSTIC_AWDL_ONLY":"1","COMPANION_DIAGNOSTIC_TRAFFIC":"'
[[ "$probe_mode" == traffic ]] && probe_env+='1' || probe_env+='0'
probe_env+='","COMPANION_DIAGNOSTIC_UNSCOPED":"'
[[ "$probe_scope" == unscoped ]] && probe_env+='1' || probe_env+='0'
probe_run=$(python3 -c 'import uuid; print(uuid.uuid4())')
probe_env+='","COMPANION_DIAGNOSTIC_RUN":"'"$probe_run"'","COMPANION_DIAGNOSTIC_DROP_DISCOVERY":"'
[[ "${COMPANION_PROBE_DROP_DISCOVERY:-0}" == 1 ]] && probe_env+='1' || probe_env+='0'
probe_env+='"}'
xcrun devicectl device process launch --device "$probe_device" --terminate-existing \
    --environment-variables "$probe_env" com.quenda.companion.ios --timeout 10
for ((probe_attempt=0; probe_attempt<32; probe_attempt++)); do
    sleep 5
    if ! xcrun devicectl device copy from --device "$probe_device" \
        --domain-type appDataContainer --domain-identifier com.quenda.companion.ios \
        --source Library/Caches/Companion/connection-diagnostics.json \
        --destination "$probe_output" --timeout 5 >/dev/null 2>&1; then
        xcrun devicectl device info details --device "$probe_device" --timeout 5 >/dev/null 2>&1 || true
        continue
    fi
    probe_verdict=$(python3 - "$probe_output" "$probe_run" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
starts = [i for i, e in enumerate(entries) if e['stage'] == 'debug.awdl.start' and ('run=' + sys.argv[2]) in e['detail']]
if not starts: sys.exit(0)
entries = entries[starts[-1]:]
terminal = next((e for e in entries if e['stage'] in {'debug.awdl.result', 'debug.awdl.interrupted'}), None)
if terminal:
    if terminal['stage'] == 'debug.awdl.interrupted':
        print('INCONCLUSIVE: app entered background')
    else:
        ready = [e['detail'] for e in entries if e['stage'] == 'transport.ready']
        print(terminal['detail'] if ready and all(set(x.split(',')) == {'awdl0'} for x in ready) else 'FAIL no verified AWDL connection; ' + terminal['detail'])
PY
)
    if [[ -n "$probe_verdict" ]]; then
        echo "$probe_verdict"
        [[ "$probe_verdict" == PASS* ]] && exit 0
        [[ "$probe_verdict" == INCONCLUSIVE* ]] && exit 3
        exit 1
    fi
done
echo 'INCONCLUSIVE: no completed probe; inspect device state and saved diagnostics.' >&2
exit 3
