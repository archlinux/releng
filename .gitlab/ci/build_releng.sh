#!/usr/bin/env bash
#
# This script is run within a virtual environment to build the available archiso profiles and their available build
# modes and create checksum files for the resulting images.
# The script needs to be run as root and assumes $PWD to be the root of the repository.
#
# Dependencies:
# * archiso
# * gawk
# * gnupg
# * openssl
# * zsync

set -eu
shopt -s extglob

readonly orig_pwd="${PWD}"
readonly output="${orig_pwd}/output"
readonly tmpdir_base="${orig_pwd}/tmp"
readonly install_dir="arch"
readonly app_name="${0##*/}"

tmpdir=""
tmpdir="$(mktemp --dry-run --directory --tmpdir="${tmpdir_base}")"
gnupg_homedir=""
codesigning_dir=""
codesigning_cert=""
codesigning_key=""
pgp_key_id=""

print_section_start() {
  # gitlab collapsible sections start: https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
  local _section _title
  _section="${1}"
  _title="${2}"

  printf "\e[0Ksection_start:%(%s)T:%s\r\e[0K%s\n" '-1' "${_section}" "${_title}"
}

print_section_end() {
  # gitlab collapsible sections end: https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
  local _section
  _section="${1}"

  printf "\e[0Ksection_end:%(%s)T:%s\r\e[0K\n" '-1' "${_section}"
}

cleanup() {
  # clean up temporary directories
  print_section_start "cleanup" "Cleaning up temporary directory"

  if [ -n "${tmpdir_base:-}" ]; then
    rm -fr "${tmpdir_base}"
  fi

  print_section_end "cleanup"
}

create_checksums() {
  # create checksums for files
  # $@: files
  local _file_path _file_name _current_pwd
  _current_pwd="${PWD}"

  print_section_start "checksums" "Creating checksums"

  for _file_path in "$@"; do
    cd "$(dirname "${_file_path}")"
    _file_name="$(basename "${_file_path}")"
    b2sum "${_file_name}" > "${_file_name}.b2"
    md5sum "${_file_name}" > "${_file_name}.md5"
    sha1sum "${_file_name}" > "${_file_name}.sha1"
    sha256sum "${_file_name}" > "${_file_name}.sha256"
    sha512sum "${_file_name}" > "${_file_name}.sha512"
    grep -H . -- "${_file_name}."{b2,md5,sha{1,256,512}}
  done
  cd "${_current_pwd}"

  print_section_end "checksums"
}

create_zsync_delta() {
  # create zsync control files for files
  # $@: files
  local _file

  print_section_start "zsync_delta" "Creating zsync delta"

  for _file in "$@"; do
    if [[ "${_file}" != *.iso ]]; then
      # zsyncmake fails on 'too long between blocks' with default block size on bootstrap image
      zsyncmake -v -b 512 -C -u "${_file##*/}" -o "${_file}".zsync "${_file}"
    else
      zsyncmake -v -C -u "${_file##*/}" -o "${_file}".zsync "${_file}"
    fi
  done

  print_section_end "zsync_delta"
}

create_metrics() {
  local _metrics="${output}/metrics.txt"
  # create metrics
  print_section_start "metrics" "Creating metrics"

  {
    # metrics on build environment
    printf 'version_info{package="archiso",name="Version of archiso used for build",version="%s"} 1\n' \
      "$(pacman -Q archiso |cut -d' ' -f2)"
    printf 'version_info{package="ipxe",name="Version of iPXE binaries",version="%s"} 1\n' \
      "$(pacman -Q ipxe |cut -d' ' -f2)"
    # create metrics per buildmode
    printf 'version_info{package="linux",name="Version of Linux used in image",version="%s"} 1\n' \
      "$(file "${output}/arch/boot/"*/vmlinuz-linux| cut -d',' -f2| awk '{print $2}')"
    printf 'size_mebibytes{buildmode="iso",artifact="iso"} %s\n' \
      "$(du -m -- "${output}/"*.iso | cut -f1)"
    printf 'package_count{buildmode="iso"} %s\n' \
      "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
    if [[ -e "${tmpdir}/efiboot.img" ]]; then
      printf 'size_mebibytes{buildmode="iso",artifact="eltorito_efi_image"} %s\n' \
        "$(du -m -- "${tmpdir}/efiboot.img" | cut -f1)"
    fi
    printf 'size_mebibytes{buildmode="iso",artifact="initramfs"} %s\n' \
      "$(du -m -- "${tmpdir}/iso/"*/boot/**/initramfs*.img | cut -f1)"
    printf 'size_mebibytes{buildmode="netboot",artifact="directory"} %s\n' \
      "$(du -m -- "${output}/${install_dir}/" | tail -n1 | cut -f1)"
    printf 'package_count{buildmode="netboot"} %s\n' \
      "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
    printf 'size_mebibytes{buildmode="bootstrap",artifact="compressed"} %s\n' \
      "$(du -m -- "${output}/"*.tar*(.gz|.xz|.zst) | cut -f1)"
    printf 'package_count{buildmode="bootstrap"} %s\n' \
      "$(sort -u -- "${tmpdir}/"*/bootstrap/root.*/pkglist.*.txt | wc -l)"
  } > "${_metrics}"
  cat "${_metrics}"

  print_section_end "metrics"
}

