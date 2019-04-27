# AWS-OpenBSD

AWS playground for OpenBSD kids.

Running whatever is in this repo will propably end up destroying a kitten factory.

## Prerequisites for obsd-img-builder.sh (OpenBSD AMI builder)

* shell access to OpenBSD current >6.5 with vmm(4) support and Internet access
  * working vmm(4) internet access using local network interface (or use the "-c" option)
* 3GB of free space in ${TMPDIR}
* *awscli*, *upobsd* and *vmdktool* packages installed
* AWS IAM user with enough permissions (AmazonEC2FullAccess, AmazonS3FullAccess, IAMFullAccess)
  * AWS environment variables properly set (when not use root's awscli configuration):
    * *AWS_CONFIG_FILE*
    * *AWS_DEFAULT_PROFILE* (when not using the *default* profile)
    * *AWS_SHARED_CREDENTIALS_FILE*

## Script usage

```
usage: obsd-img-builder.sh
       -a "architecture" -- default to "amd64"
       -c -- autoconfigure pf(4) and enable IP forwarding
       -d "description" -- AMI description; defaults to "openbsd-$release-$timestamp"
       -i "path to RAW image" -- use image at path instead of creating one
       -m "install mirror" -- defaults to "cdn.openbsd.org"
       -n -- only create a RAW image (don't convert to an AMI nor push to AWS)
       -r "release" -- e.g "6.5"; default to "snapshots"
       -s "image size in GB" -- default to "10"
```

## TODO

* arm64 support
* MP support

### Misc

### KARL (kernel address randomized link)

While a newly built image/AMI will contain a randomized kernel, it is advised
to add user-data at first boot that will reboot the instance once the first
randomization is done. This is so that every instance will indeed run a
different relinked kernel.

### ENI hotplug

```
# cat <<-'EOF' >/etc/hotplug/attach
#!/bin/sh

case $1 in
	3)      echo "!/sbin/dhclient -i routers $2" >/etc/hostname.$2
		/bin/sh /etc/netstart $i
		;;
esac
EOF
# chmod 0555 /etc/hotplug/attach
# rcctl enable hotplugd && rcctl start hotplugd
```

### Build sample output

```
# export AWS_CONFIG_FILE=/home/myuser/.aws/config
# export AWS_DEFAULT_PROFILE=builder
# export AWS_SHARED_CREDENTIALS_FILE=/home/myuser/.aws/credentials
```

```
# ./obsd-img-builder.sh      
================================================================================
| creating install.site
================================================================================
================================================================================
| creating sd1 and storing siteXX.tgz
================================================================================
vmctl: raw imagefile created
Writing MBR at offset 0.
Label editor (enter '?' for help at any prompt)
> offset: [128] size: [2096972] FS type: [4.2BSD] > > No label changes.
/dev/rvnd0a: 1023.9MB in 2096960 sectors of 512 bytes
6 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
super-block backups (for fsck -b #) at:
 32, 414688, 829344, 1244000, 1658656, 2073312,
================================================================================
| creating auto_install.conf
================================================================================
================================================================================
| creating modified bsd.rd for autoinstall
================================================================================
SHA256.sig   100% |******************************************************|  2141       00:00    
bsd.rd       100% |******************************************************|  9971 KB    00:01    
checking signature: /etc/signify/openbsd-65-base.pub
================================================================================
| starting autoinstall inside vmm(4)
================================================================================
vmctl: raw imagefile created
Connected to /dev/ttyp5 (speed 115200)
Copyright (c) 1982, 1986, 1989, 1991, 1993
	The Regents of the University of California.  All rights reserved.
Copyright (c) 1995-2019 OpenBSD. All rights reserved.  https://www.OpenBSD.org

OpenBSD 6.5-beta (RAMDISK_CD) #783: Thu Mar 21 21:42:12 MDT 2019
    deraadt@amd64.openbsd.org:/usr/src/sys/arch/amd64/compile/RAMDISK_CD
real mem = 520093696 (496MB)
avail mem = 500412416 (477MB)
mainbus0 at root
bios0 at mainbus0
acpi at bios0 not configured
cpu0 at mainbus0: (uniprocessor)
cpu0: Intel(R) Core(TM) i5-5300U CPU @ 2.30GHz, 2295.72 MHz, 06-3d-04
cpu0: FPU,VME,DE,PSE,TSC,MSR,PAE,MCE,CX8,SEP,PGE,MCA,CMOV,PAT,PSE36,CFLUSH,MMX,FXSR,SSE,SSE2,SSE3,PCLMUL,SSSE3,FMA3,CX16,SSE4.1,SSE4.2,MOVBE,POPCNT,AES,XSAVE,AVX,F16C,RDRAND,HV,NXE,PAGE1GB,LONG,LAHF,ABM,3DNOWP,ITSC,FSGSBASE,BMI1,AVX2,SMEP,BMI2,ERMS,RDSEED,ADX,SMAP,MELTDOWN
cpu0: 256KB 64b/line 8-way L2 cache
pvbus0 at mainbus0: OpenBSD
pci0 at mainbus0 bus 0
pchb0 at pci0 dev 0 function 0 "OpenBSD VMM Host" rev 0x00
virtio0 at pci0 dev 1 function 0 "Qumranet Virtio RNG" rev 0x00
viornd0 at virtio0
virtio0: irq 3
virtio1 at pci0 dev 2 function 0 "Qumranet Virtio Network" rev 0x00
vio0 at virtio1: address fe:e1:bb:d1:44:83
virtio1: irq 5
virtio2 at pci0 dev 3 function 0 "Qumranet Virtio Storage" rev 0x00
vioblk0 at virtio2
scsibus0 at vioblk0: 2 targets
sd0 at scsibus0 targ 0 lun 0: <VirtIO, Block Device, > SCSI3 0/direct fixed
sd0: 12288MB, 512 bytes/sector, 25165824 sectors
virtio2: irq 6
virtio3 at pci0 dev 4 function 0 "Qumranet Virtio Storage" rev 0x00
vioblk1 at virtio3
scsibus1 at vioblk1: 2 targets
sd1 at scsibus1 targ 0 lun 0: <VirtIO, Block Device, > SCSI3 0/direct fixed
sd1: 1024MB, 512 bytes/sector, 2097152 sectors
virtio3: irq 7
virtio4 at pci0 dev 5 function 0 "OpenBSD VMM Control" rev 0x00
vmmci0 at virtio4
virtio4: irq 9
isa0 at mainbus0
com0 at isa0 port 0x3f8/8 irq 4: ns16450, no fifo
com0: console
softraid0 at root
scsibus2 at softraid0: 256 targets
root on rd0a swap on rd0b dump on rd0b
erase ^?, werase ^W, kill ^U, intr ^C, status ^T

Welcome to the OpenBSD/amd64 6.5 installation program.
Starting non-interactive mode in 5 seconds...
(I)nstall, (U)pgrade, (A)utoinstall or (S)hell? waiting for vm openbsd-current-amd64-20190322T091544Z: 
Performing non-interactive install...
Terminal type? [vt220] vt220
System hostname? (short form, e.g. 'foo') openbsd

Available network interfaces are: vio0 vlan0.
Which network interface do you wish to configure? (or 'done') [vio0] vio0
IPv4 address for vio0? (or 'dhcp' or 'none') [dhcp] dhcp
IPv6 address for vio0? (or 'autoconf' or 'none') [none] none
Available network interfaces are: vio0 vlan0.
Which network interface do you wish to configure? (or 'done') [done] done
DNS domain name? (e.g. 'example.com') [my.domain] my.domain
Using DNS nameservers at 100.64.11.2

Password for root account? <provided>
Public ssh key for root account? [none] none
Start sshd(8) by default? [yes] yes
Change the default console to com0? [yes] yes
Available speeds are: 9600 19200 38400 57600 115200.
Which speed should com0 use? (or 'done') [115200] 115200
Setup a user? (enter a lower-case loginname, or 'no') [no] ec2-user
Full name for user ec2-user? [ec2-user] EC2 Default User
Password for user ec2-user? <provided>
Public ssh key for user ec2-user [none] none
WARNING: root is targeted by password guessing attacks, pubkeys are safer.
Allow root ssh login? (yes, no, prohibit-password) [no] no
What timezone are you in? ('?' for list) [UTC] UTC

Available disks are: sd0 sd1.
Which disk is the root disk? ('?' for details) [sd0] sd0
No valid MBR or GPT.
Use (W)hole disk MBR, whole disk (G)PT or (E)dit? [whole] whole
Setting OpenBSD MBR partition to whole sd0...done.
URL to autopartitioning template for disklabel? [none] none
The auto-allocated layout for sd0 is:
#                size           offset  fstype [fsize bsize   cpg]
  a:           255.1M               64  4.2BSD   2048 16384     1 # /
  b:           290.2M           522496    swap                    
  c:         12288.0M                0  unused                    
  d:           288.2M          1116832  4.2BSD   2048 16384     1 # /tmp
  e:           353.2M          1706976  4.2BSD   2048 16384     1 # /var
  f:          1005.1M          2430432  4.2BSD   2048 16384     1 # /usr
  g:           447.0M          4488864  4.2BSD   2048 16384     1 # /usr/X11R6
  h:          1339.3M          5404416  4.2BSD   2048 16384     1 # /usr/local
  i:          1342.0M          8147296  4.2BSD   2048 16384     1 # /usr/src
  j:          5204.1M         10895776  4.2BSD   2048 16384     1 # /usr/obj
  k:          1759.8M         21553728  4.2BSD   2048 16384     1 # /home
Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout? [a] a
newfs: reduced number of fragments per cylinder group from 32648 to 32512 to enlarge last cylinder group
/dev/rsd0a: 255.1MB in 522432 sectors of 512 bytes
5 cylinder groups of 63.50MB, 4064 blocks, 8192 inodes each
/dev/rsd0k: 1759.8MB in 3604032 sectors of 512 bytes
9 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
newfs: reduced number of fragments per cylinder group from 36880 to 36728 to enlarge last cylinder group
/dev/rsd0d: 288.2MB in 590144 sectors of 512 bytes
5 cylinder groups of 71.73MB, 4591 blocks, 9216 inodes each
/dev/rsd0f: 1005.1MB in 2058432 sectors of 512 bytes
5 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
newfs: reduced number of fragments per cylinder group from 57216 to 56992 to enlarge last cylinder group
/dev/rsd0g: 447.0MB in 915552 sectors of 512 bytes
5 cylinder groups of 111.31MB, 7124 blocks, 14336 inodes each
/dev/rsd0h: 1339.3MB in 2742880 sectors of 512 bytes
7 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
/dev/rsd0j: 5204.1MB in 10657952 sectors of 512 bytes
26 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
/dev/rsd0i: 1342.0MB in 2748480 sectors of 512 bytes
7 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
/dev/rsd0e: 353.2MB in 723456 sectors of 512 bytes
4 cylinder groups of 88.31MB, 5652 blocks, 11392 inodes each
Available disks are: sd1.
Which disk do you wish to initialize? (or 'done') [done] done
/dev/sd0a (9861f4b2a79df4f4.a) on /mnt type ffs (rw, asynchronous, local)
/dev/sd0k (9861f4b2a79df4f4.k) on /mnt/home type ffs (rw, asynchronous, local, nodev, nosuid)
/dev/sd0d (9861f4b2a79df4f4.d) on /mnt/tmp type ffs (rw, asynchronous, local, nodev, nosuid)
/dev/sd0f (9861f4b2a79df4f4.f) on /mnt/usr type ffs (rw, asynchronous, local, nodev)
/dev/sd0g (9861f4b2a79df4f4.g) on /mnt/usr/X11R6 type ffs (rw, asynchronous, local, nodev)
/dev/sd0h (9861f4b2a79df4f4.h) on /mnt/usr/local type ffs (rw, asynchronous, local, nodev)
/dev/sd0j (9861f4b2a79df4f4.j) on /mnt/usr/obj type ffs (rw, asynchronous, local, nodev, nosuid)
/dev/sd0i (9861f4b2a79df4f4.i) on /mnt/usr/src type ffs (rw, asynchronous, local, nodev, nosuid)
/dev/sd0e (9861f4b2a79df4f4.e) on /mnt/var type ffs (rw, asynchronous, local, nodev, nosuid)

Let's install the sets!
Location of sets? (disk http or 'done') [disk] http
HTTP proxy URL? (e.g. 'http://proxy:8080', or 'none') [none] none
HTTP Server? (hostname, list#, 'done' or '?') [cdn.openbsd.org] cdn.openbsd.org
Server directory? [pub/OpenBSD/snapshots/amd64] pub/OpenBSD/snapshots/amd64

Select sets by entering a set name, a file name pattern or 'all'. De-select
sets by prepending a '-', e.g.: '-game*'. Selected sets are labelled '[X]'.
    [X] bsd           [X] comp65.tgz    [X] xbase65.tgz   [X] xserv65.tgz
    [X] bsd.rd        [X] man65.tgz     [X] xshare65.tgz
    [X] base65.tgz    [X] game65.tgz    [X] xfont65.tgz
Set name(s)? (or 'abort' or 'done') [done] done
Get/Verify SHA256.sig   100% |**************************|  2141       00:00    
Signature Verified
Get/Verify bsd          100% |**************************| 15492 KB    00:02    
Get/Verify bsd.rd       100% |**************************|  9971 KB    00:01    
Get/Verify base65.tgz   100% |**************************|   191 MB    00:27    
Get/Verify comp65.tgz   100% |**************************| 93001 KB    00:12    
Get/Verify man65.tgz    100% |**************************|  7383 KB    00:01    
Get/Verify game65.tgz   100% |**************************|  2740 KB    00:00    
Get/Verify xbase65.tgz  100% |**************************| 20664 KB    00:03    
Get/Verify xshare65.tgz 100% |**************************|  4448 KB    00:01    
Get/Verify xfont65.tgz  100% |**************************| 39342 KB    00:05    
Get/Verify xserv65.tgz  100% |**************************| 16684 KB    00:02    
Installing bsd          100% |**************************| 15492 KB    00:00    
Installing bsd.rd       100% |**************************|  9971 KB    00:00    
Installing base65.tgz   100% |**************************|   191 MB    00:18    
Extracting etc.tgz      100% |**************************|   256 KB    00:00    
Installing comp65.tgz   100% |**************************| 93001 KB    00:14    
Installing man65.tgz    100% |**************************|  7383 KB    00:01    
Installing game65.tgz   100% |**************************|  2740 KB    00:00    
Installing xbase65.tgz  100% |**************************| 20664 KB    00:02    
Extracting xetc.tgz     100% |**************************|  6935       00:00    
Installing xshare65.tgz 100% |**************************|  4448 KB    00:01    
Installing xfont65.tgz  100% |**************************| 39342 KB    00:03    
Installing xserv65.tgz  100% |**************************| 16684 KB    00:01    
Location of sets? (disk http or 'done') [done] disk
Is the disk partition already mounted? [yes] no
Available disks are: sd0 sd1.
Which disk contains the install media? (or 'done') [sd1] sd1
Pathname to the sets? (or 'done') [6.5/amd64] 6.5/amd64
INSTALL.amd64 not found. Use sets found here anyway? [no] yes

Select sets by entering a set name, a file name pattern or 'all'. De-select
sets by prepending a '-', e.g.: '-game*'. Selected sets are labelled '[X]'.
    [ ] site65.tgz
Set name(s)? (or 'abort' or 'done') [done] site*
    [X] site65.tgz
Set name(s)? (or 'abort' or 'done') [done] done
Directory does not contain SHA256.sig. Continue without verification? [no] yes
Installing site65.tgz   100% |**************************|   372       00:00    
Location of sets? (disk http or 'done') [done] done
Saving configuration files... done.
Making all device nodes... done.
Relinking to create unique kernel... done.

CONGRATULATIONS! Your OpenBSD install has been successfully completed!

When you login to your new system the first time, please read your mail
using the 'mail' command.

syncing disks... done
vmmci0: powerdown
rebooting...
terminated vm 11
                stopping vm openbsd-current-amd64-20190322T091544Z: forced to terminate vm 11

[SIGTERM]
================================================================================
| creating IAM role
================================================================================
{
    "Role": {
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17", 
            "Statement": [
                {
                    "Action": "sts:AssumeRole", 
                    "Effect": "Allow", 
                    "Condition": {
                        "StringEquals": {
                            "sts:Externalid": "vmimport"
                        }
                    }, 
                    "Principal": {
                        "Service": "vmie.amazonaws.com"
                    }
                }
            ]
        }, 
        "RoleId": "AROAJ724UC5U3JGJ5EZ7C", 
        "CreateDate": "2019-03-22T09:18:45Z", 
        "RoleName": "openbsd-current-amd64-20190322T091544Z", 
        "Path": "/", 
        "Arn": "arn:aws:iam::360116137065:role/openbsd-current-amd64-20190322T091544Z"
    }
}
================================================================================
| converting image to stream-based VMDK
================================================================================
================================================================================
| uploading image to S3
================================================================================
{
    "Location": "http://openbsd-current-amd64-20190322t091544z-29476.s3.amazonaws.com/"
}
upload: ./openbsd-current-amd64-20190322T091544Z.vmdk to s3://openbsd-current-amd64-20190322t091544z-29476/openbsd-current-amd64-20190322T091544Z.vmdk
================================================================================
| converting VMDK to snapshot
================================================================================
 Progress: None%
================================================================================
| removing bucket openbsd-current-amd64-20190322t091544z-29476
================================================================================
delete: s3://openbsd-current-amd64-20190322t091544z-29476/openbsd-current-amd64-20190322T091544Z.vmdk
remove_bucket: openbsd-current-amd64-20190322t091544z-29476
================================================================================
| registering AMI
================================================================================
{
    "ImageId": "ami-0d1cf7bb6f969621f"
}
================================================================================
| removing IAM role
================================================================================
================================================================================
| work directory: /tmp/aws-ami.p0MJZxjBcr
================================================================================
```

Instanciate the AMI and connect to it using SSH:

```
$ ssh ec2-user@${IPADDR}
```
