#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
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
# * python
# * python-jinja
# * python-orjson

set -eu
shopt -s extglob

readonly orig_pwd="${PWD}"
readonly output="${orig_pwd}/output"
readonly tmpdir_base="${orig_pwd}/tmp"
readonly install_dir="arch"
readonly app_name="${0##*/}"

tmpdir=""
tmpdir="$(mktemp --dry-run --directory --tmpdir="${tmpdir_base}")"
version="$(date +%Y.%m.%d)"
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

print_package_version_metric() {
  local _name="${1}" _description="${2}" _version=""

  if find "${tmpdir}" -type d -iwholename "*airootfs/var/lib/pacman/local/${_name}-*" >/dev/null; then
    _version=$(
      find "${tmpdir}" \
        -type d \
        -iwholename "*airootfs/var/lib/pacman/local/${_name}-[0-9,-]*" \
        -exec basename {} \; \
      | cut -d '-' --output-delimiter '-' -f2,3
    )
    printf 'version_info{name="%s",description="%s",version="%s"} 1\n' \
      "${_name}" "${_description}" "${_version}"
  fi
}

create_metrics() {
  local _metrics="${output}/metrics.txt"
  # create metrics
  print_section_start "metrics" "Creating metrics"

  {
    printf '# TYPE version_info info\n'
    printf 'version_info{name="archiso",description="Version of archiso used for build",version="%s"} 1\n' \
      "$(pacman -Q archiso |cut -d' ' -f2)"
    printf 'version_info{name="ipxe",description="Version of iPXE binaries",version="%s"} 1\n' \
      "$(pacman -Q ipxe |cut -d' ' -f2)"
    printf 'version_info{name="linux",description="Version of Linux used in image",version="%s"} 1\n' \
      "$(file "${output}/arch/boot/"*/vmlinuz-linux| cut -d',' -f2| awk '{print $2}')"

    print_package_version_metric "archinstall" "Version of archinstall used in image"
    print_package_version_metric "pacman" "Version of pacman used in image"
    print_package_version_metric "systemd" "Version of systemd used in image"

    printf '# TYPE artifact_bytes gauge\n'
    printf 'artifact_bytes{name="iso",description="Size of ISO"} %s\n' \
      "$(du -b -- "${output}/"*.iso | cut -f1)"
    if [[ -e "${tmpdir}/efiboot.img" ]]; then
      printf 'artifact_bytes{name="eltorito_efi_image",description="Size of El-Torito EFI Image"} %s\n' \
        "$(du -b -- "${tmpdir}/efiboot.img" | cut -f1)"
    fi
    printf 'artifact_bytes{name="initramfs",artifact="Size of initramfs"} %s\n' \
      "$(du -b -- "${tmpdir}/iso/"*/boot/*/initramfs*.img | cut -f1)"
    printf 'artifact_bytes{name="netboot",description="Size of netboot directory"} %s\n' \
      "$(du -bs -- "${output}/${install_dir}/" | cut -f1)"
    printf 'artifact_bytes{name="bootstrap",description="Size of compressed bootstrap rootfs"} %s\n' \
      "$(du -b -- "${output}/"*.tar*(.gz|.xz|.zst) | cut -f1)"

    printf '# TYPE data_count summary\n'
    printf 'data_count{name="iso",description="Number of packages in ISO"} %s\n' \
      "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
    printf 'data_count{name="netboot",description="Number of packages in netboot rootfs"} %s\n' \
      "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
    printf 'data_count{name="bootstrap",description="Number of packages in compressed bootstrap rootfs"} %s\n' \
      "$(sort -u -- "${tmpdir}/"*/bootstrap/root.*/pkglist.*.txt | wc -l)"
  } >"${_metrics}"
  # show metrics (without comments, as the '#' character is read as if this script finished)
  grep -v '#' "${_metrics}"

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

  pgp_sender="Arch Linux Release Engineering (Ephemeral Signing Key) <arch-releng@lists.archlinux.org>"

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
  local _ipxe_output="${output}/ipxe/ipxe-${version}"

  print_section_start "copy_ipxe" "Copy iPXE binaries"

  cp -av -- "${_ipxe_base}/"{ipxe-arch.{lkrn,pxe},x86_64/ipxe-arch.efi} "${_ipxe_output}"

  print_section_end "copy_ipxe"

  create_checksums "${_ipxe_output}/"*.{efi,lkrn,pxe}
}

