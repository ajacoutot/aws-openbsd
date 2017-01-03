#!/bin/sh
#
# Copyright (c) 2015, 2016 Antoine Jacoutot <ajacoutot@openbsd.org>
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
#
# create an OpenBSD image and AMI for AWS

set -e
umask 022

AWSCLI_ARGS=${AWSCLI_ARGS:=} # region, az
INSTALLPATH=${INSTALLPATH:=https://ftp.fr.openbsd.org}

check_req()
{
	[[ $(doas ${RANDOM} 2>/dev/null) == 1 ]] &&
		p_err "needs doas(1) privileges"

	[[ ${_ARCH} != @(amd64|i386) ]] &&
		p_err "only supports amd64 and i386"

	if ${CREATE_AMI}; then
		aws --version 2>/dev/null ||
			p_err "AWS CLI tools are not installed, pkg_add awscli"
		aws ec2 describe-instances >/dev/null ||
			p_err "cannot connect to AWS, check your credentials"
	fi

	_VNDEV=$(doas vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)
	[[ -z ${_VNDEV} ]] &&
		p_err "no vnd(4) device available"
}

create_img() {
	local _mnt=${_TMP}/mnt _rel=${RELEASE:-$(uname -r)}
	_rel=${_rel%\.*}${_rel#*\.}

	_IMG=${_TMP}/openbsd-${RELEASE:-current}-${_ARCH}-${_TIMESTAMP}

	install -d ${_mnt}

	echo "===> creating image container and filesystem"
	vmctl create ${_IMG} -s ${IMGSIZE}G
	doas vnconfig ${_VNDEV} ${_IMG}
	doas fdisk -iy ${_VNDEV}
	printf "a\n\n\n\n\nq\n\n" | doas disklabel -E ${_VNDEV}
	doas newfs /dev/r${_VNDEV}a
	doas mount /dev/${_VNDEV}a ${_mnt}

	echo "===> installing kernel and sets from ${INSTALLPATH:##*//}"
	( cd ${_TMP} &&
		ftp -V ${INSTALLPATH}/pub/OpenBSD/${RELEASE:-snapshots}/${_ARCH}/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_rel}.tgz}
	)
	for i in ${_TMP}/*${_rel}.tgz ${_mnt}/var/sysmerge/{,x}etc.tgz; do \
		doas tar xzphf $i -C ${_mnt}
	done
	doas mv ${_TMP}/bsd* ${_mnt}
	doas mv ${_mnt}/bsd ${_mnt}/bsd.sp
	doas mv ${_mnt}/bsd.mp ${_mnt}/bsd
	doas chown 0:0 ${_mnt}/bsd*
	rm ${_TMP}/*${_rel}.tgz

	echo "===> installing ec2-init"
	ftp -V -o ${_TMP}/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh
	doas install -m 0555 -o root -g bin ${_TMP}/ec2-init \
		${_mnt}/usr/local/libexec/ec2-init
	rm ${_TMP}/ec2-init

	echo "===> creating devices and installing master boot record"
	( cd ${_mnt}/dev && doas sh ./MAKEDEV all )
	doas installboot -r ${_mnt} ${_VNDEV}

	echo "===> configuring and unmounting the image"
	doas dd if=/dev/random of=${_mnt}/var/db/host.random bs=65536 count=1 \
		status=none
	doas dd if=/dev/random of=${_mnt}/etc/random.seed bs=512 count=1 \
		status=none
	doas chmod 600 ${_mnt}/var/db/host.random ${_mnt}/etc/random.seed
	if [[ ! -d ${INSTALLPATH:##*//} ]]; then
		echo "installpath = ${INSTALLPATH:##*//}" |
			doas tee ${_mnt}/etc/pkg.conf >/dev/null
	fi
	echo "$(doas disklabel vnd0 | grep duid | cut -d ' ' -f 2).a / ffs rw 1 1" |
		doas tee ${_mnt}/etc/fstab >/dev/null
	doas sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," \
		${_mnt}/etc/ttys
	echo "stty com0 9600" | doas tee ${_mnt}/etc/boot.conf >/dev/null
	echo "set tty com0" | doas tee -a ${_mnt}/etc/boot.conf >/dev/null
	echo "dhcp" | doas tee ${_mnt}/etc/hostname.xnf0 >/dev/null
	echo "!/usr/local/libexec/ec2-init" |
		doas tee -a ${_mnt}/etc/hostname.xnf0 >/dev/null
	doas chmod 0640 ${_mnt}/etc/hostname.xnf0
	echo "127.0.0.1\tlocalhost" | doas tee ${_mnt}/etc/hosts >/dev/null
	echo "::1\t\tlocalhost" | doas tee -a ${_mnt}/etc/hosts >/dev/null
	doas chroot ${_mnt} env -i ln -sf /usr/share/zoneinfo/UTC /etc/localtime
	doas chroot ${_mnt} env -i ldconfig /usr/local/lib /usr/X11R6/lib
	doas chroot ${_mnt} env -i rcctl disable sndiod
	doas rm -rf ${_mnt}/tmp/{.[!.],}*
	doas umount ${_mnt}
	doas vnconfig -u ${_VNDEV}

	echo "===> image available at:"
	echo "     ${_IMG}"
	echo

	rmdir ${_mnt}
}

