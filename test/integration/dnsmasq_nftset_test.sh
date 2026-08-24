#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != "--isolated" ]]; then
  user_name=$(id -un)
  subuid_start=
  subuid_count=
  subgid_start=
  subgid_count=
  while IFS=: read -r name start count; do
    if [[ $name == "$user_name" ]]; then
      subuid_start=$start
      subuid_count=$count
      break
    fi
  done </etc/subuid
  while IFS=: read -r name start count; do
    if [[ $name == "$user_name" ]]; then
      subgid_start=$start
      subgid_count=$count
      break
    fi
  done </etc/subgid
  if [[ -z $subuid_start || -z $subgid_start || $subuid_count -lt 65535 || $subgid_count -lt 65535 ]]; then
    echo "this test requires at least 65535 subordinate UIDs and GIDs for $user_name" >&2
    exit 1
  fi

  exec unshare \
    --map-users="0:$(id -u):1" \
    --map-users="1:$subuid_start:65535" \
    --map-groups="0:$(id -g):1" \
    --map-groups="1:$subgid_start:65535" \
    --setuid 0 \
    --setgid 0 \
    --keep-caps \
    --net \
    -- "$0" --isolated
fi

for command in dnsmasq nft ip dig; do
  command -v "$command" >/dev/null || {
    echo "missing $command; run this test from nix develop" >&2
    exit 1
  }
done

tmp_dir=$(mktemp -d -t devbox-dnsmasq-test.XXXXXX)
upstream_pid=
proxy_pid=

