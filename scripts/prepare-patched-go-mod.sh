#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
output_dir="${repo_root}/build/patched-go"
staging_dir=""
input_manifest_name="inputs.manifest"

module_path="github.com/sagernet/tailscale"
expected_version="v1.92.4-sing-box-1.13-mod.7.0.20260717155615-b353b93d194a"
patch_dir="${repo_root}/patches/tailscale"
sing_box_module_path="github.com/sagernet/sing-box"
sing_box_expected_version="v1.14.0-beta.2"
sing_box_patch_dir="${repo_root}/patches/sing-box"
sslcon_source_dir="${repo_root}/third_party/sslcon"
sslcon_patch_dir="${repo_root}/patches/sslcon"

cleanup() {
	if [[ -n "${staging_dir}" && -d "${staging_dir}" ]]; then
		rm -rf "${staging_dir}"
	fi
}
trap cleanup EXIT

write_input_manifest() {
	local input_file

	echo "xdial-patched-go-inputs-v2"
	for input_file in \
		"${repo_root}/go.mod" \
		"${repo_root}/go.sum" \
		"${script_dir}/$(basename "${BASH_SOURCE[0]}")"; do
		cksum "${input_file}"
	done
	for input_file in "${patch_dir}"/*.patch; do
		[[ -f "${input_file}" ]] || continue
		cksum "${input_file}"
	done
	for input_file in "${sing_box_patch_dir}"/*.patch; do
		[[ -f "${input_file}" ]] || continue
		cksum "${input_file}"
	done
	for input_file in "${sslcon_patch_dir}"/*.patch; do
		[[ -f "${input_file}" ]] || continue
		cksum "${input_file}"
	done
	while IFS= read -r input_file; do
		cksum "${input_file}"
	done < <(find "${sslcon_source_dir}" -type f -print | LC_ALL=C sort)
}

atomic_exchange() {
	local source_path="$1"
	local destination_path="$2"

	if ! command -v python3 >/dev/null 2>&1; then
		echo "error: python3 is required to atomically replace ${destination_path}" >&2
		return 1
	fi

	python3 - "${source_path}" "${destination_path}" <<'PY'
import ctypes
import os
import sys

source = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
rename_swap = 0x00000002

if sys.platform == "darwin":
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    result = rename(source, destination, rename_swap)
elif sys.platform.startswith("linux"):
    rename = libc.renameat2
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename.restype = ctypes.c_int
    at_fdcwd = -100
    result = rename(at_fdcwd, source, at_fdcwd, destination, rename_swap)
else:
    raise SystemExit(f"atomic directory exchange is unsupported on {sys.platform}")

if result != 0:
    error_number = ctypes.get_errno()
    raise OSError(
        error_number,
        f"cannot atomically exchange {os.fsdecode(source)} and "
        f"{os.fsdecode(destination)}",
    )
PY
}

case "${1:-}" in
	"") ;;
	--check)
		if [[ \
			-f "${output_dir}/xdial.work" &&
			-d "${output_dir}/tailscale" &&
			-d "${output_dir}/sing-box" &&
			-d "${output_dir}/sslcon" &&
			-f "${output_dir}/${input_manifest_name}" \
		]] && cmp -s \
			<(write_input_manifest) \
			"${output_dir}/${input_manifest_name}"; then
			exit 0
		fi
		exit 1
		;;
	*)
		echo "usage: $0 [--check]" >&2
		exit 2
		;;
esac

actual_version="$(
	cd "${repo_root}"
	GOWORK=off GOFLAGS= go list -mod=readonly -m -f '{{.Version}}' "${module_path}"
)"
if [[ "${actual_version}" != "${expected_version}" ]]; then
	echo "error: ${module_path} is ${actual_version}; patch expects ${expected_version}" >&2
	echo "error: review the upstream fix before changing the pinned version" >&2
	exit 1
fi

sing_box_actual_version="$(
	cd "${repo_root}"
	GOWORK=off GOFLAGS= go list -mod=readonly -m -f '{{.Version}}' "${sing_box_module_path}"
)"
if [[ "${sing_box_actual_version}" != "${sing_box_expected_version}" ]]; then
	echo "error: ${sing_box_module_path} is ${sing_box_actual_version}; patch expects ${sing_box_expected_version}" >&2
	echo "error: review the upstream fix before changing the pinned version" >&2
	exit 1
fi

case "${output_dir}" in
	"${repo_root}"/build/*) ;;
	*)
		echo "error: refusing to replace generated directory outside build/: ${output_dir}" >&2
		exit 1
		;;
esac

mkdir -p "$(dirname "${output_dir}")"
staging_dir="$(mktemp -d "${output_dir}.tmp.XXXXXX")"
cp "${repo_root}/go.mod" "${staging_dir}/xdial.mod"
cp "${repo_root}/go.sum" "${staging_dir}/xdial.sum"

# An explicit module download can add missing checksums to the active module's
# go.sum. Point it at the staging copy so preparing generated dependencies
# never writes the repository's go.mod or go.sum.
GOWORK=off GOFLAGS= go mod download \
	-modfile="${staging_dir}/xdial.mod" \
	"${module_path}@${expected_version}"
GOWORK=off GOFLAGS= go mod download \
	-modfile="${staging_dir}/xdial.mod" \
	"${sing_box_module_path}@${sing_box_expected_version}"

module_cache="$(GOWORK=off GOFLAGS= go env GOMODCACHE)"
source_dir="${module_cache}/${module_path}@${expected_version}"
if [[ ! -d "${source_dir}" ]]; then
	echo "error: downloaded module directory not found: ${source_dir}" >&2
	exit 1
fi

sing_box_source_dir="${module_cache}/${sing_box_module_path}@${sing_box_expected_version}"
if [[ ! -d "${sing_box_source_dir}" ]]; then
	echo "error: downloaded module directory not found: ${sing_box_source_dir}" >&2
	exit 1
fi

patched_sing_box_dir="${staging_dir}/sing-box"
cp -R "${sing_box_source_dir}" "${patched_sing_box_dir}"
chmod -R u+w "${patched_sing_box_dir}"

sing_box_patch_files=()
for patch_file in "${sing_box_patch_dir}"/*.patch; do
	[[ -f "${patch_file}" ]] || continue
	sing_box_patch_files+=("${patch_file}")
done
if [[ "${#sing_box_patch_files[@]}" -eq 0 ]]; then
	echo "error: no sing-box patches found in ${sing_box_patch_dir}" >&2
	exit 1
fi
for patch_file in "${sing_box_patch_files[@]}"; do
	(
		cd "${patched_sing_box_dir}"
		patch -p1 --batch --forward < "${patch_file}"
	)
done

grep -Fq 'if allowedIP.Bits() == 0 {' \
	"${patched_sing_box_dir}/protocol/tailscale/endpoint.go"

patched_module_dir="${staging_dir}/tailscale"
cp -R "${source_dir}" "${patched_module_dir}"
chmod -R u+w "${patched_module_dir}"

patch_files=()
for patch_file in "${patch_dir}"/*.patch; do
	[[ -f "${patch_file}" ]] || continue
	patch_files+=("${patch_file}")
done
if [[ "${#patch_files[@]}" -eq 0 ]]; then
	echo "error: no Tailscale patches found in ${patch_dir}" >&2
	exit 1
fi
for patch_file in "${patch_files[@]}"; do
	(
		cd "${patched_module_dir}"
		patch -p1 --batch --forward < "${patch_file}"
	)
done

grep -Fq 'b.MagicConn().ResetNetInfoLast()' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'func (c *Conn) ResetNetInfoLast()' \
	"${patched_module_dir}/wgengine/magicsock/magicsock.go"
grep -Fq 'func TestResetNetInfoLast(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/netinfo_reset_test.go"
grep -Fq 'func TestDERPActiveWaitsForStartGate(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/derp_active_gate_test.go"
grep -Fq 'func (c *Conn) XDialDERPConnectionState() XDialDERPConnectionDiagnostics' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'func (b *LocalBackend) XDialControlNetInfoState() XDialControlNetInfoDiagnostics' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_diagnostics.go"
grep -Fq 'func TestXDialDERPProtocolReadyTracksReconnect(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_diagnostics_test.go"
grep -Fq 'func TestXDialControlNetInfoTrackerGeneration(t *testing.T)' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_diagnostics_test.go"
grep -Fq 'func TestXDialFullNetmapReconcilesDERPHomeMutation(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_netmap_reconcile_test.go"
grep -Fq 'func (b *LocalBackend) XDialReselectHomeDERP(' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'func (c *Conn) XDialPrepareHomeDERPReselection(' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'func (c *Conn) XDialCommitHomeDERPReselection(' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'func TestXDialDERPHomeReselectionRequiresCurrentControlClient(t *testing.T)' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection_test.go"
grep -Fq 'func TestXDialControlHomeMatchesExactBaseline(t *testing.T)' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection_test.go"
grep -Fq 'FailureCode = "local_control_baseline_mismatch"' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'ControlSelfHomeMatchesPlanAlternate' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'func TestXDialLocalControlBaselineUsesCurrentGenerationNetInfo(' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection_test.go"
grep -Fq 'func (c *Auto) XDialSetNetInfoWithReceipt(' \
	"${patched_module_dir}/control/controlclient/auto.go"
grep -Fq 'func (r XDialNetInfoReceipt) State() XDialNetInfoReceiptState' \
	"${patched_module_dir}/control/controlclient/xdial_update.go"
grep -Fq 'func TestXDialNetInfoReceiptRequiresExactHTTPAcceptedSnapshot(' \
	"${patched_module_dir}/control/controlclient/xdial_update_test.go"
grep -Fq 'ControlUpdateHTTPAccepted' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'ControlUpdateSuperseded' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'func TestXDialPickAlternateDERPUsesLowestMeasuredLatency(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection_test.go"
grep -Fq 'active.protocolReady' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'func (c *Conn) xdialNormalizePinnedDERPLocked() int' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'ni.PreferredDERP = pinnedDERP' \
	"${patched_module_dir}/wgengine/magicsock/magicsock.go"
grep -Fq 'func TestXDialPrivateKeyChangeInvalidatesReselection(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection_test.go"
grep -Fq 'func TestXDialHomelessInvalidatesReselection(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection_test.go"
grep -Fq 'func TestXDialCommitHomeDERPReselectionHonorsCanceledContext(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection_test.go"
grep -Fq 'func (c *Conn) XDialNormalizeNetInfoForControl(' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'xdialNetInfoSendMu.Lock()' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'normalized, current := b.MagicConn().' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'if !current {' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'if c.netInfoLast != ni {' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'normalized.PreferredDERP = c.myDerp' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"
grep -Fq 'func TestXDialNetInfoControlBoundaryRejectsSupersededCallbacks(' \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection_test.go"
grep -Fq 'b.xdialNetInfoSendMu.Unlock()' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'Ignoring SetControlClientStatus from old client after TKA sync' \
	"${patched_module_dir}/ipn/ipnlocal/local.go"
grep -Fq 'netMap.SelfNode.HomeDERP() == alternateDERP' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go"
grep -Fq 'func (c *Conn) XDialPeerDERPState(' \
	"${patched_module_dir}/wgengine/magicsock/xdial_peer_derp_diagnostics.go"
grep -Fq 'func (c *Client) XDialSendWithGeneration(' \
	"${patched_module_dir}/derp/derphttp/derphttp_client.go"
grep -Fq 'if !serverKey.IsZero() {' \
	"${patched_module_dir}/derp/derphttp/derphttp_client.go"
grep -Fq 'c.atomicState.Store(ConnectedState{})' \
	"${patched_module_dir}/derp/derphttp/derphttp_client.go"
grep -Fq 'LastWriteClientIdealKnown bool' \
	"${patched_module_dir}/wgengine/magicsock/xdial_peer_derp_diagnostics.go"
grep -Fq 'ServerChangeSequence' \
	"${patched_module_dir}/wgengine/magicsock/xdial_peer_derp_diagnostics.go"
grep -Fq 'connGen, err := dc.XDialSendWithGeneration' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'delete(c.xdialPeerDERP, peer)' \
	"${patched_module_dir}/wgengine/magicsock/magicsock.go"
grep -Fq 'func TestXDialPeerDERPStateNotHereWithoutReplyRoute(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_peer_derp_diagnostics_test.go"
grep -Fq 'func TestXDialPeerDERPStateSeparatesExplicitCloseAndReaderError(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_peer_derp_diagnostics_test.go"
grep -Fq 'func TestXDialConnectionGenerationAndServerChange(t *testing.T)' \
	"${patched_module_dir}/derp/derphttp/xdial_diagnostics_test.go"
grep -Fq 'func TestXDialCloseForReconnectClearsConnectedState(t *testing.T)' \
	"${patched_module_dir}/derp/derphttp/xdial_diagnostics_test.go"
grep -Fq 'HomeIdealKnown           bool' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'HomeConnectionGeneration int' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'HomeServerChangeSequence uint64' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'client := active.c.XDialConnectionDiagnostics()' \
	"${patched_module_dir}/wgengine/magicsock/derp.go"
grep -Fq 'func TestXDialHomeDERPConnectionDiagnosticsProjection(t *testing.T)' \
	"${patched_module_dir}/wgengine/magicsock/xdial_diagnostics_test.go"
if grep -Eq 'DebugPickNewDERP\(|DebugForcePreferDERP\(|RotateDiscoKey\(|SetDiscoPublicKey\(|\.EditPrefs\(|WantRunning[[:space:]]*[:=]' \
	"${patched_module_dir}/ipn/ipnlocal/xdial_derp_reselection.go" \
	"${patched_module_dir}/wgengine/magicsock/xdial_derp_reselection.go"; then
	echo "error: bounded HomeDERP reselection used a debug or persistent lifecycle hook" >&2
	exit 1
fi

patched_sslcon_dir="${staging_dir}/sslcon"
cp -R "${sslcon_source_dir}" "${patched_sslcon_dir}"
chmod -R u+w "${patched_sslcon_dir}"

sslcon_patch_files=()
for patch_file in "${sslcon_patch_dir}"/*.patch; do
	[[ -f "${patch_file}" ]] || continue
	sslcon_patch_files+=("${patch_file}")
done
if [[ "${#sslcon_patch_files[@]}" -eq 0 ]]; then
	echo "error: no sslcon patches found in ${sslcon_patch_dir}" >&2
	exit 1
fi
for patch_file in "${sslcon_patch_files[@]}"; do
	(
		cd "${patched_sslcon_dir}"
		patch -p1 --batch --forward < "${patch_file}"
	)
done

grep -Fq 'func (c *ClientConfig) SetXDialForceDPD(seconds int)' \
	"${patched_sslcon_dir}/base/config.go"
grep -Fq 'func (cSess *ConnSession) XDialDiagnosticsJSON() string' \
	"${patched_sslcon_dir}/session/xdial_liveness.go"
grep -Fq 'reason.PeerPayloadLength,' \
	"${patched_sslcon_dir}/session/xdial_liveness.go"
grep -Fq 'SchemaVersion:   2,' \
	"${patched_sslcon_dir}/session/xdial_liveness.go"
grep -Fq 'func TestReadTLSPayloadBoundsAndSanitizesDisconnectReason(' \
	"${patched_sslcon_dir}/vpn/xdial_liveness_test.go"
grep -Fq 'func TestXDialLateOldSessionCloseCannotClearNewSession(' \
	"${patched_sslcon_dir}/session/xdial_liveness_test.go"

GOWORK=off GOFLAGS= go mod edit \
	-modfile="${staging_dir}/xdial.mod" \
	-replace="${module_path}=${output_dir}/tailscale"
GOWORK=off GOFLAGS= go mod edit \
	-modfile="${staging_dir}/xdial.mod" \
	-replace="${sing_box_module_path}=${output_dir}/sing-box"
GOWORK=off GOFLAGS= go mod edit \
	-modfile="${staging_dir}/xdial.mod" \
	-replace="sslcon=${output_dir}/sslcon"

# gomobile overwrites GOFLAGS for each target architecture, so a -modfile
# replacement is not inherited by the actual bind build. An explicit GOWORK
# survives that boundary and makes the patched module the workspace module.
(
	cd "${staging_dir}"
	GOWORK=off GOFLAGS= go work init ../.. ./tailscale ./sing-box ./sslcon
	mv go.work xdial.work
)
write_input_manifest > "${staging_dir}/${input_manifest_name}"

# Resolve and validate the complete staged workspace before it can replace the
# last known-good output. Both staging and final directories have the same
# depth below the repository, so xdial.work's relative use paths remain valid.
resolved_dir="$(
	cd "${repo_root}"
	GOWORK="${staging_dir}/xdial.work" GOFLAGS= \
		go list -m -f '{{.Dir}}' "${module_path}"
)"
if [[ "${resolved_dir}" != "${staging_dir}/tailscale" ]]; then
	echo "error: patched workspace resolved ${module_path} to ${resolved_dir}" >&2
	exit 1
fi
resolved_sing_box_dir="$(
	cd "${repo_root}"
	GOWORK="${staging_dir}/xdial.work" GOFLAGS= \
		go list -m -f '{{.Dir}}' "${sing_box_module_path}"
)"
if [[ "${resolved_sing_box_dir}" != "${staging_dir}/sing-box" ]]; then
	echo "error: patched workspace resolved ${sing_box_module_path} to ${resolved_sing_box_dir}" >&2
	exit 1
fi
resolved_sslcon_dir="$(
	cd "${repo_root}"
	GOWORK="${staging_dir}/xdial.work" GOFLAGS= \
		go list -m -f '{{.Dir}}' sslcon
)"
if [[ "${resolved_sslcon_dir}" != "${staging_dir}/sslcon" ]]; then
	echo "error: patched workspace resolved sslcon to ${resolved_sslcon_dir}" >&2
	exit 1
fi

if [[ -e "${output_dir}" || -L "${output_dir}" ]]; then
	# RENAME_SWAP / RENAME_EXCHANGE keeps the old output visible until the new
	# validated tree becomes visible in a single filesystem operation. After
	# the exchange, staging_dir names the old output and cleanup can remove it.
	atomic_exchange "${staging_dir}" "${output_dir}"
	rm -rf "${staging_dir}"
else
	# rename within build/ is atomic for the initial installation.
	mv "${staging_dir}" "${output_dir}"
fi
staging_dir=""

echo "prepared patched ${module_path}@${expected_version}"
echo "prepared patched ${sing_box_module_path}@${sing_box_expected_version}"
echo "prepared patched sslcon from ${sslcon_source_dir}"
echo "modfile: ${output_dir}/xdial.mod"
echo "workfile: ${output_dir}/xdial.work"
