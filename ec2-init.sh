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
# AWS cloud-init like helper for OpenBSD
# ======================================
# Install as /usr/local/libexec/ec2-init and append to /etc/hostname.xnf0:
# !/usr/local/libexec/ec2-init firstboot

ec2_fingerprints()
{
	cat <<'EOF-RC' >>/etc/rc.firsttime
logger -s -t ec2 <<EOF
#############################################################
-----BEGIN SSH HOST KEY FINGERPRINTS-----
$(for _f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf ${_f}; done)
-----END SSH HOST KEY FINGERPRINTS-----
#############################################################
EOF
EOF-RC
}

ec2_hostname()
{
	local _hostname="$(mock meta-data/local-hostname)" || return
	hostname ${_hostname} || return
	print -- "${_hostname}" >/etc/myname || return
}

ec2_pubkey()
{
	local _pubkey="$(mock meta-data/public-keys/0/openssh-key)" || return
	install -d -m 0700 /root/.ssh || return
	if [[ ! -f /root/.ssh/authorized_keys ]]; then
		install -m 0600 /dev/null /root/.ssh/authorized_keys || return
	fi
	print -- "${_pubkey}" >>/root/.ssh/authorized_keys || return
}

ec2_userdata()
{
	local _userdata="$(mock user-data)" || return
	[[ ${_userdata%${_userdata#??}} == "#!" ]] || return 0
	local _script="$(mktemp -p /tmp -t aws-user-data.XXXXXXXXXX)" || return
	print -- "${_userdata}" >${_script} && chmod u+x ${_script} && \
		/bin/sh -c ${_script} && rm ${_script} || return
}

icleanup()
{
	# packer: /var/log/* ?
	rm /etc/{iked,isakmpd}/{local.pub,private/local.key} \
		/etc/ssh/ssh_host_*
	# reset entropy files in case the installer put them in the image
	>/etc/random.seed
	>/var/db/host.random
}

mock()
{
	[[ -n ${1} ]] || return
	local _ret
	_ret=$(ftp -MVo - http://169.254.169.254/latest/${1} 2>/dev/null) || return
	[[ -n ${_ret} ]] && print -- "${_ret}" || return
}

mock_pf()
{
	[[ -z ${INRC} ]] && return
	rcctl get pf status || return 0
	case ${1} in
		open)
			print -- \
			"pass out proto tcp from egress to 169.254.169.254 port www" | \
			pfctl -f -
			;;
		close)
			print -- "" | pfctl -f -
			;;
		*)
			return 1
			;;
	esac
}

usage()
{
	echo "usage: ${0##*/} cloudinit|firstboot"; exit 1
}

if [[ $(id -u) != 0 ]]; then
	echo "${0##*/}: needs root privileges"
	exit 1
fi

case ${1} in
	cloudinit)
		# XXX TODO
		exit 0 ;;
	firstboot)
		sed -i "/^!\/usr\/local\/libexec\/ec2-init/d" /etc/hostname.xnf0
		icleanup
		mock_pf open
		ec2_pubkey
		ec2_hostname
		ec2_userdata
		mock_pf close
		ec2_fingerprints
		;;
	*)
		usage ;;
esac
