#!/bin/sh
#
# Copyright (c) 2015 Antoine Jacoutot <ajacoutot@openbsd.org>
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
# create a 1G OpenBSD AMI for AWS

# XXX script vmm(4) to create an "official" installation instead of the extract dance
# XXX ec2-delete-disk-image
# XXX use env vars and knobs instead of editing the script
# XXX function()alise
# XXX make it possible to build a release image instead of a snap

_ARCH=$(uname -m)

################################################################################

AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_REGION=eu-west-1
AWS_AZ=eu-west-1a
AWS_CREATE_AMI=YES

IMGSIZE=1 # GB
MIRROR=http://ftp.fr.openbsd.org/pub/OpenBSD/snapshots/${_ARCH}

################################################################################

if [[ ${_ARCH} == amd64 ]]; then
	_ARCH=x86_64
elif [[ ${_ARCH} != i386 ]]; then
	echo "${0##*/}: only supports amd64 and i386"
	exit 1
fi

if [[ $(doas ${RANDOM} 2>/dev/null) == 1 ]]; then
	echo "${0##*/}: needs doas(1) privileges"
	exit 1
fi

if [[ ${AWS_CREATE_AMI} ==  "YES" ]]; then
	if [[ -z ${AWS_ACCESS_KEY_ID} || -z ${AWS_SECRET_ACCESS_KEY} ]]; then
		echo "${0##*/}: AWS credentials aren't set"
		exit 1
	fi
	if ! type ec2-import-volume >/dev/null; then
		echo "${0##*/}: needs the EC2 CLI tools"
	fi
	unset _VOL
fi

set -e
umask 022

_WRKDIR=$(mktemp -d -p /tmp aws-ami.XXXXXXXXXX)
_LOG=${_WRKDIR}/log
_IMG=${_WRKDIR}/img-openbsd-$(date "+%s")
_MNT=${_WRKDIR}/mnt
_REL=$(uname -r | tr -d '.')
_VNDEV=$(doas vnconfig -l | grep 'not in use' | head -1 | cut -d ':' -f1)

if [[ -z ${_VNDEV} ]]; then
	echo "${0##*/}: no vnd(4) device available"
	exit 1
fi

mkdir -p ${_MNT}
touch ${_LOG}

trap "cat ${_LOG}" ERR

echo "===> create image container"
doas dd if=/dev/zero of=${_IMG} bs=1m count=$((${IMGSIZE}*1024)) >${_LOG} 2>&1

echo "===> create image filesystem"
doas vnconfig ${_VNDEV} ${_IMG} >${_LOG} 2>&1
doas fdisk -iy ${_VNDEV} >${_LOG} 2>&1
printf "a\n\n\n\n\nq\n\n" | doas disklabel -E ${_VNDEV} >${_LOG} 2>&1
doas newfs /dev/r${_VNDEV}a >${_LOG} 2>&1

echo "===> mount image"
doas mount /dev/${_VNDEV}a ${_MNT} >${_LOG} 2>&1

echo "===> fetch sets (can take some time)"
( cd ${_WRKDIR} && \
	ftp -V ${MIRROR}/{bsd{,.mp,.rd},{base,comp,game,man,xbase,xshare,xfont,xserv}${_REL}.tgz} >${_LOG} 2>&1 )

