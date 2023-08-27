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

create_ami() {
	local _arch=${ARCH} _bucket_conf _importsnapid _snap
	local _region=$(aws configure get region)

	[[ ${_region} == us-east-1 ]] ||
		_bucket_conf="--create-bucket-configuration LocationConstraint=${_region}"

	! [[ ${_arch} == amd64 ]] || _arch=x86_64

	pr_title "converting image to stream-based VMDK"
	vmdktool -v ${IMGPATH}.vmdk ${IMGPATH}

	pr_title "uploading image to S3"
	aws s3api create-bucket --bucket ${_BUCKETNAME} ${_bucket_conf}
	aws s3 cp ${IMGPATH}.vmdk s3://${_BUCKETNAME}

	pr_title "converting VMDK to snapshot"
	cat <<-EOF >>${_WRKDIR}/containers.json
	{
	  "Description": "${DESCR}",
	  "Format": "vmdk",
	  "UserBucket": {
	      "S3Bucket": "${_BUCKETNAME}",
	      "S3Key": "${_IMGNAME}.vmdk"
	  }
	}
	EOF

	# Cannot use import-image: "ClientError: Unknown OS / Missing OS files."
	#aws ec2 import-image --description "${DESCR}" --disk-containers \
	#	file://"${_WRKDIR}/containers.json"

	_importsnapid=$(aws ec2 import-snapshot --description "${DESCR}" \
		--disk-container file://"${_WRKDIR}/containers.json" \
		--role-name ${_IMGNAME} --query "ImportTaskId" --output text)

	while true; do
		set -A _snap -- $(aws ec2 describe-import-snapshot-tasks \
			--output text --import-task-ids ${_importsnapid} \
			--query \
			"ImportSnapshotTasks[*].SnapshotTaskDetail.[Status,Progress,SnapshotId]")
		echo -ne "\r Progress: ${_snap[1]}%"
		[[ ${_snap[0]} == completed ]] && echo && break
		sleep 10
	done

	pr_title "removing bucket ${_BUCKETNAME}"
	aws s3 rb s3://${_BUCKETNAME} --force

	pr_title "registering AMI"
	aws ec2 register-image --name "${_IMGNAME}" --architecture ${_arch} \
		--root-device-name /dev/sda1 --virtualization-type hvm \
		--description "${DESCR}" --block-device-mappings \
		DeviceName="/dev/sda1",Ebs={SnapshotId=${_snap[2]}}
}

