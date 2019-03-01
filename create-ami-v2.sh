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

aws_create_ami() {
	local _progress _snap _state _v _vol _volids _volids_new
	local _vmdkpath=${IMGPATH}.vmdk

	pr_action "converting image to stream-based VMDK"
	vmdktool -v ${_vmdkpath} ${IMGPATH}

	pr_action "uploading image to S3 and converting to volume in az ${AWS_AZ}"
	_volids="$(volume_ids)"
	ec2-import-volume \
		${_vmdkpath} \
		-f vmdk \
		--region ${AWS_REGION} \
		-z ${AWS_AZ} \
		-d ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		-o "${AWS_ACCESS_KEY_ID}" \
		-w "${AWS_SECRET_ACCESS_KEY}" \
		-b ${_IMGNAME}

	_volids_new="$(volume_ids)"
	echo
	while [[ ${_volids} == ${_volids_new} ]]; do
		sleep 10
		_volids_new="$(volume_ids)"
	done
	_vol=$(for _v in ${_volids_new}; do echo "${_volids}" | fgrep -q $_v ||
		echo $_v; done)

	pr_action "waiting for completed conversion of volume for ${_vol}"
	while /usr/bin/true; do
		_state="$(volume_state ${_vol})"
		[[ ${_state} == completed ]] && break
		[[ ${_state} == active ]] && _progress="$(volume_progress ${_vol})"
		[[ -n ${_progress} ]] && echo "${_progress}"
		sleep 10
	done

	# XXX
	#echo
	#echo "deleting local and remote disk images"
	#rm -rf ${_WRKDIR}
	#ec2-delete-disk-image

	pr_action "creating snapshot in region ${AWS_REGION}"
	ec2-create-snapshot \
	       -O "${AWS_ACCESS_KEY_ID}" \
	       -W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-d ${_IMGNAME} \
		${_vol}
	while [[ -z ${_snap} ]]; do
		_snap=$(ec2-describe-snapshots \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null |
			grep "${_vol}" |
			grep "completed.*${_IMGNAME}" |
			grep -Eo "snap-[[:alnum:]]*") || true
		sleep 10
	done

	pr_action "registering new AMI in region ${AWS_REGION}: ${_IMGNAME}"
	ec2-register \
		-n ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-a x86_64 \
		-d "${DESCR}" \
		--root-device-name /dev/sda1 \
		--virtualization-type hvm \
		-s ${_snap}
}

aws_volume_ids()
{
	aws --region ${AWS_REGION} --output json ec2 describe-conversion-tasks |
		python2 -c 'from __future__ import print_function;import sys,json; [print(task["ImportVolume"]["Volume"]["Id"]) if "Id" in task["ImportVolume"]["Volume"] else None for task in json.load(sys.stdin)["ConversionTasks"]]'
}

aws_volume_progress()
{
	local _vol=$1
	aws --region ${AWS_REGION} --output json ec2 describe-conversion-tasks |
		python2 -c 'from __future__ import print_function;import sys,json; [print(task["ImportVolume"]["Volume"]["Id"],task["StatusMessage"]) if ("Id" in task["ImportVolume"]["Volume"] and "StatusMessage" in task) else None for task in json.load(sys.stdin)["ConversionTasks"]]' |
		grep "${_vol}" | awk '{print $2,$3}'
}

aws_volume_state()
{
	local _vol=$1
	aws --region ${AWS_REGION} --output json ec2 describe-conversion-tasks |
		python2 -c 'from __future__ import print_function;import sys,json; [print(task["ImportVolume"]["Volume"]["Id"],task["State"]) if "Id" in task["ImportVolume"]["Volume"] else None for task in json.load(sys.stdin)["ConversionTasks"]]' |
		grep "${_vol}" | awk '{print $NF}'
}

build_autoinstallconf()
{
	local _autoinstallconf=${_WRKDIR}/auto_install.conf

	cat <<-EOF >>${_autoinstallconf}
	System hostname = openbsd
	Password for root = *************
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
	create_install_site_disk

	build_autoinstallconf
	upobsd -V ${RELEASE} -a amd64 -i ${_WRKDIR}/auto_install.conf \
		-o ${_WRKDIR}/bsd.rd

	vmctl create ${IMGPATH} -s ${IMGSIZE}G

	(sleep 30 && vmctl wait ${_IMGNAME} && vmctl stop ${_IMGNAME} -f) &

	vmctl start ${_IMGNAME} -b ${_WRKDIR}/bsd.rd -c -L -d ${IMGPATH} -d \
		${_WRKDIR}/siteXX.img
	# XXX handle installation error
	# (e.g. ftp: raw.githubusercontent.com: no address associated with name)
}

