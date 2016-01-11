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
# AWS cloud-init helper for OpenBSD
# =================================
# Install as /usr/libexec/cloud-init; add the following to /etc/rc.securelevel:
# /usr/libexec/cloud-init firstboot
#

ec2_fingerprints()
{
	( while ! pgrep -qf "^/usr/libexec/getty "; do sleep 1; done
	logger -s -t ec2 <<EOF
#############################################################
-----BEGIN SSH HOST KEY FINGERPRINTS-----
$(for _f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf ${_f}; done)
-----END SSH HOST KEY FINGERPRINTS-----
#############################################################
EOF
	) &
}

ec2_hostname()
{
	local _hostname="$(mock meta-data/local-hostname)"
	hostname ${_hostname}
	echo ${_hostname} >/etc/myname
}

ec2_pubkey()
{
	mkdir -pm 0700 /root/.ssh
	echo "$(mock meta-data/public-keys/0/openssh-key)" \
		>>/root/.ssh/authorized_keys
	chmod 0600 /root/.ssh/authorized_keys
}

# XXX only handles scripts for now
ec2_userdata()
{
	local _userdata="$(mktemp -p /tmp -t aws-user-data.XXXXXXXXXX)" || return
	echo "$(mock user-data)" >${_userdata}
	[[ -s ${_userdata} ]] && chmod u+x ${_userdata} && \
		/bin/sh -c ${_userdata} && rm ${_userdata}
}

mock()
{
	[[ -n ${1} ]] || return
	ftp -MVo - http://169.254.169.254/latest/${1} 2>/dev/null || return
}

usage()
{
	echo "usage: ${0##*/} cloudinit|firstboot" >&2; exit 1
}

case ${1} in
	cloudinit)
		# XXX TODO
		exit 0 ;;
	firstboot)
		ec2_pubkey
		ec2_hostname
		ec2_userdata
		ec2_fingerprints
		sed -i "/^!\/usr\/libexec\/cloud-init/d" /etc/rc.securelevel
		if [[ ! -s /etc/rc.securelevel ]]; then
			rm /etc/rc.securelevel
		fi
		;;
	*)
		usage ;;
esac