p_err()
{
	echo "${1}" 1>&2 && return ${2:-1}
}

usage() {
	p_err "usage: ${0##*/} [-d | -i | -n | -r | -s]"
}

_ARCH=$(uname -m)
_TIMESTAMP=$(date -u +%G%m%dT%H%M%SZ)
_TMP=$(mktemp -d -p ${TMPDIR:=/tmp} aws-openbsd-ami-creator.XXXXXXXXXX)

# XXX trap rm -rf ${_TMP}

check_req

CREATE_AMI=true
CREATE_IMG=true
while getopts d:i:nr:s: arg; do
	case ${arg} in
	d)	DESCR="${OPTARG}";;
	i)	CREATE_IMG=false; _IMG="${OPTARG}";;
	n)	CREATE_AMI=false;;
	r)	REL="${OPTARG}";;
	s)	IMGSIZE="${OPTARG}";;
	*)	usage;;
	esac
done

[[ -z ${REL} ]] && REL=current
[[ -z ${DESCR} ]] && DESCR="OpenBSD ${RELEASE} ${_ARCH} ${__TIMESTAMP}"
[[ -z ${IMGSIZE} ]] && IMGSIZE=8














create_ami(){
	local _IMGNAME=${_IMG##*/}
	local _BUCKETNAME=${_IMGNAME}
	typeset -l _BUCKETNAME

	[[ -n ${DESCRIPTION} ]] || \
		local DESCRIPTION="OpenBSD ${RELEASE:-current} ${_ARCH} ${_TIMESTAMP}"

	echo "===> uploading image to S3 (can take some time)"
	ec2-import-volume \
		${_IMG} \
		-f RAW \
		--region ${AWS_REGION} \
		-z ${AWS_AZ} \
		-s ${IMGSIZE} \
		-d ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		-o "${AWS_ACCESS_KEY_ID}" \
		-w "${AWS_SECRET_ACCESS_KEY}" \
		-b ${_BUCKETNAME}

	echo
	echo "===> converting image to volume in region ${AWS_REGION} (can take some time)"
	while [[ -z ${_VOL} ]]; do
		_VOL=$(ec2-describe-conversion-tasks \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null | \
			grep "${_IMGNAME}" | \
			grep -Eo "vol-[[:alnum:]]*") || true
		sleep 10
	done

	#echo
	#echo "===> deleting local and remote disk images"
	#rm -rf ${_TMP}
	#ec2-delete-disk-image

	echo
	echo "===> creating snapshot n region ${AWS_REGION} (can take some time)"
	ec2-create-snapshot \
	       -O "${AWS_ACCESS_KEY_ID}" \
	       -W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-d ${_IMGNAME} \
		${_VOL}
	while [[ -z ${_SNAP} ]]; do
		_SNAP=$(ec2-describe-snapshots \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null | \
			grep "completed.*${_IMGNAME}" | \
			grep -Eo "snap-[[:alnum:]]*") || true
		sleep 10
	done

	echo
	echo "===> registering new AMI in region ${AWS_REGION}: ${_IMGNAME}"
	if [[ "${_ARCH}" == "amd64" ]]; then
		local _ARCH=x86_64
	fi
	ec2-register \
		-n ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-a ${_ARCH} \
		-d "${DESCRIPTION}" \
		--root-device-name /dev/sda1 \
		--virtualization-type hvm \
		-s ${_SNAP}
}

if ${CREATE_IMG}; then
	create_img
elif [[ ! -f ${_IMG} ]]; then
	echo "${0##*/}: ${_IMG} does not exist"
	exit 1
fi

if ${CREATE_AMI}; then
	create_ami
fi