create_install_site()
{
	# XXX
	# bsd.mp + relink directory
	# https://cdn.openbsd.org/pub/OpenBSD in installurl if MIRROR ~= file:/
	# proxy support

	cat <<-'EOF' >>${_WRKDIR}/install.site
	ftp -V -o /usr/local/libexec/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh
	chown root:bin /usr/local/libexec/ec2-init
	chmod 0555 /usr/local/libexec/ec2-init

	echo "!/usr/local/libexec/ec2-init" >>/etc/hostname.vio0
	cp -p /etc/hostname.vio0 /etc/hostname.xnf0

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

	vmctl create ${_siteimg} -s 1G
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

	if [[ -n ${_WRKDIR} ]]; then
		rmdir ${_WRKDIR} 2>/dev/null ||
			echo "Work directory: ${_WRKDIR}"
	fi
}

usage()
{
	pr_err "usage: ${0##*/}
       -c -- autoconfigure pf(4) and enable IP forwarding
       -d -- AMI description; defaults to \"openbsd-\$release-\$timestamp\"
       -i \"path to RAW image\" -- use image at path instead of creating one
       -m \"install mirror\" -- defaults to \"cdn.openbsd.org\"
       -n -- only create a RAW image (don't convert to an AMI and push to AWS)
       -r \"release\" -- e.g 6.5; default to \"snapshots\"
       -s \"image size in GB\" -- default to \"10\""
}

while getopts cd:i:m:nr:s: arg; do
	case ${arg} in
	c)	NETCONF=true ;;
	d)	DESCR="${OPTARG}" ;;
	i)	IMGPATH="${OPTARG}" ;;
	m)	MIRROR="${OPTARG}" ;;
	n)	CREATE_AMI=false ;;
	r)	RELEASE="${OPTARG}" ;;
	s)	IMGSIZE="${OPTARG}" ;;
	*)	usage ;;
	esac
done

trap 'trap_handler' EXIT
trap exit HUP INT TERM

_TS=$(date -u +%G%m%dT%H%M%SZ)
_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} aws-ami.XXXXXXXXXX)
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY}}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_KEY}}
AWS_REGION=${AWS_REGION:-eu-west-1}
AWS_AZ=${AWS_AZ:-${AWS_REGION}a}
CREATE_AMI=${CREATE_AMI:-true}
IMGSIZE=${IMGSIZE:-10}
MIRROR=${MIRROR:-cdn.openbsd.org}
NETCONF=${NETCONF:-false}
RELEASE=${RELEASE:-snapshots}
_IMGNAME=openbsd-${RELEASE}-amd64-${_TS}
! [[ ${RELEASE} == snapshots ]] ||
	_IMGNAME=${_IMGNAME%snapshots*}current${_IMGNAME#*snapshots}
! [[ -z ${IMGPATH} ]] || IMGPATH=${_WRKDIR}/${_IMGNAME}
DESCR=${DESCR:-${_IMGNAME}}

readonly AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_AZ
readonly _IMGNAME _TS _WRKDIR
readonly CREATE_AMI DESCR IMGPATH IMGSIZE MIRROR NETCONF RELEASE

if [[ ! -f ${IMGPATH} ]]; then
	(($(id -u) != 0)) && pr_err "${0##*/}: need root privileges"
	[[ $(uname -m) != amd64 ]] && pr_err "${0##*/}: only supports amd64"
	[[ -z $(dmesg | grep ^vmm0 | tail -1) ]] &&
		pr_err "${0##*/}: need vmm(4) support"
	type upobsd >/dev/null 2>&1 ||
		pr_err "${0##*/}: package \"upobsd\" is not installed"
	setup_vmd
	setup_pf
	setup_forwarding
	create_img
fi

if ${CREATE_AMI}; then
	[[ -n ${AWS_ACCESS_KEY_ID} && -n ${AWS_SECRET_ACCESS_KEY} ]] ||
		pr_err "${0##*/}: AWS credentials aren't set
(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
	# XXX seems the aws cli does more checking on the image than the ec2
	# tools, preventing creating an OpenBSD AMI; so we need java for now :-(
	[[ -n ${JAVA_HOME} ]] ||
		export JAVA_HOME=$(javaPathHelper -h ec2-api-tools) 2>/dev/null
	[[ -n ${EC2_HOME} ]] || export EC2_HOME=/usr/local/ec2-api-tools
	type ec2-import-volume >/dev/null 2>&1 ||
		export PATH=${EC2_HOME}/bin:${PATH}
	type ec2-import-volume >/dev/null 2>&1 ||
		pr_err "${0##*/}: package \"ec2-api-tools\" is not installed"
	type vmdktool >/dev/null 2>&1 ||
		pr_err "${0##*/}: package \"vmdktool\" is not installed"
	export _JAVA_OPTIONS=-Djava.io.tmpdir=${_WRKDIR}
	aws_create_ami
fi
