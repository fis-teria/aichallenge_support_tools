#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu 22.04 NVIDIA stack installer.
#
# Installs:
#   - NVIDIA driver for nvidia-smi
#   - CUDA Toolkit for nvcc
#   - NVIDIA Container Toolkit for Docker GPU access
#
# Safety rules:
#   - Only Ubuntu 22.04 is accepted.
#   - Existing NVIDIA driver packages are not removed automatically.
#   - Driver package removal requires an exact confirmation string.
#   - CUDA packages and NVIDIA Container Toolkit packages are not purged by the
#     old-driver cleanup step.
#
# Common overrides:
#   DRIVER_SPEC=auto                 # auto, 595-open, 595, 580-open, 535, etc.
#   DRIVER_PROFILE=desktop           # desktop or gpgpu
#   CUDA_TOOLKIT_PACKAGE=cuda-toolkit-12-8
#   CONFIGURE_DOCKER=prompt          # prompt, yes, no
#   FORCE_REPO_SETUP=0               # 1 to rewrite NVIDIA apt repo files
#   UNHOLD_NVIDIA_DRIVER=no          # yes to unhold driver packages before install
#   HOLD_NVIDIA_DRIVER=no            # yes to hold installed driver packages after install

DRIVER_SPEC="${DRIVER_SPEC:-auto}"
DRIVER_PROFILE="${DRIVER_PROFILE:-desktop}"
CUDA_TOOLKIT_PACKAGE="${CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-12-8}"
CONFIGURE_DOCKER="${CONFIGURE_DOCKER:-prompt}"
FORCE_REPO_SETUP="${FORCE_REPO_SETUP:-0}"
UNHOLD_NVIDIA_DRIVER="${UNHOLD_NVIDIA_DRIVER:-no}"
HOLD_NVIDIA_DRIVER="${HOLD_NVIDIA_DRIVER:-no}"

SUDO=()
if (( EUID != 0 )); then
    SUDO=(sudo)
fi

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '\n[WARN] %s\n' "$*" >&2
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

confirm_yes() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

require_ubuntu_2204() {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only. Detected ID=${ID:-unknown}."
    [[ "${VERSION_ID:-}" == "22.04" ]] || die "This script supports Ubuntu 22.04 only. Detected VERSION_ID=${VERSION_ID:-unknown}."
}

require_supported_arch() {
    local arch
    arch="$(dpkg --print-architecture)"
    [[ "${arch}" == "amd64" ]] || die "This script currently supports amd64 only. Detected arch=${arch}."
}

require_sudo() {
    if (( EUID != 0 )); then
        log "Requesting sudo credentials."
        run sudo -v
    fi
}

list_installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 2>/dev/null \
        | awk '$1 == "ii" { print $2 "\t" $3 }'
}

list_driver_cleanup_packages() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 2>/dev/null \
        | awk '
            {
                status=$1
                pkg=$2
                if (status != "ii" && status != "rc") next
                if (pkg ~ /^nvidia-container-toolkit/) next
                if (pkg ~ /^nvidia-container-runtime/) next
                if (pkg ~ /^libnvidia-container/) next
                if (pkg ~ /^cuda/) next
                if (pkg ~ /^nvidia-cuda/) next
                if (pkg ~ /^nsight/) next

                if (pkg ~ /^nvidia-driver-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-dkms-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-compute-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-kernel-(common|source)-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-kernel-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-compute-utils-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-utils-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-firmware-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-persistenced$/) print pkg
                else if (pkg ~ /^libnvidia-(cfg1|common|compute|decode|encode|extra|fbc1|gl)-[0-9]/) print pkg
                else if (pkg ~ /^xserver-xorg-video-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-modules-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-objects-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-signatures-nvidia-/) print pkg
            }
        ' \
        | sort -u
}

