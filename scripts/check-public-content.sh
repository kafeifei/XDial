#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

# Keep the deny-list assembled at runtime so this guard does not contain the
# strings it is responsible for rejecting. Vendored upstream source is
# intentionally excluded and remains byte-for-byte reproducible.
policy_term='g''fw'
policy_list="${policy_term}"'list'
policy_geo='geosite-'"${policy_term}"
community_source='lyc''8503'
public_geo_source='raw\.githubusercontent\.com/'"Sager"'Net/'"sing"'-geoip'
enterprise_domain='xin''dong''\.com'
enterprise_address='139''\.196\.60\.210'
restricted_phrase=$'\u88ab\u5899'
misleading_phrase=$'\u5899\u7ed9'
ambiguous_phrase=$'\u6c61\u67d3'

forbidden_regex="${policy_term}|${policy_list}|${policy_geo}|${community_source}|${public_geo_source}|${enterprise_domain}|${enterprise_address}|${restricted_phrase}|${misleading_phrase}|${ambiguous_phrase}"

set +e
matched_files="$(
  git grep -I -l -i -E -e "$forbidden_regex" -- . ':(exclude)third_party/**'
)"
grep_status=$?
set -e

if (( grep_status > 1 )); then
  echo "public-content gate could not scan tracked files" >&2
  exit "$grep_status"
fi
if [[ -n "$matched_files" ]]; then
  echo "public-content gate rejected tracked content in:" >&2
  printf '%s\n' "$matched_files" >&2
  exit 1
fi

set +e
private_paths="$(git ls-files | LC_ALL=C grep -i -E '(^|/)PrivateConfig(/|$)')"
private_status=$?
set -e

if (( private_status > 1 )); then
  echo "public-content gate could not inspect tracked paths" >&2
  exit "$private_status"
fi
if [[ -n "$private_paths" ]]; then
  echo "public-content gate rejected tracked private configuration" >&2
  exit 1
fi

echo "public-content gate passed"
