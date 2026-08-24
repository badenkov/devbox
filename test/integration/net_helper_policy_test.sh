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

for command in ruby nft dnsmasq ip; do
  command -v "$command" >/dev/null || {
    echo "missing $command; run this test from nix develop" >&2
    exit 1
  }
done

export DEVBOX_TEST_NFT=$(command -v nft)
export DEVBOX_TEST_DNSMASQ=$(command -v dnsmasq)
export DEVBOX_TEST_IP=$(command -v ip)
exec ruby -Ilib test/integration/net_helper_policy_test.rb
