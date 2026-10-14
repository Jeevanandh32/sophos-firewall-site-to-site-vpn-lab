#!/usr/bin/env bash
# Run on a lab client: bash client-tests.sh a   (or b)
# Prints PASS/FAIL for each policy check and saves a copy of the output.
set -u

SITE="${1:?usage: client-tests.sh a|b}"
case "$SITE" in
  a) FW_LAN_NET=10.10.0.0/24; PEER=10.20.0.50 ;;
  b) FW_LAN_NET=10.20.0.0/24; PEER=10.10.0.50 ;;
  *) echo "site must be a or b"; exit 2 ;;
esac

OUT="results-site-$SITE-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

pass=0; fail=0
check() { # check "<description>" <expect: ok|blocked> <command...>
  local desc="$1" expect="$2"; shift 2
  if timeout 15 "$@" >/dev/null 2>&1; then got=ok; else got=blocked; fi
  if [[ "$got" == "$expect" ]]; then
    printf 'PASS  %-55s (expected %s)\n' "$desc" "$expect"; ((pass++))
  else
    printf 'FAIL  %-55s (expected %s, got %s)\n' "$desc" "$expect" "$got"; ((fail++))
  fi
}

echo "== client-site-$SITE  $(date -u)  LAN $FW_LAN_NET"
ip -4 -br addr; ip route | head -3; echo

# Rule 1: LAN -> WAN allowed for web, with NAT (masquerade) to the firewall's public IP
check "HTTPS to internet (LAN->WAN allow + NAT)"        ok      curl -sS -o /dev/null https://www.example.com
check "DNS resolution"                                  ok      getent hosts www.amazon.com
echo "      public source IP seen by internet: $(curl -s --max-time 10 https://checkip.amazonaws.com || echo n/a)"

# Rule 2: deny ICMP to the internet
check "ICMP ping to 1.1.1.1 (deny rule)"                blocked ping -c 2 -W 3 1.1.1.1

# Web filtering: Sophos answers a blocked HTTPS site with its own block page/certificate,
# which curl rejects, so a blocked category shows up as a failed request.
check "Social-networking site (web filter block)"       blocked curl -sf --max-time 10 -o /dev/null https://www.facebook.com
check "Allowed category site still works"               ok      curl -sf --max-time 10 -o /dev/null https://www.wikipedia.org

# Site-to-site IPsec: reach the other site's client by private IP
check "Ping remote site client $PEER over IPsec"        ok      ping -c 3 -W 3 "$PEER"
check "TCP 22 to remote site client $PEER over IPsec"   ok      bash -c "exec 3<>/dev/tcp/$PEER/22"

echo; echo "Result: $pass passed, $fail failed  (saved to $OUT)"
