#!/usr/bin/env bash
# Install the LoongArch64 GNU cross toolchain used to build the
# loongarch64-unknown-linux-gnu release artifacts, plus a cross-compiled
# libcap for bubblewrap.
#
# The toolchain comes from the community cross-tools project:
# https://github.com/loong64/cross-tools/releases/tag/20260912
# Ubuntu ships no loong64 packages, so libcap is cross-compiled from source
# exactly like the musl cross build path in install-musl-build-tools.sh.
set -euo pipefail

: "${TARGET:?TARGET environment variable is required}"
: "${GITHUB_ENV:?GITHUB_ENV environment variable is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE environment variable is required}"

if [[ "${TARGET}" != "loongarch64-unknown-linux-gnu" ]]; then
  echo "Unexpected LoongArch64 target: ${TARGET}" >&2
  exit 1
fi

# Toolchain variant: "stable" tracks GCC 14 / glibc 2.38, which matches the
# glibc baseline of the prebuilt LoongArch64 rusty_v8 artifacts.
cross_tools_version="20260912"
cross_tools_variant="stable"

case "$(uname -m)" in
  x86_64)
    cross_tools_host="x86_64"
    ;;
  aarch64|arm64)
    cross_tools_host="aarch64"
    ;;
  *)
    echo "Unsupported cross-tools host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

toolchain_prefix="loongarch64-unknown-linux-gnu"
artifact="${cross_tools_host}-cross-tools-${TARGET}-${cross_tools_variant}"
download_url="https://github.com/loong64/cross-tools/releases/download/${cross_tools_version}/${artifact}.tar.xz"

runner_temp="${RUNNER_TEMP:-/tmp}"
tool_root="${runner_temp}/codex-loongarch64-tools"
# cross-tools is built for /opt/x-tools and bakes that prefix into the GCC
# driver, so install it exactly where its README says to.
cross_tools_root="/opt/x-tools"
toolchain_root="${cross_tools_root}/${toolchain_prefix}"

sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  pkg-config \
  xz-utils

if [[ ! -x "${toolchain_root}/bin/${toolchain_prefix}-gcc" ]]; then
  sudo mkdir -p "${cross_tools_root}"
  archive="${tool_root}/${artifact}.tar.xz"
  curl -fsSL "${download_url}" -o "${archive}"
  sudo tar -xJf "${archive}" -C "${cross_tools_root}"
  rm -f "${archive}"
fi

# libcap's Makefile invokes OBJCOPY as a bare name, so the toolchain must be
# reachable while this step runs.
export PATH="${toolchain_root}/bin:${PATH}"

cc="${toolchain_root}/bin/${toolchain_prefix}-gcc"
cxx="${toolchain_root}/bin/${toolchain_prefix}-g++"
if [[ ! -x "${cc}" || ! -x "${cxx}" ]]; then
  echo "cross-tools toolchain is incomplete under ${toolchain_root}" >&2
  exit 1
fi

# bubblewrap links against libcap, which has no loong64 build in the Ubuntu
# archive. Cross-compile a static libcap and expose it through pkg-config.
libcap_version="2.75"
libcap_sha256="de4e7e064c9ba451d5234dd46e897d7c71c96a9ebf9a0c445bc04f4742d83632"
libcap_tarball_name="libcap-${libcap_version}.tar.xz"
libcap_download_url="https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/${libcap_tarball_name}"

libcap_root="${tool_root}/libcap-${libcap_version}"
libcap_src_root="${libcap_root}/src"
libcap_prefix="${libcap_root}/prefix"
libcap_pkgconfig_dir="${libcap_prefix}/lib/pkgconfig"

if [[ ! -f "${libcap_prefix}/lib/libcap.a" ]]; then
  mkdir -p "${libcap_src_root}" "${libcap_prefix}/lib" "${libcap_prefix}/include/sys" "${libcap_prefix}/include/linux" "${libcap_pkgconfig_dir}"
  libcap_tarball="${libcap_root}/${libcap_tarball_name}"

  curl -fsSL "${libcap_download_url}" -o "${libcap_tarball}"
  echo "${libcap_sha256}  ${libcap_tarball}" | sha256sum -c -

  tar -xJf "${libcap_tarball}" -C "${libcap_src_root}"
  libcap_source_dir="${libcap_src_root}/libcap-${libcap_version}"
  # BUILD_CC defaults to CC (Make.Rules: BUILD_CC ?= $(CC)), but _makenames is
  # a build-time host tool; compiling it with the cross compiler yields a
  # loongarch64 binary that cannot run on the x86_64 runner. OBJCOPY defaults
  # to the host objcopy, which cannot read loongarch64 objects either.
  make -C "${libcap_source_dir}/libcap" -j"$(nproc)" \
    CC="${cc}" \
    BUILD_CC=gcc \
    OBJCOPY="${toolchain_prefix}-objcopy" \
    AR=ar \
    RANLIB=ranlib

  cp "${libcap_source_dir}/libcap/libcap.a" "${libcap_prefix}/lib/libcap.a"
  cp "${libcap_source_dir}/libcap/include/uapi/linux/capability.h" "${libcap_prefix}/include/linux/capability.h"
  cp "${libcap_source_dir}/libcap/include/sys/capability.h" "${libcap_prefix}/include/sys/capability.h"

  cat > "${libcap_pkgconfig_dir}/libcap.pc" <<EOF
prefix=${libcap_prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libcap
Description: Linux capabilities
Version: ${libcap_version}
Libs: -L\${libdir} -lcap
Cflags: -I\${includedir}
EOF
fi

env_set() {
  echo "$1=$2" >> "$GITHUB_ENV"
}

target_cc_var="CC_${TARGET//-/_}"
target_cxx_var="CXX_${TARGET//-/_}"
cargo_linker_var="CARGO_TARGET_${TARGET^^}_LINKER"
cargo_linker_var="${cargo_linker_var//-/_}"
cflags_var="CFLAGS_${TARGET//-/_}"
cxxflags_var="CXXFLAGS_${TARGET//-/_}"
pkg_config_path_var="PKG_CONFIG_PATH_${TARGET//-/_}"
pkg_config_libdir_var="PKG_CONFIG_LIBDIR_${TARGET//-/_}"

env_set "${target_cc_var}" "${cc}"
env_set "${target_cxx_var}" "${cxx}"
env_set "${cargo_linker_var}" "${cc}"
env_set "CMAKE_C_COMPILER" "${cc}"
env_set "CMAKE_CXX_COMPILER" "${cxx}"
# The host strip/objcopy cannot read loongarch64 objects.
env_set "STRIP" "${toolchain_prefix}-strip"
env_set "OBJCOPY" "${toolchain_prefix}-objcopy"
# GCC defaults to the small code model, which overflows the +/-2GiB PC-relative
# range when linking the V8 static library. aws-lc-sys and bwrap pick this up
# through their target-scoped CFLAGS.
env_set "${cflags_var}" "-mcmodel=medium"
env_set "${cxxflags_var}" "-mcmodel=medium"
# bwrap links against the cross-compiled libcap above.
env_set "PKG_CONFIG_ALLOW_CROSS" "1"
env_set "${pkg_config_path_var}" "${libcap_pkgconfig_dir}"
env_set "${pkg_config_libdir_var}" "${libcap_pkgconfig_dir}"

echo "${toolchain_root}/bin" >> "$GITHUB_PATH"
