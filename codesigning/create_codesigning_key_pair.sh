#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This script creates a codesigning key pair and copies the resulting certificate and key to the directory specified by
# the first argument to this script (else $PWD)

set -euo pipefail

temp_dir="$(mktemp -d --tmpdir codesigning.XXXXXXXXXXXXX)"

readonly codesigning_subj="/C=DE/ST=Berlin/L=Berlin/O=Arch Linux/OU=Release Engineering/CN=archlinux.org"
readonly codesigning_cert="${temp_dir}/codesign.crt"
readonly codesigning_key="${temp_dir}/codesign.key"
readonly codesigning_conf="${temp_dir}/openssl.cnf"
readonly output_dir="${1:-$PWD}"

cleanup() {
  rm -fr "${temp_dir}"
}

generate_ca() {
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
}

copy_certs() {
  local _output_dir
  if [[ -d "${output_dir}" ]]; then
      _output_dir="${output_dir}"
  else
      _output_dir="${PWD}"
  fi
  cp -- "${codesigning_cert}" "${codesigning_key}" "${_output_dir}"
}

trap cleanup EXIT
generate_ca
copy_certs
