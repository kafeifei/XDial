#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
contract="$root/scripts/release-contract.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/xdial-next-release-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export XDIAL_RELEASE_CHANNEL=next
reject() { if "$@" >/dev/null 2>&1; then echo "unexpected acceptance: $*" >&2; exit 1; fi; }
"$contract" validate-inputs next-v0.9.0 1790000000
reject "$contract" validate-inputs v0.9.0 1790000000
reject "$contract" validate-inputs next-v00.9.0 1790000000
reject "$contract" validate-inputs next-v0.9.0 0
reject env XDIAL_RELEASE_CHANNEL=stable "$contract" validate-inputs next-v0.9.0 1
"$contract" validate-notes next-v0.9.0 "$root/NEXT_RELEASE_NOTES.md"
reject "$contract" validate-notes next-v0.9.0 "$root/RELEASE_NOTES.md"
(
    cd "$fixture"
    git init -q -b xdial-next
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' source >source.txt
    git add source.txt
    git commit -qm fixture
    git tag next-v0.9.0
    git update-ref refs/remotes/origin/main HEAD
    reject "$contract" assert-git-tag next-v0.9.0
    git update-ref refs/remotes/origin/xdial-next HEAD
    "$contract" assert-git-tag next-v0.9.0
    printf '%s\n' dirty >>source.txt
    reject "$contract" assert-git-tag next-v0.9.0
    git restore source.txt
    printf '%s\n' later >>source.txt
    git commit -qam later
    git update-ref refs/remotes/origin/xdial-next HEAD
    git checkout -q --detach next-v0.9.0
    reject "$contract" assert-git-tag next-v0.9.0
)
mkdir -p "$fixture/XDial Next.app/Contents"
printf '%s\n' fixture >"$fixture/XDial Next.app/Contents/payload"
"$contract" archive "$fixture/XDial Next.app" next-v0.9.0 "$fixture/output" >/dev/null
archive="$fixture/output/XDial-Next-next-v0.9.0.zip"
"$contract" verify-archive-shape "$archive"
"$contract" verify-checksum "$archive" "$archive.sha256"
reject env XDIAL_RELEASE_CHANNEL=stable "$contract" verify-archive-shape "$archive"
echo 'Next release branch, tag and archive isolation verified'
