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

# XXX script vmm(4) to create an "official" installation instead of the extract dance
# XXX ec2-delete-disk-image
# XXX function()alise
# XXX /etc/hostname.ix0?
# XXX obootstrap (KVM (vio0, sd0a)

_ARCH=$(uname -m)
_RELEASE=$(uname -r)
_DEPS="awscli ec2-api-tools jdk"

################################################################################

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
if [[ -z ${AWS_ACCESS_KEY_ID} || -z ${AWS_SECRET_ACCESS_KEY} ]]; then
	AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}
	AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}
fi
AWS_REGION=${AWS_REGION:=eu-west-1}
AWS_AZ=${AWS_AZ:=eu-west-1a}

MIRROR_ARCH=${_ARCH}
MIRROR_HOST=${MIRROR_HOST:=http://ftp.fr.openbsd.org}
MIRROR=${MIRROR_HOST}/pub/OpenBSD/snapshots/${MIRROR_ARCH}

DESCRIPTION="OpenBSD-current ${_ARCH}"
TIMESTAMP=$(date -u +%G%m%dT%H%M%SZ)

################################################################################

if [[ ${_ARCH} == amd64 ]]; then
	_ARCH=x86_64
elif [[ ${_ARCH} != i386 ]]; then
	echo "${0##*/}: only supports amd64 and i386"
	exit 1
fi

for _p in ${_DEPS}; do
	if ! pkg_info -qe ${_p}-*; then
		echo "${0##*/}: needs the ${_p} package"
		exit 1
	fi
done

if [[ $(doas ${RANDOM} 2>/dev/null) == 1 ]]; then
	echo "${0##*/}: needs doas(1) privileges"
	exit 1
fi

set -e
umask 022

usage() {
	echo "usage: ${0##*/} [-dinsr]" >&2
	echo "       -d \"$DESCRIPTION\"" >&2
	echo "       -i /path/to/image" >&2
	echo "       -n only create the RAW image (not the AMI)" >&2
	echo "       -s image/AMI size (in GB; default to 8)" >&2
	echo "       -r build released version (6.0|5.9)" >&2
	exit 1
}

create_img() {
	_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} aws-ami.XXXXXXXXXX)
	_IMG=${_WRKDIR}/openbsd-$TIMESTAMP
	local _LOG=${_WRKDIR}/log
	local _MNT=${_WRKDIR}/mnt
	local _REL=$(echo ${_RELEASE} | tr -d '.')
	local _VNDEV=$(doas vnconfig -l | grep 'not in use' | head -1 | cut -d ':' -f1)

	if [[ -z ${_VNDEV} ]]; then
		echo "${0##*/}: no vnd(4) device available"
		exit 1
	fi

	mkdir -p ${_MNT}
	touch ${_LOG}

	trap "cat ${_LOG}" ERR

	echo "===> creating image container"
	doas dd if=/dev/zero of=${_IMG} bs=1m count=$((${IMGSIZE}*1024)) \
		>${_LOG} 2>&1

	echo "===> creating image filesystem"
	doas vnconfig ${_VNDEV} ${_IMG} >${_LOG} 2>&1
	doas fdisk -iy ${_VNDEV} >${_LOG} 2>&1
	printf "a\n\n\n\n\nq\n\n" | doas disklabel -E ${_VNDEV} >${_LOG} 2>&1
	doas newfs /dev/r${_VNDEV}a >${_LOG} 2>&1

	echo "===> mounting image"
	doas mount /dev/${_VNDEV}a ${_MNT} >${_LOG} 2>&1

	echo "===> fetching sets from ${MIRROR}"
	( cd ${_WRKDIR} && \
		ftp -V ${MIRROR}/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_REL}.tgz} >${_LOG} 2>&1 )

	echo "===> fetching ec2-init"
	ftp -MV -o ${_WRKDIR}/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh

	echo "===> extracting sets"
	for i in ${_WRKDIR}/*${_REL}.tgz ${_MNT}/var/sysmerge/{,x}etc.tgz; do \
		doas tar xzphf $i -C ${_MNT} >${_LOG} 2>&1
	done

	echo "===> installing MP kernel"
	doas mv ${_WRKDIR}/bsd* ${_MNT} >${_LOG} 2>&1
	doas mv ${_MNT}/bsd ${_MNT}/bsd.sp >${_LOG} 2>&1
	doas mv ${_MNT}/bsd.mp ${_MNT}/bsd >${_LOG} 2>&1
	doas chown 0:0 ${_MNT}/bsd* >${_LOG} 2>&1

	echo "===> installing ec2-init"
	doas install -m 0555 -o root -g bin ${_WRKDIR}/ec2-init \
		${_MNT}/usr/local/libexec/ec2-init >${_LOG} 2>&1

	echo "===> removing downloaded files"
	rm ${_WRKDIR}/*${_REL}.tgz ${_WRKDIR}/ec2-init >${_LOG} 2>&1

	echo "===> creating devices"
	( cd ${_MNT}/dev && doas sh ./MAKEDEV all >${_LOG} 2>&1 )

	echo "===> storing entropy for the initial boot"
	doas dd if=/dev/random of=${_MNT}/var/db/host.random bs=65536 count=1 \
		status=none >${_LOG} 2>&1
	doas dd if=/dev/random of=${_MNT}/etc/random.seed bs=512 count=1 \
		status=none >${_LOG} 2>&1
	doas chmod 600 ${_MNT}/var/db/host.random ${_MNT}/etc/random.seed \
		>${_LOG} 2>&1

	echo "===> installing master boot record"
	doas installboot -r ${_MNT} ${_VNDEV} >${_LOG} 2>&1

	echo "===> configuring the image"
	echo "installpath = ${MIRROR_HOST:##*//}" | doas tee ${_MNT}/etc/pkg.conf >${_LOG} 2>&1
	echo "/dev/wd0a / ffs rw 1 1" | doas tee ${_MNT}/etc/fstab >${_LOG} 2>&1
	doas sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," ${_MNT}/etc/ttys >${_LOG} 2>&1
	echo "stty com0 9600" | doas tee ${_MNT}/etc/boot.conf >${_LOG} 2>&1
	echo "set tty com0" | doas tee -a ${_MNT}/etc/boot.conf >${_LOG} 2>&1
	echo "dhcp" | doas tee ${_MNT}/etc/hostname.xnf0 >${_LOG} 2>&1
	echo "!/usr/local/libexec/ec2-init" | \
		doas tee -a ${_MNT}/etc/hostname.xnf0 >${_LOG} 2>&1
	doas chmod 0640 ${_MNT}/etc/hostname.xnf0 >${_LOG} 2>&1
	echo "127.0.0.1\tlocalhost" | doas tee ${_MNT}/etc/hosts >${_LOG} 2>&1
	echo "::1\t\tlocalhost" | doas tee -a ${_MNT}/etc/hosts >${_LOG} 2>&1
	doas chroot ${_MNT} env -i ln -sf /usr/share/zoneinfo/UTC /etc/localtime \
		>${_LOG} 2>&1
	doas chroot ${_MNT} env -i ldconfig /usr/local/lib /usr/X11R6/lib >${_LOG} 2>&1
	doas chroot ${_MNT} env -i rcctl disable sndiod >${_LOG} 2>&1

	# XXX not technically needed
	#echo "===> removing cruft from the image"
	#doas rm /etc/random.seed /var/db/host.random
	doas rm -f ${_MNT}/etc/isakmpd/private/local.key \
		${_MNT}/etc/isakmpd/local.pub \
		${_MNT}/etc/iked/private/local.key \
		${_MNT}/etc/isakmpd/local.pub \
		${_MNT}/etc/ssh/ssh_host_* \
		${_MNT}/var/db/dhclient.leases.* >${_LOG} 2>&1
	doas rm -rf ${_MNT}/tmp/{.[!.],}* >${_LOG} 2>&1

	# XXX not technically needed
	#echo "===> disabling root password"
	doas chroot ${_MNT} env -i chpass -a \
		'root:*:0:0:daemon:0:0:Charlie &:/root:/bin/ksh' >${_LOG} 2>&1

	echo "===> unmounting the image"
	doas umount ${_MNT} >${_LOG} 2>&1
	doas vnconfig -u ${_VNDEV} >${_LOG} 2>&1

	echo "===> image available at:"
	echo "     ${_IMG}"
	echo

	trap - ERR
	rmdir ${_MNT} || true
	rm -f ${_LOG}
}