move_build_artifacts() {
  print_section_start "move_build_artifacts" "Move build artifacts to release directories"

  mkdir -vp -- "${output}/bootstrap/bootstrap-${version}"
  mkdir -vp -- "${output}/iso/iso-${version}"
  mkdir -vp -- "${output}/netboot/netboot-${version}"
  mv -v -- "${output}/archlinux-bootstrap"* "${output}/bootstrap/bootstrap-${version}/"
  mv -v -- "${output}/archlinux-"*.iso* "${output}/iso/iso-${version}/"
  mv -v -- "${output}/${install_dir}/"* "${output}/netboot/netboot-${version}/"
  rmdir -v "${output}/${install_dir}/"

  print_section_end "move_build_artifacts"
}

set_ownership() {
  print_section_start "ownership" "Setting ownership on output"

  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown -Rv "${SUDO_UID}:${SUDO_GID}" -- "${output}"
  fi

  print_section_end "ownership"
}

run_mkarchiso() {
  # run mkarchiso
  print_section_start "mkarchiso" "Running mkarchiso"

  mkdir -p "${output}/" "${tmpdir}/"
  GNUPGHOME="${gnupg_homedir}" mkarchiso \
      -D "${install_dir}" \
      -c "${codesigning_cert} ${codesigning_key}" \
      -g "${pgp_key_id}" \
      -G "${pgp_sender}" \
      -o "${output}/" \
      -w "${tmpdir}/" \
      -m "iso netboot bootstrap" \
      -v "/usr/share/archiso/configs/releng/"

  print_section_end "mkarchiso"

  create_zsync_delta "${output}/"*+(.iso|.tar|.gz|.xz|.zst)
  create_checksums "${output}/"*+(.iso|.tar|.gz|.xz|.zst)
  create_metrics
  move_build_artifacts
}

generate_archlinux_ipxe() {
  # generate the archlinux.ipxe target script that is downloaded by the ipxe image
  print_section_start "generate_archlinux_ipxe" "Generating archlinux.ipxe image"

  local _ipxe_dir="${orig_pwd}/ipxe"
  local _ipxe_output="${output}/ipxe/ipxe-${version}"

  install -vdm 755 -- "${_ipxe_output}"
  python "${_ipxe_dir}/generate_archlinux_ipxe.py" > "${_ipxe_output}/archlinux.ipxe"

  create_checksums "${_ipxe_output}/archlinux.ipxe"

  print_section_end "generate_archlinux_ipxe"
}

sign_archlinux_ipxe() {
  # sign the archlinux.ipxe intermediate artifact
  print_section_start "sign_archlinux_ipxe" "Signing archlinux.ipxe image"

  local _ipxe_dir="${orig_pwd}/ipxe"
  local _ipxe_output="${output}/ipxe/ipxe-${version}"

  openssl cms \
      -sign \
      -binary \
      -noattr \
      -in "${_ipxe_output}/archlinux.ipxe" \
      -signer "${codesigning_cert}" \
      -inkey "${codesigning_key}" \
      -outform DER \
      -out "${_ipxe_output}/archlinux.ipxe.sig"

  print_section_end "sign_archlinux_ipxe"
}

trap cleanup EXIT

if (( EUID != 0 )); then
    printf "%s must be run as root.\n" "${app_name}" >&2
    exit 1
fi

create_ephemeral_pgp_key
select_codesigning_key
check_codesigning_cert_validity
generate_archlinux_ipxe
sign_archlinux_ipxe
run_mkarchiso
copy_ipxe_binaries
set_ownership