list_installed_driver_packages() {
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 2>/dev/null \
        | awk '
            {
                status=$1
                pkg=$2
                if (status != "ii") next
                if (pkg ~ /^nvidia-container-toolkit/) next
                if (pkg ~ /^nvidia-container-runtime/) next
                if (pkg ~ /^libnvidia-container/) next
                if (pkg ~ /^cuda/) next
                if (pkg ~ /^nvidia-cuda/) next
                if (pkg ~ /^nsight/) next

                if (pkg ~ /^nvidia-driver-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-dkms-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-compute-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-kernel-(common|source)-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-kernel-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-compute-utils-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-utils-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-firmware-[0-9]/) print pkg
                else if (pkg ~ /^nvidia-persistenced$/) print pkg
                else if (pkg ~ /^libnvidia-(cfg1|common|compute|decode|encode|extra|fbc1|gl)-[0-9]/) print pkg
                else if (pkg ~ /^xserver-xorg-video-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-modules-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-objects-nvidia-[0-9]/) print pkg
                else if (pkg ~ /^linux-signatures-nvidia-/) print pkg
            }
        ' \
        | sort -u
}

normalize_yes_no() {
    local name="$1"
    local value="$2"
    case "${value}" in
        yes|no) ;;
        *) die "${name} must be yes or no. Got ${value}." ;;
    esac
}

validate_settings() {
    normalize_yes_no UNHOLD_NVIDIA_DRIVER "${UNHOLD_NVIDIA_DRIVER}"
    normalize_yes_no HOLD_NVIDIA_DRIVER "${HOLD_NVIDIA_DRIVER}"
}

show_current_state() {
    log "Current OS and kernel"
    lsb_release -a 2>/dev/null || true
    uname -r

    log "Current NVIDIA/CUDA/container packages"
    list_installed_packages \
        | awk -F '\t' '$1 ~ /^(nvidia|libnvidia|cuda|nsight)/ { print }' \
        | sort || true

    log "Current commands"
    command -v nvidia-smi && nvidia-smi || true
    command -v nvcc && nvcc --version || true
    command -v nvidia-ctk && nvidia-ctk --version || true
    command -v docker && docker --version || true

    log "Current NVIDIA kernel state"
    cat /proc/driver/nvidia/version 2>/dev/null || true
    dkms status 2>/dev/null || true
    lsmod | grep -E '^(nvidia|nouveau)' || true
    ls -l /dev/nvidia* 2>/dev/null || true
}

