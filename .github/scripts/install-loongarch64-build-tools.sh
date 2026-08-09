#!/usr/bin/env bash
# Install the LoongArch64 GNU cross toolchain and a cross-compiled libcap
# for bubblewrap, then export the environment variables Cargo/cc/cmake/
# pkg-config need for `loongarch64-unknown-linux-gnu` cross builds.
#
# Ubuntu ships no loong64 binary packages (the LoongArch64 port lives outside
# the main archive), so libcap is built from source exactly like the musl
# cross build path in install-musl-build-tools.sh.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV environment variable is required}"

toolchain_prefix="loongarch64-linux-gnu"
cc="${toolchain_prefix}-gcc-13"
cxx="${toolchain_prefix}-g++-13"

# Ubuntu 24.04 ships the LoongArch64 cross-toolchain in its main archive.
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  gcc-13-loongarch64-linux-gnu \
  g++-13-loongarch64-linux-gnu \
  binutils-loongarch64-linux-gnu \
  lld \
  xz-utils

libcap_version="2.75"
libcap_sha256="de4e7e064c9ba451d5234dd46e897d7c71c96a9ebf9a0c445bc04f4742d83632"
libcap_tarball_name="libcap-${libcap_version}.tar.xz"
libcap_download_url="https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/${libcap_tarball_name}"

runner_temp="${RUNNER_TEMP:-/tmp}"
tool_root="${runner_temp}/codex-loong64-tools"
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
  # BUILD_CC defaults to CC (Make.Rules: BUILD_CC ?= $(CC)), but _makenames
  # is a build-time host tool; compiling it with the cross compiler yields a
  # loongarch64 binary that cannot run on the x86_64 runner ("Exec format
  # error"). Build it with the host gcc instead.
  #
  # OBJCOPY defaults to $(CROSS_COMPILE)objcopy (Make.Rules), i.e. the host
  # objcopy, which cannot read the loongarch64 "empty" binary when generating
  # loader.txt for the shared library build. Use the cross objcopy from
  # binutils-loongarch64-linux-gnu. AR/RANLIB stay host tools: ar archives are
  # machine-independent.
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

# Point cc / cmake / cargo / pkg-config at the LoongArch64 toolchain.
env_set "CC_loongarch64_unknown_linux_gnu" "${cc}"
env_set "CXX_loongarch64_unknown_linux_gnu" "${cxx}"
env_set "CARGO_TARGET_LOONGARCH64_UNKNOWN_LINUX_GNU_LINKER" "${cc}"
env_set "CMAKE_C_COMPILER" "${cc}"
env_set "CMAKE_CXX_COMPILER" "${cxx}"
# The host strip/objcopy may not understand loongarch64 objects.
env_set "STRIP" "${toolchain_prefix}-strip"
env_set "OBJCOPY" "${toolchain_prefix}-objcopy"
env_set "CFLAGS_loongarch64_unknown_linux_gnu" "-pthread"
env_set "CXXFLAGS_loongarch64_unknown_linux_gnu" "-pthread"
# bwrap links against the cross-compiled libcap above.
env_set "PKG_CONFIG_ALLOW_CROSS" "1"
env_set "PKG_CONFIG_LIBDIR_loongarch64_unknown_linux_gnu" "${libcap_pkgconfig_dir}"