echo "===> extract sets"
for i in ${_WRKDIR}/*${_REL}.tgz ${_MNT}/var/sysmerge/{,x}etc.tgz; do doas tar xzphf $i -C ${_MNT} >${_LOG} 2>&1; done

echo "===> install MP kernel"
doas mv ${_WRKDIR}/bsd* ${_MNT} >${_LOG} 2>&1
doas mv ${_MNT}/bsd ${_MNT}/bsd.sp >${_LOG} 2>&1
doas mv ${_MNT}/bsd.mp ${_MNT}/bsd >${_LOG} 2>&1
doas chown 0:0 ${_MNT}/bsd* >${_LOG} 2>&1

echo "===> remove downloaded files"
rm ${_WRKDIR}/*${_REL}.tgz >${_LOG} 2>&1

echo "===> create devices"
( cd ${_MNT}/dev && doas sh ./MAKEDEV all >${_LOG} 2>&1 )

echo "===> store entropy for the initial boot"
doas dd if=/dev/random of=${_MNT}/var/db/host.random bs=65536 count=1 status=none >${_LOG} 2>&1
doas dd if=/dev/random of=${_MNT}/etc/random.seed bs=512 count=1 status=none >${_LOG} 2>&1
doas chmod 600 ${_MNT}/var/db/host.random ${_MNT}/etc/random.seed >${_LOG} 2>&1

echo "===> install master boot record"
doas installboot -r ${_MNT} ${_VNDEV} >${_LOG} 2>&1

echo "===> configure the image"
echo "/dev/wd0a / ffs rw 1 1" | doas tee ${_MNT}/etc/fstab >${_LOG} 2>&1
doas sed -i "s,^tty00.*,tty00	\"/usr/libexec/getty std.9600\"	vt220   on  secure," ${_MNT}/etc/ttys >${_LOG} 2>&1
echo "stty com0 9600" | doas tee ${_MNT}/etc/boot.conf >${_LOG} 2>&1
echo "set tty com0" | doas tee -a ${_MNT}/etc/boot.conf >${_LOG} 2>&1
doas chroot ${_MNT} ln -sf /usr/share/zoneinfo/UTC /etc/localtime >${_LOG} 2>&1
doas chroot ${_MNT} ldconfig /usr/local/lib /usr/X11R6/lib >${_LOG} 2>&1
doas chroot ${_MNT} rcctl disable sndiod >${_LOG} 2>&1

echo "===> unmount the image"
doas umount ${_MNT} >${_LOG} 2>&1
doas vnconfig -u ${_VNDEV} >${_LOG} 2>&1

echo "===> image available at:"
echo "     ${_IMG}"
echo

trap - ERR
rmdir ${_MNT} || true
rm -f ${_LOG}

if [[ ${AWS_CREATE_AMI} ==  "YES" ]]; then
	echo "===> upload image to S3 (can take some time)"
	ec2-import-volume \
		${_IMG} \
		-f RAW \
		--region ${AWS_REGION} \
		-z ${AWS_AZ} \
		-s ${IMGSIZE} \
		-d ${_IMG##*/} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		-o "${AWS_ACCESS_KEY_ID}" \
		-w "${AWS_SECRET_ACCESS_KEY}" \
		-b ${_IMG##*/}

	echo
	echo "===> convert image to volume (can take some time)"
	while [[ -z ${_VOL} ]]; do
		_VOL=$(ec2-describe-conversion-tasks \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null | \
			grep "${_IMG##*/}" | \
			grep -Eo "vol-[[:alnum:]]*") || true
		sleep 10
	done

	#echo
	#echo "===> delete local and remote disk images"
	rm -rf ${_WRKDIR}
	#ec2-delete-disk-image

	echo
	echo "===> create snapshot (can take some time)"
	ec2-create-snapshot \
	       -O "${AWS_ACCESS_KEY_ID}" \
	       -W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-d ${_IMG##*/} \
		${_VOL}
	while [[ -z ${_SNAP} ]]; do
		_SNAP=$(ec2-describe-snapshots \
			-O "${AWS_ACCESS_KEY_ID}" \
			-W "${AWS_SECRET_ACCESS_KEY}" \
			--region ${AWS_REGION} 2>/dev/null | \
			grep "completed.*${_IMG##*/}" | \
			grep -Eo "snap-[[:alnum:]]*") || true
		sleep 10
	done

	echo
	echo "===> register new AMI: ${_IMG##*img-}"
	ec2-register \
		-n ${_IMG##*img-} \
		-O "${AWS_ACCESS_KEY_ID}" \
		-W "${AWS_SECRET_ACCESS_KEY}" \
		--region ${AWS_REGION} \
		-a ${_ARCH} \
		-d "OpenBSD-current $(uname -m) ${_IMG##*img-}" \
		--root-device-name /dev/sda1 \
		--virtualization-type hvm \
		-s ${_SNAP}
fi
