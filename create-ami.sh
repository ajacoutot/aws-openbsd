#!/bin/ksh
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

################################################################################

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:=${AWS_ACCESS_KEY}}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:=${AWS_SECRET_KEY}}
AWS_REGION=${AWS_REGION:=eu-west-1}
AWS_AZ=${AWS_AZ:=eu-west-1a}

MIRROR=${MIRROR:=https://ftp.fr.openbsd.org}

TIMESTAMP=$(date -u +%G%m%dT%H%M%SZ)

################################################################################

if [[ $(uname -m) != amd64 ]]; then
	echo "${0##*/}: only supports amd64"
	exit 1
fi

if [[ $(doas ${RANDOM} 2>/dev/null) == 1 ]]; then
	echo "${0##*/}: needs doas(1) privileges"
	exit 1
fi

usage() {
	echo "usage: ${0##*/}" >&2
	echo "       -d \"description\"" >&2
	echo "       -i \"/path/to/image\"" >&2
	echo "       -n only create the RAW image (not the AMI)" >&2
	echo "       -p pause before unmounting image to allow manual configuring" >&2
	echo "       -r \"release\" (e.g 6.0; default to current)" >&2
	exit 1
}

pr_action() {
	echo "========================================================================="
	echo "| ${1}"
	echo "========================================================================="
}

create_img() {
	_WRKDIR=$(mktemp -d -p ${TMPDIR:=/tmp} aws-ami.XXXXXXXXXX)
	_IMG=${_WRKDIR}/openbsd-${RELEASE:-current}-amd64-${TIMESTAMP}
	local _MNT=${_WRKDIR}/mnt _REL=${RELEASE:-$(uname -r)} _p
	local _VNDEV=$(doas vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)
	_REL=$(echo ${_REL} | tr -d '.')

	if [[ -z ${_VNDEV} ]]; then
		echo "${0##*/}: no vnd(4) device available"
		exit 1
	fi

	mkdir -p ${_MNT}

	pr_action "creating image container"
	vmctl create ${_IMG} -s 4G

	# matches >7G disklabel(8) automatic allocation minimum sizes (and not
	# disklabel -Aw ${_VNDEV}) except for /var (80M->256M) (to accomodate
	# syspatch(8)); we hardcode a 4G image because it's easy to extend /home
	# if we need more space for specialized usage (or even add a new EBS)
	pr_action "creating and mounting image filesystem"
	doas vnconfig ${_VNDEV} ${_IMG}
	doas fdisk -c 522 -h 255 -s 63 -yi ${_VNDEV}
	cat <<'EOF' >${_WRKDIR}/disklabel
type: SCSI
disk: SCSI disk
label: EC2 root device
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 522
total sectors: 8388608
boundstart: 64
boundend: 8385930

16 partitions:
#                size           offset  fstype [fsize bsize   cpg]
  a:           176640               64  4.2BSD   2048 16384     1 
  b:           160661           176704    swap                    
  c:          8388608                0  unused                    
  d:           257024           337376  4.2BSD   2048 16384     1 
  e:           514080           594400  4.2BSD   2048 16384     1 
  f:          1831392          1108480  4.2BSD   2048 16384     1 
  g:          1044224          2939872  4.2BSD   2048 16384     1 
  h:          4192960          3984096  4.2BSD   2048 16384     1 
  i:           211552          8177056  4.2BSD   2048 16384     1
EOF
	doas disklabel -R ${_VNDEV} ${_WRKDIR}/disklabel
	for _p in a d e f g h i; do
		doas newfs /dev/r${_VNDEV}${_p}
	done
	doas mount /dev/${_VNDEV}a ${_MNT}
	doas install -d ${_MNT}/{tmp,var,usr,home}
	doas mount /dev/${_VNDEV}d ${_MNT}/tmp
	doas mount /dev/${_VNDEV}e ${_MNT}/var
	doas mount /dev/${_VNDEV}f ${_MNT}/usr
	doas install -d ${_MNT}/usr/{X11R6,local}
	doas mount /dev/${_VNDEV}g ${_MNT}/usr/X11R6
	doas mount /dev/${_VNDEV}h ${_MNT}/usr/local
	doas mount /dev/${_VNDEV}i ${_MNT}/home

	pr_action "fetching sets from ${MIRROR:##*//}"
	( cd ${_WRKDIR} &&
		ftp -V ${MIRROR}/pub/OpenBSD/${RELEASE:-snapshots}/amd64/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_REL}.tgz} )

	pr_action "fetching ec2-init"
	ftp -V -o ${_WRKDIR}/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh

	pr_action "extracting sets"
	for i in ${_WRKDIR}/*${_REL}.tgz ${_MNT}/var/sysmerge/{,x}etc.tgz; do
		doas tar xzphf $i -C ${_MNT}
	done

	pr_action "installing MP kernel"
	doas mv ${_WRKDIR}/bsd* ${_MNT}
	doas mv ${_MNT}/bsd ${_MNT}/bsd.sp
	doas mv ${_MNT}/bsd.mp ${_MNT}/bsd
	doas chown 0:0 ${_MNT}/bsd*

	pr_action "installing ec2-init"
	doas install -m 0555 -o root -g bin ${_WRKDIR}/ec2-init \
		${_MNT}/usr/local/libexec/ec2-init

	pr_action "removing downloaded files"
	rm ${_WRKDIR}/*${_REL}.tgz ${_WRKDIR}/ec2-init

	pr_action "creating devices"
	( cd ${_MNT}/dev && doas sh ./MAKEDEV all )

	pr_action "storing entropy for the initial boot"
	doas dd if=/dev/random of=${_MNT}/var/db/host.random bs=65536 count=1 \
		status=none
	doas dd if=/dev/random of=${_MNT}/etc/random.seed bs=512 count=1 \
		status=none
	doas chmod 600 ${_MNT}/var/db/host.random ${_MNT}/etc/random.seed

	pr_action "installing master boot record"
	doas installboot -r ${_MNT} ${_VNDEV}

	pr_action "configuring the image"
	# XXX hardcoded
	echo "https://ftp.fr.openbsd.org/pub/OpenBSD" | doas tee \
		${_MNT}/etc/installurl
	_duid=$(doas disklabel ${_VNDEV} | grep duid | cut -d ' ' -f 2)
	echo "${_duid}.b none swap sw" | doas tee ${_MNT}/etc/fstab
	echo "${_duid}.a / ffs rw 1 1" | doas tee -a ${_MNT}/etc/fstab
	echo "${_duid}.i /home ffs rw,nodev,nosuid 1 2" | doas tee -a \
		${_MNT}/etc/fstab
	echo "${_duid}.d /tmp ffs rw,nodev,nosuid 1 2" | doas tee -a \
		${_MNT}/etc/fstab
	echo "${_duid}.f /usr ffs rw,nodev 1 2" | doas tee -a ${_MNT}/etc/fstab
	echo "${_duid}.g /usr/X11R6 ffs rw,nodev 1 2" | doas tee -a \
		${_MNT}/etc/fstab
	echo "${_duid}.h /usr/local ffs rw,wxallowed,nodev 1 2" | doas tee -a \
		${_MNT}/etc/fstab
	echo "${_duid}.e /var ffs rw,nodev,nosuid 1 2" | doas tee -a \
		${_MNT}/etc/fstab
	doas sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," \
		${_MNT}/etc/ttys
	echo "stty com0 9600" | doas tee ${_MNT}/etc/boot.conf
	echo "set tty com0" | doas tee -a ${_MNT}/etc/boot.conf
	echo "dhcp" | doas tee ${_MNT}/etc/hostname.xnf0
	echo "!/usr/local/libexec/ec2-init" |
		doas tee -a ${_MNT}/etc/hostname.xnf0
	doas chmod 0640 ${_MNT}/etc/hostname.xnf0
	echo "127.0.0.1\tlocalhost" | doas tee ${_MNT}/etc/hosts
	echo "::1\t\tlocalhost" | doas tee -a ${_MNT}/etc/hosts
	doas chroot ${_MNT} env -i ln -sf /usr/share/zoneinfo/UTC /etc/localtime
	doas chroot ${_MNT} env -i ldconfig /usr/local/lib /usr/X11R6/lib
	doas chroot ${_MNT} env -i rcctl disable sndiod

#	cat <<'EOF' | doas tee ${_MNT}/etc/hotplugd/attach
##!/bin/sh
#
#case $1 in
#	3) /sbin/dhclient -i routers $2 ;;
#esac
#EOF
#	doas chmod 0555 ${_MNT}/etc/hotplugd/attach
#	doas chroot ${_MNT} env -i rcctl enable hotplugd

	[[ $PAUSE = true ]] && {
		echo -n Do manual configuring under ${_MNT} then hit ENTER to continue.
		read
	}
        
	pr_action "unmounting the image"
	doas umount ${_MNT}/usr/X11R6
	doas umount ${_MNT}/usr/local
	doas umount ${_MNT}/usr
	doas umount ${_MNT}/var
	doas umount ${_MNT}/home
	doas umount ${_MNT}/tmp
	doas umount ${_MNT}
	doas vnconfig -u ${_VNDEV}

	pr_action "image available at: ${_IMG}"

	rm -r ${_MNT} || true
}

create_ami() {
	local _IMGNAME=${_IMG##*/}
	local _BUCKETNAME=${_IMGNAME}
	typeset -l _BUCKETNAME
	[[ -z ${TMPDIR} ]] || export _JAVA_OPTIONS=-Djava.io.tmpdir=${TMPDIR}
	[[ -z ${http_proxy} ]] || {
		local host_port=${http_proxy##*/}
		export EC2_JVM_ARGS="-Dhttps.proxyHost=${host_port%%:*} \
			-Dhttps.proxyPort=${host_port##*:}"
	}

	if [[ -z ${DESCRIPTION} ]]; then
		local DESCRIPTION="OpenBSD ${RELEASE:-current} amd64"
		[[ -n ${RELEASE} ]] ||
			DESCRIPTION="${DESCRIPTION} ${TIMESTAMP}"
	fi

	pr_action "uploading image to S3 in region ${AWS_REGION}"
	ec2-import-volume \
		${_IMG} \
		-f RAW \
		--region ${AWS_REGION} \
		-z ${AWS_AZ} \
		-s 4 \
		-d ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		-o "${AWS_ACCESS_KEY_ID}" \
		-w "${AWS_SECRET_ACCESS_KEY}" \
		-b ${_BUCKETNAME}

	echo
	pr_action "converting image to volume in region ${AWS_REGION}"
	while [[ -z ${_VOL} ]]; do
		_VOL=$(ec2-describe-conversion-tasks \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null |
			grep "${_IMGNAME}" |
			grep -Eo "vol-[[:alnum:]]*") || true
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
		${_VOL}
	while [[ -z ${_SNAP} ]]; do
		_SNAP=$(ec2-describe-snapshots \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null |
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
		-d "${DESCRIPTION}" \
		--root-device-name /dev/sda1 \
		--virtualization-type hvm \
		-s ${_SNAP}
}

CREATE_AMI=true
CREATE_IMG=true
PAUSE=false
while getopts d:i:npr: arg; do
	case ${arg} in
	d)	DESCRIPTION="${OPTARG}";;
	i)	CREATE_IMG=false; _IMG="${OPTARG}";;
	n)	CREATE_AMI=false;;
	p)	PAUSE=true;;
	r)	RELEASE="${OPTARG}";;
	*)	usage;;
	esac
done

if ${CREATE_AMI}; then
	if [[ -z ${AWS_ACCESS_KEY_ID} || -z ${AWS_SECRET_ACCESS_KEY} ]]; then
		echo "${0##*/}: AWS credentials aren't set"
		exit 1
	fi
	[[ -n ${JAVA_HOME} ]] ||
		export JAVA_HOME=$(javaPathHelper -h ec2-api-tools) 2>/dev/null
	[[ -n ${EC2_HOME} ]] || export EC2_HOME=/usr/local/ec2-api-tools
	which ec2-import-volume >/dev/null 2>&1 ||
		export PATH=${EC2_HOME}/bin:${PATH}
	# XXX seems the aws cli does more checking on the image than the ec2
	# tools, preventing creating an OpenBSD AMI; so we need java for now :-(
	if ! type ec2-import-volume >/dev/null; then
		echo "${0##*/}: needs the EC2 CLI tools (\"ec2-api-tools\")"
		exit 1
	fi
fi

if ${CREATE_IMG}; then
	create_img
elif [[ ! -f ${_IMG} ]]; then
	echo "${0##*/}: ${_IMG} does not exist"
	exit 1
fi

if ${CREATE_AMI}; then
	create_ami
fi