create_ephemeral_pgp_key() {
  # create an ephemeral PGP key for signing the rootfs image
  print_section_start "ephemeral_pgp_key" "Creating ephemeral PGP key"

  gnupg_homedir="$tmpdir/.gnupg"
  mkdir -p "${gnupg_homedir}"
  chmod 700 "${gnupg_homedir}"

  cat << __EOF__ > "${gnupg_homedir}"/gpg.conf
quiet
batch
no-tty
no-permission-warning
export-options no-export-attributes,export-clean
list-options no-show-keyring
armor
no-emit-version
__EOF__

  gpg --homedir "${gnupg_homedir}" --gen-key <<EOF
%echo Generating ephemeral Arch Linux release engineering key pair...
Key-Type: default
Key-Length: 3072
Key-Usage: sign
Name-Real: Arch Linux Release Engineering
Name-Comment: Ephemeral Signing Key
Name-Email: arch-releng@lists.archlinux.org
Expire-Date: 0
%no-protection
%commit
%echo Done
EOF

  pgp_key_id="$(
    gpg --homedir "${gnupg_homedir}" \
        --list-secret-keys \
        --with-colons \
        | awk -F':' '{if($1 ~ /sec/){ print $5 }}'
  )"

  print_section_end "ephemeral_pgp_key"
}

create_ephemeral_codesigning_key() {
  # create ephemeral certificates used for codesigning
  print_section_start "ephemeral_codesigning_key" "Creating ephemeral codesigning key"

  codesigning_dir="${tmpdir}/.codesigning/"
  local codesigning_conf="${codesigning_dir}/openssl.cnf"
  local codesigning_subj="/C=DE/ST=Berlin/L=Berlin/O=Arch Linux/OU=Release Engineering/CN=archlinux.org"
  codesigning_cert="${codesigning_dir}/codesign.crt"
  codesigning_key="${codesigning_dir}/codesign.key"
  mkdir -p "${codesigning_dir}"
  cp -- /etc/ssl/openssl.cnf "${codesigning_conf}"
  printf "\n[codesigning]\nkeyUsage=digitalSignature\nextendedKeyUsage=codeSigning\n" >> "${codesigning_conf}"
  openssl req \
      -newkey rsa:4096 \
      -keyout "${codesigning_key}" \
      -nodes \
      -sha256 \
      -x509 \
      -days 365 \
      -out "${codesigning_cert}" \
      -config "${codesigning_conf}" \
      -subj "${codesigning_subj}" \
      -extensions codesigning

  print_section_end "ephemeral_codesigning_key"
}

select_codesigning_key() {
  local _codesigning_cert="${orig_pwd}/codesign.crt"
  local _codesigning_key="${orig_pwd}/codesign.key"

  if [[ -f "${_codesigning_key}" && -f "${_codesigning_cert}" ]]; then

    print_section_start "select_codesigning_key" "Select codesigning key"

    printf "Using local codesigning key pair!\n%s %s\n" "${_codesigning_cert}" "${_codesigning_key}"
    codesigning_cert="${_codesigning_cert}"
    codesigning_key="${_codesigning_key}"

    print_section_end "select_codesigning_key"
  else
    create_ephemeral_codesigning_key
  fi
}

check_codesigning_cert_validity() {
  local _now _valid_until _ninety_days=7776000
  printf -v _now "%(%s)T" '-1'
  _valid_until="$(openssl x509 -noout -dates -in "${codesigning_cert}"| grep -Po 'notAfter=\K.*$' | date +%s -f -)"

  print_section_start "check_codesigning_cert" "Check codesigning cert"

  if (( ("$_now" + "$_ninety_days") > "$_valid_until" )); then
    printf "The codesigning certificate is only valid for less than 90 days!\n" >&2
    exit 1
  fi

  print_section_end "check_codesigning_cert"
}

copy_ipxe_binaries() {
  # copy ipxe binaries to output dir
  local _ipxe_base="/usr/share/ipxe"
  local _ipxe_output="${output}/ipxe"

  print_section_start "copy_ipxe" "Copy iPXE binaries"

  install -vdm 755 -- "${_ipxe_output}"
  cp -av -- "${_ipxe_base}/"{ipxe-arch.{lkrn,pxe},x86_64/ipxe-arch.efi} "${_ipxe_output}"

  print_section_end "copy_ipxe"
}

run_mkarchiso() {
  # run mkarchiso
  print_section_start "mkarchiso" "Running mkarchiso"

  mkdir -p "${output}/" "${tmpdir}/"
  GNUPGHOME="${gnupg_homedir}" mkarchiso \
      -D "${install_dir}" \
      -c "${codesigning_cert} ${codesigning_key}" \
      -g "${pgp_key_id}" \
      -o "${output}/" \
      -w "${tmpdir}/" \
      -m "iso netboot bootstrap" \
      -v "/usr/share/archiso/configs/releng/"

  print_section_end "mkarchiso"

  copy_ipxe_binaries
  create_zsync_delta "${output}/"*+(.iso|.tar|.gz|.xz|.zst)
  create_checksums "${output}/"*+(.iso|.tar|.gz|.xz|.zst) "${output}/ipxe/"*.{efi,lkrn,pxe}
  create_metrics

  print_section_start "ownership" "Setting ownership on output"

  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown -Rv "${SUDO_UID}:${SUDO_GID}" -- "${output}"
  fi
  print_section_end "ownership"
}

trap cleanup EXIT

if (( EUID != 0 )); then
    printf "%s must be run as root.\n" "${app_name}" >&2
    exit 1
fi

create_ephemeral_pgp_key
select_codesigning_key
check_codesigning_cert_validity
run_mkarchiso
