#!/usr/bin/env bash

python generate_archlinux_ipxe.py > archlinux.ipxe
curl https://ipxe.archlinux.org/releng/netboot/archlinux.ipxe > archweb-archlinux.ipxe

diff archweb-archlinux.ipxe archlinux.ipxe
