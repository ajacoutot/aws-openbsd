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

MIRROR=${MIRROR:=https://ftp.fr.openbsd.org}

TIMESTAMP=$(date -u +%G%m%dT%H%M%SZ)
################################################################################

if [[ $(uname -m) != amd64 ]]; then
	echo "${0##*/}: only supports amd64"
	exit 1
fi

if (($(id -u) != 0)); then
	echo "${0##*/}: need root privileges"
	exit 1
fi

usage() {
	echo "usage: ${0##*/}" >&2
	echo "       -d \"description\"" >&2
	echo "       -i \"/path/to/image\"" >&2
	echo "       -n only create the RAW/VMDK images (not the AMI)" >&2
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
	local _VNDEV=$(vnconfig -l | grep 'not in use' | head -1 |
		cut -d ':' -f1)
	_REL=$(echo ${_REL} | tr -d '.')

	if [[ -z ${_VNDEV} ]]; then
		echo "${0##*/}: no vnd(4) device available"
		exit 1
	fi

	mkdir -p ${_MNT}

	pr_action "creating image container"
	vmctl create ${_IMG} -s 8G

	# we hardcode a 8G image because it's easy to extend /home if we need
	# more space for specialized usage (or even add a new EBS)
	pr_action "creating and mounting image filesystem"
	vnconfig ${_VNDEV} ${_IMG}
	fdisk -iy ${_VNDEV}
	disklabel -F ${_WRKDIR}/fstab -Aw ${_VNDEV}
	# remove /usr/src and /usr/obj
	echo "d i\nd j\nd k\na i\n\n\n\nq\n" | disklabel -E ${_VNDEV}
	for _p in a d e f g h i; do newfs /dev/r${_VNDEV}${_p}; done
	mount /dev/${_VNDEV}a ${_MNT}
	install -d ${_MNT}/{tmp,var,usr,home}
	mount /dev/${_VNDEV}d ${_MNT}/tmp
	mount /dev/${_VNDEV}e ${_MNT}/var
	mount /dev/${_VNDEV}f ${_MNT}/usr
	install -d ${_MNT}/usr/{X11R6,local}
	mount /dev/${_VNDEV}g ${_MNT}/usr/X11R6
	mount /dev/${_VNDEV}h ${_MNT}/usr/local
	mount /dev/${_VNDEV}i ${_MNT}/home

	pr_action "fetching sets from ${MIRROR:##*//}"
	( cd ${_WRKDIR} &&
		ftp -V ${MIRROR}/pub/OpenBSD/${RELEASE:-snapshots}/amd64/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_REL}.tgz} )

	pr_action "fetching ec2-init"
	ftp -V -o ${_WRKDIR}/ec2-init \
		https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh

	pr_action "extracting sets"
	for i in ${_WRKDIR}/*${_REL}.tgz ${_MNT}/var/sysmerge/{,x}etc.tgz; do
		tar xzphf $i -C ${_MNT}
	done

	pr_action "installing MP kernel"
	mv ${_WRKDIR}/bsd* ${_MNT}
	mv ${_MNT}/bsd ${_MNT}/bsd.sp
	mv ${_MNT}/bsd.mp ${_MNT}/bsd
	chown 0:0 ${_MNT}/bsd*

	pr_action "installing ec2-init"
	install -m 0555 -o root -g bin ${_WRKDIR}/ec2-init \
		${_MNT}/usr/local/libexec/ec2-init

	pr_action "creating devices"
	( cd ${_MNT}/dev && sh ./MAKEDEV all )

	pr_action "storing entropy for the initial boot"
	dd if=/dev/random of=${_MNT}/var/db/host.random bs=65536 count=1 \
		status=none
	dd if=/dev/random of=${_MNT}/etc/random.seed bs=512 count=1 \
		status=none
	chmod 600 ${_MNT}/var/db/host.random ${_MNT}/etc/random.seed

	pr_action "installing master boot record"
	installboot -r ${_MNT} ${_VNDEV}

	pr_action "configuring the image"
	# XXX hardcoded
	echo "https://ftp.fr.openbsd.org/pub/OpenBSD" >${_MNT}/etc/installurl
	sed -e "s#\(/home ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/tmp ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\(/usr ffs rw\)#\1,nodev#" \
		-e "s#\(/usr/X11R6 ffs rw\)#\1,nodev#" \
		-e "s#\(/usr/local ffs rw\)#\1,wxallowed,nodev#" \
		-e "/\/usr\/obj /d" \
		-e "/\/usr\/src /d" \
		-e "s#\(/var ffs rw\)#\1,nodev,nosuid#" \
		-e "s#\.k #\.i #" \
		-e '1h;1d;$!H;$!d;G' \
		${_WRKDIR}/fstab >${_MNT}/etc/fstab
	sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," \
		${_MNT}/etc/ttys
	echo "stty com0 9600" >${_MNT}/etc/boot.conf
	echo "set tty com0" >>${_MNT}/etc/boot.conf
	echo "dhcp" >${_MNT}/etc/hostname.xnf0
	echo "!/usr/local/libexec/ec2-init" >>${_MNT}/etc/hostname.xnf0
	chmod 0640 ${_MNT}/etc/hostname.xnf0
	echo "127.0.0.1\tlocalhost" >${_MNT}/etc/hosts
	echo "::1\t\tlocalhost" >>${_MNT}/etc/hosts
	sed -i "s/^#\(PermitRootLogin\) .*/\1 no/" ${_MNT}/etc/ssh/sshd_config
	chroot ${_MNT} ln -sf /usr/share/zoneinfo/UTC /etc/localtime
	chroot ${_MNT} ldconfig /usr/local/lib /usr/X11R6/lib
	chroot ${_MNT} rcctl disable sndiod
	chroot ${_MNT} useradd -G wheel -L staff -c 'EC2 Default User' -g =uid \
		-m -u 1000 ec2-user
	echo "permit nopass ec2-user" >${_MNT}/etc/doas.conf
	echo "ec2-user" >${_MNT}/root/.forward

	pr_action "unmounting the image"
	umount ${_MNT}/usr/X11R6
	umount ${_MNT}/usr/local
	umount ${_MNT}/usr
	umount ${_MNT}/var
	umount ${_MNT}/home
	umount ${_MNT}/tmp
	umount ${_MNT}
	vnconfig -u ${_VNDEV}

	pr_action "removing downloaded and temporary files"
	rm ${_WRKDIR}/*${_REL}.tgz ${_WRKDIR}/ec2-init || true # non-fatal
	rm ${_WRKDIR}/fstab || true # non-fatal
	rm -r ${_MNT} || true # non-fatal

	pr_action "image available at: ${_IMG}"
}

create_ami() {
	local _IMGNAME=${_IMG##*/}
	local _BUCKETNAME=${_IMGNAME}
	local _VMDK=${_IMG}.vmdk
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

	pr_action "converting image to stream-based VMDK"
	vmdktool -v ${_VMDK} ${_IMG}

	pr_action "uploading image to S3 and converting to volume in region ${AWS_REGION}"
	ec2-import-volume \
		${_VMDK} \
		-f vmdk \
		--region ${AWS_REGION} \
		-z ${AWS_REGION}a \
		-d ${_IMGNAME} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		-o "${AWS_ACCESS_KEY_ID}" \
		-w "${AWS_SECRET_ACCESS_KEY}" \
		-b ${_BUCKETNAME}

	echo
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
while getopts d:i:nr: arg; do
	case ${arg} in
	d)	DESCRIPTION="${OPTARG}";;
	i)	CREATE_IMG=false; _IMG="${OPTARG}";;
	n)	CREATE_AMI=false;;
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
	if ! type vmdktool >/dev/null; then
		echo "${0##*/}: needs the vmdktool"
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