create_autoinstallconf()
{
	local _autoinstallconf=${_WRKDIR}/auto_install.conf
	local _mirror=${MIRROR}

	_mirror=${_mirror#*://}
	_mirror=${_mirror%%/*}

	pr_title "creating auto_install.conf"

	cat <<-EOF >>${_autoinstallconf}
	System hostname = openbsd
	Password for root = *************
	Change the default console to com0 = yes
	Setup a user = ec2-user
	Full name for user ec2-user = EC2 Default User
	Password for user = *************
	What timezone are you in = UTC
	Location of sets = cd
	Set name(s) = done
	EOF

	# XXX if checksum fails
	for i in $(jot 11); do
	        echo "Checksum test for = yes" >>${_autoinstallconf}
	done
	echo "Continue without verification = yes" >>${_autoinstallconf}

	cat <<-EOF >>${_autoinstallconf}
	Location of sets = disk
	Is the disk partition already mounted = no
	Which disk contains the install media = sd1
	Which sd1 partition has the install sets = a
	INSTALL.${ARCH} not found. Use sets found here anyway = yes
	Set name(s) = site*
	Checksum test for = yes
	Continue without verification = yes
	EOF
}

create_iam_role()
{
	pr_title "creating IAM role"
	local _region=$(aws configure get region) _awsarn="aws" 
 	[[ ${_region} != cn-north-1 ]] ||
  		_awsarn="aws-cn"
	cat <<-'EOF' >>${_WRKDIR}/trust-policy.json
	{
	   "Version": "2012-10-17",
	   "Statement": [
	      {
	         "Effect": "Allow",
	         "Principal": { "Service": "vmie.amazonaws.com" },
	         "Action": "sts:AssumeRole",
	         "Condition": {
	            "StringEquals":{
	               "sts:Externalid": "vmimport"
	            }
	         }
	      }
	   ]
	}
	EOF

	cat <<-EOF >>${_WRKDIR}/role-policy.json
	{
	   "Version":"2012-10-17",
	   "Statement":[
	      {
	         "Effect":"Allow",
	         "Action":[
	            "s3:GetBucketLocation",
	            "s3:GetObject",
	            "s3:ListBucket"
	         ],
	         "Resource":[
	            "arn:${_awsarn}:s3:::${_BUCKETNAME}",
	            "arn:${_awsarn}:s3:::${_BUCKETNAME}/*"
	         ]
	      },
	      {
	         "Effect":"Allow",
	         "Action":[
	            "ec2:ModifySnapshotAttribute",
	            "ec2:CopySnapshot",
	            "ec2:RegisterImage",
	            "ec2:Describe*"
	         ],
	         "Resource":"*"
	      }
	   ]
	}
	EOF

	aws iam create-role --role-name ${_IMGNAME} \
		--assume-role-policy-document \
		"file://${_WRKDIR}/trust-policy.json"

	aws iam put-role-policy --role-name ${_IMGNAME} --policy-name \
		${_IMGNAME} --policy-document \
		"file://${_WRKDIR}/role-policy.json"
}

create_img()
{
	local _bsdrd=${_WRKDIR}/bsd.rd _rdextract=${_WRKDIR}/bsd.rd.extract
	local _rdgz=false _rdmnt=${_WRKDIR}/rdmnt _vndev

	create_install_site_disk

	create_autoinstallconf

	pr_title "creating modified bsd.rd for autoinstall"
	ftp -MV -o ${_bsdrd} ${MIRROR}/${RELEASE}/${ARCH}/bsd.rd

	# 6.9 onwards uses a compressed rd file
	if [[ $(file -bi ${_bsdrd}) == "application/x-gzip" ]]; then
		mv ${_bsdrd} ${_bsdrd}.gz
		gunzip ${_bsdrd}.gz
		_rdgz=true
	fi

	rdsetroot -x ${_bsdrd} ${_rdextract}
	_vndev=$(vnconfig ${_rdextract})
	install -d ${_rdmnt}
	mount /dev/${_vndev}a ${_rdmnt}
	cp ${_WRKDIR}/auto_install.conf ${_rdmnt}
	umount ${_rdmnt}
	vnconfig -u ${_vndev}
	rdsetroot ${_bsdrd} ${_rdextract}

	if ${_rdgz}; then
		gzip ${_bsdrd}
		mv ${_bsdrd}.gz ${_bsdrd}
	fi

	pr_title "starting autoinstall inside vmm(4)"

	vmctl create -s ${IMGSIZE}G ${IMGPATH}

	# handle cu(1) EOT
	(sleep 10 && vmctl wait ${_IMGNAME} && _tty=$(get_tty ${_IMGNAME}) &&
		vmctl stop -f ${_IMGNAME} && pkill -f "/usr/bin/cu -l ${_tty}")&

	# XXX handle installation error
	# (e.g. ftp: raw.githubusercontent.com: no address associated with name)
	vmctl start -b ${_WRKDIR}/bsd.rd -c -L -d ${IMGPATH} -d \
		${_WRKDIR}/siteXX.img -r ${_WRKDIR}/installXX.iso ${_IMGNAME}
}

create_install_site()
{
	# XXX bsd.mp + relink directory

	pr_title "creating install.site"

	cat <<-'EOF' >>${_WRKDIR}/install.site
	chown root:bin /usr/local/libexec/ec2-init
	chmod 0555 /usr/local/libexec/ec2-init

	echo "!/usr/local/libexec/ec2-init" >>/etc/hostname.vio0
	cp -p /etc/hostname.vio0 /etc/hostname.xnf0

	echo "https://cdn.openbsd.org/pub/OpenBSD" >/etc/installurl
	echo "sndiod_flags=NO" >/etc/rc.conf.local
	echo "permit keepenv nopass ec2-user" >/etc/doas.conf

	rm /install.site
	EOF

	chmod 0555 ${_WRKDIR}/install.site
}

create_install_site_disk()
{
	# XXX trap vnd and mount

	local _rel _relint _retrydl=true _vndev
	local _siteimg=${_WRKDIR}/siteXX.img _sitemnt=${_WRKDIR}/siteXX
 	local _region=$(aws configure get region) _cnproxy

	[[ ${RELEASE} == snapshots ]] && _rel=$(uname -r) || _rel=${RELEASE}
	_relint=${_rel%.*}${_rel#*.}

	create_install_site

	pr_title "creating install_site disk"

	vmctl create -s 1G ${_siteimg}
	_vndev="$(vnconfig ${_siteimg})"
	fdisk -iy ${_vndev}
	echo "a a\n\n\n\nw\nq\n" | disklabel -E ${_vndev}
	newfs ${_vndev}a

	install -d ${_sitemnt}
	mount /dev/${_vndev}a ${_sitemnt}
	install -d ${_sitemnt}/${_rel}/${ARCH}

	pr_title "downloading installation ISO"
	while ! ftp -o ${_WRKDIR}/installXX.iso \
		${MIRROR}/${RELEASE}/${ARCH}/install${_relint}.iso; do
		# in case we're running an X.Y snapshot while X.Z is out;
		# (e.g. running on 6.4-current and installing 6.5-beta)
		${_retrydl} || pr_err "cannot download installation ISO"
		_relint=$((_relint+1))
		_retrydl=false
	done

	pr_title "downloading ec2-init"
 	[[ ${_region} != cn-north-1 ]] || 
  		_cnproxy="https://ghproxy.com/"
	install -d ${_WRKDIR}/usr/local/libexec/
	ftp -o ${_WRKDIR}/usr/local/libexec/ec2-init \
		${_cnproxy}https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/ec2-init.sh

	pr_title "storing siteXX.tgz into install_site disk"
	cd ${_WRKDIR} && tar czf \
		${_sitemnt}/${_rel}/${ARCH}/site${_relint}.tgz ./install.site \
			./usr/local/libexec/ec2-init

	umount ${_sitemnt}
	vnconfig -u ${_vndev}
}

get_tty()
{
	local _tty _vmname=$1
	[[ -n ${_vmname} ]]

	vmctl status | grep "${_vmname}" | while read -r _ _ _ _ _ _tty _; do
		echo /dev/${_tty}
	done
}

pr_err()
{
	echo "${0##*/}: ${1}" 1>&2 && return ${2:-1}
}

pr_title()
{
	local _line=$(printf "%80s" | tr ' ' '=')
	echo "${_line}\n| ${@}\n${_line}"
}

setup_vmd()
{
	if ! $(rcctl check vmd >/dev/null); then
		pr_title "starting vmd(8)"
		rcctl start vmd
		_RESET_VMD=true
	fi
}

trap_handler()
{
	set +e # we're trapped

	if aws iam get-role --role-name ${_IMGNAME} >/dev/null 2>&1; then
		pr_title "removing IAM role"
		aws iam delete-role-policy --role-name ${_IMGNAME} \
			--policy-name ${_IMGNAME} 2>/dev/null
		aws iam delete-role --role-name ${_IMGNAME} 2>/dev/null
	fi

	if ${_RESET_VMD:-false}; then
		pr_title "stopping vmd(8)"
		rcctl stop vmd >/dev/null
	fi

	if [[ -n ${_WRKDIR} ]]; then
		rmdir ${_WRKDIR} 2>/dev/null ||
			pr_title "work directory: ${_WRKDIR}"
	fi
}

usage()
{
	echo "usage: ${0##*/}
       -a \"architecture\" -- default to \"amd64\"
       -d \"description\" -- AMI description; defaults to \"openbsd-\$release-\$timestamp\"
       -i \"path to RAW image\" -- use image at path instead of creating one
       -m \"install mirror\" -- defaults to installurl(5) or \"https://cdn.openbsd.org/pub/OpenBSD\"
       -n -- only create a RAW image (don't convert to an AMI nor push to AWS)
       -r \"release\" -- e.g \"6.5\"; default to \"snapshots\"
       -s \"image size in GB\" -- default to \"12\""

	return 1
}

while getopts a:d:i:m:nr:s: arg; do
	case ${arg} in
	a)	ARCH="${OPTARG}" ;;
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

# XXX add support for installation proxy in create_img
if [[ -n ${http_proxy} ]]; then
	export HTTP_PROXY=${http_proxy}
	export HTTPS_PROXY=${http_proxy}
fi

ARCH=${ARCH:-amd64}
CREATE_AMI=${CREATE_AMI:-true}
IMGSIZE=${IMGSIZE:-12}
RELEASE=${RELEASE:-snapshots}

if [[ -z ${MIRROR} ]]; then
	MIRROR=$(while read _line; do _line=${_line%%#*}; [[ -n ${_line} ]] &&
		print -r -- "${_line}"; done </etc/installurl | tail -1) \
		2>/dev/null
	[[ ${MIRROR} == @(http|https)://* ]] ||
		MIRROR="https://cdn.openbsd.org/pub/OpenBSD"
fi

_IMGNAME=openbsd-${RELEASE}-${ARCH}-${_TS}
[[ ${RELEASE} == snapshots ]] &&
	_IMGNAME=${_IMGNAME%snapshots*}current${_IMGNAME#*snapshots}
[[ -n ${IMGPATH} ]] && _IMGNAME=${IMGPATH##*/} ||
	IMGPATH=${_WRKDIR}/${_IMGNAME}
_BUCKETNAME=$(echo ${_IMGNAME} | tr '[:upper:]' '[:lower:]')-${RANDOM}
DESCR=${DESCR:-${_IMGNAME}}

readonly _BUCKETNAME _IMGNAME _TS _WRKDIR HTTP_PROXY HTTPS_PROXY
readonly CREATE_AMI DESCR IMGPATH IMGSIZE MIRROR RELEASE

# requirements checks to build the RAW image
if [[ ! -f ${IMGPATH} ]]; then
	(($(id -u) != 0)) && pr_err "need root privileges"
	grep -q ^vmm0 /var/run/dmesg.boot || pr_err "need vmm(4) support"
	[[ ${_IMGNAME}} != [[:alpha:]]* ]] &&
		pr_err "image name must start with a letter"
fi

# requirements checks to build and register the AMI
if ${CREATE_AMI}; then
	[[ ${ARCH} == i386 ]] &&
		pr_err "${ARCH} lacks xen(4) support to run on AWS"
	type aws >/dev/null 2>&1 || pr_err "package \"awscli\" is not installed"
	type vmdktool >/dev/null 2>&1 ||
		pr_err "package \"vmdktool\" is not installed"
	aws ec2 describe-regions --region-names us-east-1 >/dev/null ||
		pr_err "you may need to export:
AWS_CONFIG_FILE
AWS_DEFAULT_PROFILE
AWS_SHARED_CREDENTIALS_FILE"
fi

if [[ ! -f ${IMGPATH} ]]; then
	setup_vmd
	create_img
fi

if ${CREATE_AMI}; then
	create_iam_role
	create_ami
fi
