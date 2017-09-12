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

# AWS cloud-init like helper for OpenBSD
# ======================================
# Install as /usr/local/libexec/ec2-init and append to /etc/hostname.xnf0:
# !/usr/local/libexec/ec2-init

# XXXTODO https://cloudinit.readthedocs.org/en/latest/topics/format.html

set -e

ec2_fingerprints()
{
	cat <<-'EOF-RC' >>/etc/rc.firsttime
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
	local _hostname="$(mock meta-data/local-hostname)"
	hostname ${_hostname}
	print -- "${_hostname}" >/etc/myname
}

ec2_instanceid()
{
	local _instanceid="$(mock meta-data/instance-id)"
	print -- "${_instanceid}" >/var/db/ec2-init
}

ec2_pubkey()
{
	local _pubkey="$(mock meta-data/public-keys/0/openssh-key)"
	print -- "${_pubkey}" >>/home/ec2-user/.ssh/authorized_keys
}

ec2_userdata()
{
	local _userdata="$(mock user-data)"
	[[ ${_userdata%${_userdata#??}} == "#!" ]] || return 0
	local _script="$(mktemp -p /tmp -t aws-user-data.XXXXXXXXXX)"
	print -- "${_userdata}" >${_script} && chmod u+x ${_script} &&
		/bin/sh -c ${_script} && rm ${_script}
}

mock()
{
	[[ -n ${1} ]]
	local _ret
	_ret=$(ftp -MVo - http://169.254.169.254/latest/${1} 2>/dev/null)
	[[ -n ${_ret} ]] && print -- "${_ret}"
}

mock_pf()
{
	[[ -z ${INRC} ]] && return
	rcctl get pf status || return 0
	case ${1} in
	open)
		print -- \
			"pass out proto tcp from egress to 169.254.169.254 port www" |
			pfctl -f - ;;
	close)
		print -- "" | pfctl -f - ;;
	*)
		return 1 ;;
	esac
}

sysclean()
{
	local _l
	# reset root's password
	#chpass -a 'root:*:0:0:daemon:0:0:Charlie &:/root:/bin/ksh'
	# remove generated keys
	rm -f /etc/{iked,isakmpd}/{local.pub,private/local.key} \
		/etc/ssh/ssh_host_*
	# remove dhcp client configuration and old leases
	rm -f /etc/dhclient.conf /var/db/dhclient.leases.*
	# remove cruft from /tmp
	rm -rf /tmp/{.[!.],}*
	# reset entropy files
	>/etc/random.seed
	>/var/db/host.random
	# empty log files
	rm -f /var/log/[a-zA-Z]*.{{out,log}{,.old},[0-9]}.*
	for _l in $(find /var/log -type f ! -name '*.gz' -size +0); do
		>${_l}
	done
}

if [[ $(id -u) != 0 ]]; then
	echo "${0##*/}: needs root privileges"
	exit 1
fi

mock_pf open
if [[ $(mock meta-data/instance-id) != $(cat /var/db/ec2-init 2>/dev/null) ]]; then
	ec2_instanceid
	ec2_pubkey
	ec2_hostname
	ec2_userdata
	ec2_fingerprints
	sysclean
fi
mock_pf close
