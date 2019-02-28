#!/bin/ksh
#
# Copyright (c) 2015, 2016, 2019 Antoine Jacoutot <ajacoutot@openbsd.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e
umask 022

build_autoinstallconf()
{
	local _autoinstallconf=${_WRKDIR}/auto_install.conf

	cat <<-EOF >>${_autoinstallconf}
	System hostname = openbsd
	Password for root = *
	Change the default console to com0 = yes
	Setup a user = ec2-user
	Full name for user ec2-user = EC2 Default User 
	Password for user = *************
	What timezone are you in = UTC
	Location of sets = http
	HTTP Server = ${MIRROR}
	Server directory = pub/OpenBSD/${RELEASE}/amd64
	Set name(s) = done
	EOF

	# XXX if checksum fails
	for i in $(jot 11); do
	        echo "Checksum test for = yes" >>${_autoinstallconf}
	done
	echo "Continue without verification = yes" >>${_autoinstallconf}

	cat <<-'EOF' >>${_autoinstallconf}
	Location of sets = disk
	Is the disk partition already mounted = no
	Which disk contains the install media = sd1
	Which sd1 partition has the install sets = a
	Pathname to the sets = /
	INSTALL.amd64 not found. Use sets found here anyway = yes
	Set name(s) = site*
	Checksum test for = yes
	Continue without verification = yes
	EOF
}

create_img()
{
	local _amimg=${_WRKDIR}/ami.img _aminam=ami-${_WRKDIR##*/aws-ami.}
	local _bsdrd=${_WRKDIR}/bsd.rd

	create_install_site_disk

	build_autoinstallconf
	upobsd -V ${RELEASE} -a amd64 -i ${_WRKDIR}/auto_install.conf \
		-o ${_bsdrd}

	vmctl create ${_amimg} -s 10g

	(sleep 30 && vmctl wait ${_aminam} && vmctl stop ${_aminam} -f) &

	vmctl start ${_aminam} -b ${_bsdrd} -c -L \
		-d ${_amimg} -d ${_WRKDIR}/siteXX.img
	# XXX handle installation error
	# (e.g. ftp: raw.githubusercontent.com: no address associated with name)
}

create_install_site()
{
	# XXX
	# bsd.mp
	# https://cdn.openbsd.org/pub/OpenBSD in installurl if MIRROR ~= file:/

	cat <<-'EOF' >>${_WRKDIR}/install.site
	ftp -V -o /usr/local/libexec/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh
	chown root:bin /usr/local/libexec/ec2-init
	chmod 0555 /usr/local/libexec/ec2-init

	echo dhcp >/etc/hostname.xnf0

	echo "!/usr/local/libexec/ec2-init" >>/etc/hostname.vio0
	echo "!/usr/local/libexec/ec2-init" >>/etc/hostname.xnf0

	echo "sndiod_flags=NO" >/etc/rc.conf.local
	echo "permit keepenv nopass ec2-user" >/etc/doas.conf

	rm /install.site
	EOF

	chmod 0555 ${_WRKDIR}/install.site
}

create_install_site_disk()
{
	# XXX trap vnd and mount
	local _siteimg=${_WRKDIR}/siteXX.img _sitemnt=${_WRKDIR}/siteXX
	local _vndev="$(vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)"
	local _rel=$(uname -r)

	[[ -z ${_vndev} ]] && pr_err "${0##*/}: no vnd(4) device available"

	create_install_site

	vmctl create ${_siteimg} -s 1g
	vnconfig ${_vndev} ${_siteimg}
	fdisk -iy ${_vndev}
	echo "a a\n\n\n\nw\nq\n" | disklabel -E ${_vndev}
	newfs ${_vndev}a

	install -d ${_sitemnt}
	mount /dev/${_vndev}a ${_sitemnt}

	_rel=${_rel%.[0-9]}${_rel#[0-9].}
	cd ${_WRKDIR} && tar czf ${_sitemnt}/site${_rel}.tgz ./install.site
	# in case we're running an X.Y snapshot while X.Z is out;
	# (e.g. running on 6.4-current and installing 6.5-beta)
	let _rel++
	cd ${_WRKDIR} && tar czf ${_sitemnt}/site${_rel}.tgz ./install.site

	umount ${_sitemnt}
	vnconfig -u ${_vndev}
}

pr_err()
{
	echo "${1}" 1>&2 && return ${2:-1}
}

setup_forwarding()
{
	! ${NETCONF} && return 0

	if [[ $(sysctl -n net.inet.ip.forwarding) != 1 ]]; then
		RESET_FWD=true
		sysctl -q net.inet.ip.forwarding=1
	fi
}

setup_pf()
{
	! ${NETCONF} && return 0

	local _pfrules

	if ! $(pfctl -e >/dev/null); then
		RESET_PF=true
	fi
	print -- "pass out on egress from 100.64.0.0/10 to any nat-to (egress)
		  pass in proto { tcp, udp } from 100.64.0.0/10 to any port domain rdr-to 1.1.1.1" |
		pfctl -f -
}

setup_vmd()
{
	if ! $(rcctl check vmd >/dev/null); then
		rcctl start vmd >/dev/null
		RESET_VMD=true
	fi
}

trap_handler()
{
	set +e # we're trapped

	if ${RESET_VMD:-false}; then
		rcctl stop vmd >/dev/null
	fi

	if ${RESET_PF:-false}; then
		pfctl -d >/dev/null
		pfctl -F rules >/dev/null
	elif ${NETCONF}; then
		pfctl -f /etc/pf.conf
	fi

	if ${RESET_FWD:-false}; then
		sysctl -q net.inet.ip.forwarding=0
	fi
}

usage()
{
	pr_err "usage: ${0##*/}
       -c -- autoconfigure pf(4) and enable IP forwarding
       -m \"install mirror\" -- defaults to \"cdn.openbsd.org\"
       -r \"release\" -- e.g 6.0; default to snapshots"
}

trap 'trap_handler' EXIT
trap exit HUP INT TERM

while getopts cm:r: arg; do
	case ${arg} in
	c)	NETCONF=true ;;
	m)	MIRROR="${OPTARG}" ;;
	r)	RELEASE="${OPTARG}" ;;
	*)	usage ;;
	esac
done

# check for requirements
(($(id -u) != 0)) && pr_err "${0##*/}: need root privileges"
[[ $(uname -m) != amd64 ]] && pr_err "${0##*/}: only supports amd64"
[[ -z $(dmesg | grep ^vmm0 | tail -1) ]] &&
	pr_err "${0##*/}: need vmm(4) support"
which upobsd >/dev/null 2>&1 || pr_err "package \"upobsd\" is not installed"

_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} aws-ami.XXXXXXXXXX)
MIRROR=${MIRROR:-cdn.openbsd.org}
NETCONF=${NETCONF:-false}
RELEASE=${RELEASE:-snapshots}

setup_vmd
setup_pf
setup_forwarding
create_img