maybe_purge_old_driver_packages() {
    local -a packages
    mapfile -t packages < <(list_driver_cleanup_packages)

    if ((${#packages[@]} == 0)); then
        log "No installed NVIDIA driver packages were detected for cleanup."
        return
    fi

    log "Detected NVIDIA driver packages for cleanup"
    printf '  %s\n' "${packages[@]}"

    warn "The cleanup below is limited to NVIDIA driver packages only."
    warn "It includes installed packages and residual-config packages such as rc entries."
    warn "The cleanup includes nvidia-compute-utils, nvidia-dkms, nvidia-kernel,"
    warn "linux-modules-nvidia, linux-objects-nvidia, and linux-signatures-nvidia packages."
    warn "CUDA packages and NVIDIA Container Toolkit packages are intentionally excluded."
    warn "General apt autoremove is intentionally not run automatically."

    log "Dry-run purge plan"
    run "${SUDO[@]}" apt-get -s purge "${packages[@]}"

    printf '\n'
    printf 'To purge the NVIDIA driver packages listed above, type exactly:\n'
    printf '  REMOVE_NVIDIA_DRIVER_PACKAGES\n'
    printf 'Anything else skips driver cleanup.\n'
    local answer
    read -r -p '> ' answer

    if [[ "${answer}" != "REMOVE_NVIDIA_DRIVER_PACKAGES" ]]; then
        log "Skipped NVIDIA driver package cleanup."
        return
    fi

    log "Purging selected NVIDIA driver packages."
    run "${SUDO[@]}" apt-get purge -y "${packages[@]}"
}

list_held_nvidia_driver_packages() {
    apt-mark showhold 2>/dev/null \
        | awk '
            /^nvidia-driver-[0-9]/ { print; next }
            /^nvidia-dkms-[0-9]/ { print; next }
            /^nvidia-compute-[0-9]/ { print; next }
            /^nvidia-kernel-(common|source)-[0-9]/ { print; next }
            /^nvidia-kernel-[0-9]/ { print; next }
            /^nvidia-compute-utils-[0-9]/ { print; next }
            /^nvidia-utils-[0-9]/ { print; next }
            /^nvidia-firmware-[0-9]/ { print; next }
            /^nvidia-persistenced$/ { print; next }
            /^libnvidia-(cfg1|common|compute|decode|encode|extra|fbc1|gl)-[0-9]/ { print; next }
            /^xserver-xorg-video-nvidia-[0-9]/ { print; next }
            /^linux-modules-nvidia-[0-9]/ { print; next }
            /^linux-objects-nvidia-[0-9]/ { print; next }
            /^linux-signatures-nvidia-/ { print; next }
        ' \
        | sort -u
}

maybe_unhold_nvidia_driver_packages() {
    local -a held
    mapfile -t held < <(list_held_nvidia_driver_packages)

    if ((${#held[@]} == 0)); then
        log "No held NVIDIA driver packages were detected."
        return
    fi

    log "Detected held NVIDIA driver packages"
    printf '  %s\n' "${held[@]}"

    if [[ "${UNHOLD_NVIDIA_DRIVER}" != "yes" ]]; then
        warn "Held packages can block driver upgrades or downgrades."
        warn "Set UNHOLD_NVIDIA_DRIVER=yes to unhold them before installing another driver version."
        return
    fi

    log "Unholding NVIDIA driver packages."
    run "${SUDO[@]}" apt-mark unhold "${held[@]}"
}

hold_installed_nvidia_driver_packages() {
    if [[ "${HOLD_NVIDIA_DRIVER}" != "yes" ]]; then
        log "Skipped NVIDIA driver package hold."
        return
    fi

    local -a packages
    mapfile -t packages < <(list_installed_driver_packages)

    if ((${#packages[@]} == 0)); then
        warn "No installed NVIDIA driver packages were detected to hold."
        return
    fi

    log "Holding installed NVIDIA driver packages."
    printf '  %s\n' "${packages[@]}"
    run "${SUDO[@]}" apt-mark hold "${packages[@]}"
}

install_prerequisites() {
    log "Installing base prerequisites."
    run "${SUDO[@]}" apt-get update
    run "${SUDO[@]}" apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        ubuntu-drivers-common
}

setup_cuda_repo() {
    local marker="/usr/share/keyrings/cuda-archive-keyring.gpg"
    if [[ "${FORCE_REPO_SETUP}" != "1" && -f "${marker}" && -f /etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list ]]; then
        log "CUDA apt repository already appears configured."
        return
    fi

    log "Configuring NVIDIA CUDA apt repository."
    local deb="/tmp/cuda-keyring_1.1-1_all.deb"
    run curl -fsSLo "${deb}" "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
    run "${SUDO[@]}" dpkg -i "${deb}"
    rm -f "${deb}"
}

setup_container_toolkit_repo() {
    local list_file="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
    if [[ "${FORCE_REPO_SETUP}" != "1" && -f "${list_file}" ]]; then
        log "NVIDIA Container Toolkit apt repository already appears configured."
        return
    fi

    log "Configuring NVIDIA Container Toolkit apt repository."
    curl -fsSL "https://nvidia.github.io/libnvidia-container/gpgkey" \
        | run "${SUDO[@]}" gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | run "${SUDO[@]}" tee "${list_file}" >/dev/null
}

install_nvidia_driver() {
    log "Available NVIDIA drivers reported by ubuntu-drivers"
    ubuntu-drivers list || true

    local -a command
    command=("${SUDO[@]}" ubuntu-drivers install)
    if [[ "${DRIVER_PROFILE}" == "gpgpu" ]]; then
        command+=("--gpgpu")
    elif [[ "${DRIVER_PROFILE}" != "desktop" ]]; then
        die "DRIVER_PROFILE must be desktop or gpgpu. Got ${DRIVER_PROFILE}."
    fi

    if [[ "${DRIVER_SPEC}" != "auto" ]]; then
        command+=("nvidia:${DRIVER_SPEC}")
    elif [[ "${HOLD_NVIDIA_DRIVER}" == "yes" ]]; then
        warn "HOLD_NVIDIA_DRIVER=yes with DRIVER_SPEC=auto can freeze whatever ubuntu-drivers selects."
        warn "For old-version pinning, prefer DRIVER_SPEC=595-open, DRIVER_SPEC=535, etc."
    fi

    log "Installing NVIDIA driver with ubuntu-drivers."
    run "${command[@]}"

    log "Installing nvidia-modprobe to help create /dev/nvidia* nodes when needed."
    run "${SUDO[@]}" apt-get install -y --no-install-recommends nvidia-modprobe
}

install_cuda_toolkit() {
    log "Installing CUDA Toolkit package: ${CUDA_TOOLKIT_PACKAGE}"
    run "${SUDO[@]}" apt-get install -y "${CUDA_TOOLKIT_PACKAGE}"

    log "Writing /etc/profile.d/cuda-toolkit.sh so /usr/local/cuda/bin is preferred for nvcc."
    "${SUDO[@]}" tee /etc/profile.d/cuda-toolkit.sh >/dev/null <<'EOF'
if [ -d /usr/local/cuda/bin ]; then
    case ":${PATH}:" in
        *:/usr/local/cuda/bin:*) ;;
        *) export PATH="/usr/local/cuda/bin:${PATH}" ;;
    esac
fi

if [ -d /usr/local/cuda/lib64 ]; then
    case ":${LD_LIBRARY_PATH:-}:" in
        *:/usr/local/cuda/lib64:*) ;;
        *) export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
    esac
fi
EOF
}

install_container_toolkit() {
    log "Installing NVIDIA Container Toolkit."
    run "${SUDO[@]}" apt-get install -y nvidia-container-toolkit

    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker is not installed or not in PATH. Installed the toolkit, but skipped Docker runtime configuration."
        return
    fi

    local configure="no"
    case "${CONFIGURE_DOCKER}" in
        yes) configure="yes" ;;
        no) configure="no" ;;
        prompt)
            if confirm_yes "Configure Docker NVIDIA runtime and restart Docker now?"; then
                configure="yes"
            fi
            ;;
        *) die "CONFIGURE_DOCKER must be prompt, yes, or no. Got ${CONFIGURE_DOCKER}." ;;
    esac

    if [[ "${configure}" != "yes" ]]; then
        log "Skipped Docker runtime configuration."
        return
    fi

    log "Configuring Docker runtime with nvidia-ctk."
    run "${SUDO[@]}" nvidia-ctk runtime configure --runtime=docker

    log "Restarting Docker."
    run "${SUDO[@]}" systemctl restart docker
}

verify_installation() {
    log "Verification"

    printf '\n--- nvidia-smi ---\n'
    nvidia-smi || true

    printf '\n--- nvcc ---\n'
    if [[ -x /usr/local/cuda/bin/nvcc ]]; then
        /usr/local/cuda/bin/nvcc --version || true
    else
        nvcc --version || true
    fi

    printf '\n--- nvidia-ctk ---\n'
    nvidia-ctk --version || true

    printf '\n--- /dev/nvidia* ---\n'
    ls -l /dev/nvidia* 2>/dev/null || true

    printf '\n--- Docker GPU runtime hint ---\n'
    docker info 2>/dev/null | grep -i nvidia || true

    cat <<'EOF'

If nvidia-smi still fails immediately after installation, reboot first.
After reboot, verify:
  nvidia-smi
  /usr/local/cuda/bin/nvcc --version
  nvidia-ctk --version
  docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi

EOF
}

main() {
    require_ubuntu_2204
    require_supported_arch
    require_sudo
    validate_settings

    show_current_state
    maybe_unhold_nvidia_driver_packages
    maybe_purge_old_driver_packages

    install_prerequisites
    setup_cuda_repo
    setup_container_toolkit_repo
    run "${SUDO[@]}" apt-get update

    install_nvidia_driver
    hold_installed_nvidia_driver_packages
    install_cuda_toolkit
    install_container_toolkit
    verify_installation

    warn "A reboot is strongly recommended before judging nvidia-smi or Docker GPU access."
}

main "$@"