cleanup() {
  local status=$?
  [[ -z $proxy_pid ]] || kill "$proxy_pid" 2>/dev/null || true
  [[ -z $upstream_pid ]] || kill "$upstream_pid" 2>/dev/null || true
  wait "$proxy_pid" 2>/dev/null || true
  wait "$upstream_pid" 2>/dev/null || true
  if ((status != 0)); then
    for log in "$tmp_dir"/*.log; do
      [[ -f $log ]] || continue
      echo "--- $log" >&2
      sed -n '1,160p' "$log" >&2
    done
  fi
  rm -rf -- "$tmp_dir"
  return "$status"
}
trap cleanup EXIT INT TERM

wait_for_dns() {
  local address=$1
  local port=$2
  local name=$3

  for _attempt in {1..50}; do
    if dig +time=1 +tries=1 +short "@$address" -p "$port" "$name" A >/dev/null 2>&1; then
      return
    fi
    sleep 0.05
  done

  echo "dnsmasq did not become ready on $address:$port" >&2
  exit 1
}

set_contains() {
  local set_name=$1
  local address=$2
  nft list set inet devbox_dnsmasq_test "$set_name" | grep -Eq "(^|[[:space:],])$address([[:space:],}]|$)"
}

assert_in_set() {
  local set_name=$1
  local address=$2
  for _attempt in {1..50}; do
    if set_contains "$set_name" "$address"; then
      return
    fi
    sleep 0.02
  done

  echo "expected $address in $set_name" >&2
  nft list set inet devbox_dnsmasq_test "$set_name" >&2
  exit 1
}

assert_not_in_set() {
  local set_name=$1
  local address=$2
  if set_contains "$set_name" "$address"; then
    echo "did not expect $address in $set_name" >&2
    nft list set inet devbox_dnsmasq_test "$set_name" >&2
    exit 1
  fi
}

ip link set lo up

nft add table inet devbox_dnsmasq_test
nft "add set inet devbox_dnsmasq_test observed { type ipv4_addr; flags timeout; timeout 5s; }"
nft "add set inet devbox_dnsmasq_test removed_policy { type ipv4_addr; flags timeout; timeout 30s; }"

dnsmasq \
  --keep-in-foreground \
  --pid-file="$tmp_dir/upstream.pid" \
  --log-facility=- \
  --no-hosts \
  --no-resolv \
  --bind-interfaces \
  --listen-address=127.0.0.2 \
  --port=5300 \
  --local-ttl=2 \
  --host-record=direct.allowed.test,192.0.2.10 \
  --host-record=target.allowed.test,192.0.2.20 \
  --cname=alias.allowed.test,target.allowed.test \
  --host-record=target.external.test,192.0.2.30 \
  --cname=escape.allowed.test,target.external.test \
  --host-record=private.external.test,10.0.0.10 \
  --cname=private.allowed.test,private.external.test \
  --host-record=multi.allowed.test,192.0.2.40 \
  --host-record=multi.allowed.test,192.0.2.41 \
  --host-record=cached.allowed.test,192.0.2.50,20 \
  --host-record=refreshed.allowed.test,192.0.2.60,2 \
  >"$tmp_dir/upstream.log" 2>&1 &
upstream_pid=$!
wait_for_dns 127.0.0.2 5300 direct.allowed.test

dnsmasq \
  --keep-in-foreground \
  --pid-file="$tmp_dir/proxy.pid" \
  --log-facility=- \
  --no-hosts \
  --no-resolv \
  --bind-interfaces \
  --listen-address=127.0.0.1 \
  --port=5353 \
  --server=127.0.0.2#5300 \
  --nftset=/allowed.test/4#inet#devbox_dnsmasq_test#observed,4#inet#devbox_dnsmasq_test#removed_policy \
  >"$tmp_dir/proxy.log" 2>&1 &
proxy_pid=$!
wait_for_dns 127.0.0.1 5353 direct.allowed.test

dig +short @127.0.0.1 -p 5353 direct.allowed.test A >/dev/null
assert_in_set observed 192.0.2.10

dig +short @127.0.0.1 -p 5353 alias.allowed.test A >/dev/null
assert_in_set observed 192.0.2.20

dig +short @127.0.0.1 -p 5353 escape.allowed.test A >/dev/null
assert_in_set observed 192.0.2.30

# dnsmasq follows the allowed query's CNAME and adds even a private target.
# The production nft topology must apply the private-range deny independently.
dig +short @127.0.0.1 -p 5353 private.allowed.test A >/dev/null
assert_in_set observed 10.0.0.10

dig +short @127.0.0.1 -p 5353 multi.allowed.test A >/dev/null
assert_in_set observed 192.0.2.40
assert_in_set observed 192.0.2.41

dig +short @127.0.0.1 -p 5353 missing.allowed.test A >/dev/null
dig +short @127.0.0.1 -p 5353 refreshed.allowed.test A >/dev/null
assert_in_set observed 192.0.2.60

sleep 3
# dnsmasq 2.93 does not copy the two-second DNS TTL into nftables. The elements
# use the set's five-second default timeout and therefore still exist here.
assert_in_set observed 192.0.2.10
assert_in_set observed 192.0.2.20
assert_in_set observed 192.0.2.30
assert_in_set observed 10.0.0.10
assert_in_set observed 192.0.2.40
assert_in_set observed 192.0.2.41
assert_in_set observed 192.0.2.60

# Even a new upstream answer does not refresh an already-present nft element.
dig +short @127.0.0.1 -p 5353 refreshed.allowed.test A >/dev/null

sleep 3
assert_not_in_set observed 192.0.2.10
assert_not_in_set observed 192.0.2.20
assert_not_in_set observed 192.0.2.30
assert_not_in_set observed 10.0.0.10
assert_not_in_set observed 192.0.2.40
assert_not_in_set observed 192.0.2.41
assert_not_in_set observed 192.0.2.60

# A reply served from dnsmasq's cache does not refresh an existing nft element.
# The nft timeout can therefore expire while dnsmasq still has a valid answer.
dig +short @127.0.0.1 -p 5353 cached.allowed.test A >/dev/null
assert_in_set observed 192.0.2.50
sleep 3
dig +short @127.0.0.1 -p 5353 cached.allowed.test A >/dev/null
sleep 3
assert_not_in_set observed 192.0.2.50

kill "$proxy_pid"
wait "$proxy_pid" || true
proxy_pid=

nft flush set inet devbox_dnsmasq_test observed
nft flush set inet devbox_dnsmasq_test removed_policy

# The safe contract disables the dnsmasq cache and returns a one-second TTL to clients.
# An expired bounded nft element is then restored by the next DNS lookup.
dnsmasq \
  --keep-in-foreground \
  --pid-file="$tmp_dir/proxy.pid" \
  --log-facility=- \
  --no-hosts \
  --no-resolv \
  --cache-size=0 \
  --max-ttl=1 \
  --bind-interfaces \
  --listen-address=127.0.0.1 \
  --port=5353 \
  --server=127.0.0.2#5300 \
  --nftset=/allowed.test/4#inet#devbox_dnsmasq_test#observed,4#inet#devbox_dnsmasq_test#removed_policy \
  >"$tmp_dir/proxy-safe-policy.log" 2>&1 &
proxy_pid=$!
wait_for_dns 127.0.0.1 5353 direct.allowed.test

ttl=$(dig +noall +answer @127.0.0.1 -p 5353 direct.allowed.test A | awk '$4 == "A" { print $2; exit }')
[[ $ttl == 1 ]] || {
  echo "expected the client-facing DNS TTL to be one second, got ${ttl:-no answer}" >&2
  exit 1
}
assert_in_set observed 192.0.2.10
assert_in_set removed_policy 192.0.2.10
sleep 6
assert_not_in_set observed 192.0.2.10
dig +short @127.0.0.1 -p 5353 direct.allowed.test A >/dev/null
assert_in_set observed 192.0.2.10

kill "$proxy_pid"
wait "$proxy_pid" || true
proxy_pid=

dnsmasq \
  --keep-in-foreground \
  --pid-file="$tmp_dir/proxy.pid" \
  --log-facility=- \
  --no-hosts \
  --no-resolv \
  --bind-interfaces \
  --listen-address=127.0.0.1 \
  --port=5353 \
  --server=127.0.0.2#5300 \
  >"$tmp_dir/proxy-without-policy.log" 2>&1 &
proxy_pid=$!
wait_for_dns 127.0.0.1 5353 direct.allowed.test

assert_in_set removed_policy 192.0.2.10
# Removing an nftset rule or restarting dnsmasq does not remove existing
# elements. Policy tightening must explicitly flush or replace the old set.
nft flush set inet devbox_dnsmasq_test removed_policy
assert_not_in_set removed_policy 192.0.2.10

echo "dnsmasq nftset integration test passed"