create_ami(){
	local _IMGNAME=${_IMG##*/}
	local _BUCKETNAME=${_IMGNAME}
	typeset -l _BUCKETNAME
	if ! ${CREATE_IMG}; then
		_IMGNAME=${_IMGNAME}-$TIMESTAMP
	fi
	local DESCRIPTION="${DESCRIPTION} ${_IMGNAME}"

	echo "===> uploading image to S3 at ${AWS_REGION} (takes some time)"
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
	echo "===> converting image to volume at ${AWS_REGION} (takes some time)"
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
	#rm -rf ${_WRKDIR}
	#ec2-delete-disk-image

	echo
	echo "===> creating snapshot at ${AWS_REGION} (takes some time)"
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
	echo "===> registering new AMI at ${AWS_REGION}: ${_IMGNAME}"
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

CREATE_AMI=true
CREATE_IMG=true
IMGSIZE=8
while getopts d:i:ns:r: arg; do
	case ${arg} in
	d)	DESCRIPTION="${OPTARG}";;
	i)	CREATE_IMG=false; _IMG="${OPTARG}";;
	n)	CREATE_AMI=false;;
	s)	IMGSIZE="${OPTARG}";;
	r)  _RELEASE="${OPTARG}"; MIRROR=${MIRROR_HOST}/pub/OpenBSD/${_RELEASE}/${MIRROR_ARCH}; DESCRIPTION="OpenBSD ${_RELEASE} ${_ARCH}";;
	*)	usage;;
	esac
done

if ${CREATE_IMG}; then
	create_img
elif [[ ! -f ${_IMG} ]]; then
	echo "${0##*/}: ${_IMG} does not exist"
	exit 1
fi

if ${CREATE_AMI}; then
	if [[ -z ${AWS_ACCESS_KEY_ID} || -z ${AWS_SECRET_ACCESS_KEY} ]]; then
		echo "${0##*/}: AWS credentials aren't set"
		exit 1
	fi
	if [[ -z ${EC2_HOME} ]]; then
		echo "${0##*/}: EC2_HOME is not set; export EC2_HOME=/usr/local/ec2-api-tools"
		exit 1
	else
		export PATH=${EC2_HOME}/bin:$PATH
	fi
	if [[ -z ${JAVA_HOME} ]]; then
		echo "${0##*/}: JAVA_HOME is not set; export JAVA_HOME=/usr/local/jdk-1.7.0"
		exit 1
	else
		export PATH=${JAVA_HOME}/bin:$PATH
	fi
	if ! type ec2-import-volume >/dev/null; then
		echo "${0##*/}: needs the EC2 CLI tools"
		exit 1
	fi
	create_ami
fi
