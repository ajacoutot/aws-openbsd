# AWS-OpenBSD

AWS playground for OpenBSD kids.

Running whatever is in this repo will propably end up destroying a kitten factory.


## Prerequisites

* shell access to OpenBSD 6.1 with internet connection available.
* minimum 12GB free space of /tmp (8GB for disk image and ~4GB for temporary files).
* doas configured; for building as a root the "permit nopass keepenv root as root" in /etc/doas.conf is enough.
* curl, ec2-api-tools, awscli and vmdktool packages installed.
* shell environment variables available.

    export AWS_ACCESS_KEY_ID=YOUR_AWS_ACCES_KEY;
    export AWS_SECRET_ACCESS_KEY=YOUR_AWS_SECRET_KEY;

* Identity and Access Management on AWS configured.

> YOUR_AWS_ACCES_KEY and YOUR_AWS_SECRET_KEY should have AmazonEC2FullAccess and AmazonS3FullAccess policies assigned.


## Script usage

```shell
create-ami.sh [-dinsr]
    -d "description"
    -i "/path/to/image"
    -n only create the RAW/VMDK images (not the AMI)
    -r "release (e.g 6.0; default to current)"
```


## References
http://blog.d2-si.fr/2016/02/15/openbsd-on-aws/


## Building example

### How to build OpenBSD 6.1 AMI

The example for creating own OpenBSD 6.1 AMI on host with Vagrant and VirtualBox. Using "ftp.fr.openbsd.org" mirror and Amazon AWS Frankfurt (eu-central-1) region.

#### Have OpenBSD 6.1 on your host (with Vagrant and VirtualBox installed)

```shell
cd /your/work/directory;
vagrant init SierraX/openbsd-6.1; vagrant up --provider virtualbox;
vagrant ssh;
```

#### When logged in to your OpenBSD virtual machine

```shell
doas su -;
```

Mount wd0k disk with 12GB as /tmp.
```shell
umount -f /tmp && mount -o "rw,nodev,nosuid" /dev/wd0k /tmp
```

Install required packages
```shell
pkg_add curl ec2-api-tools awscli vmdktool;
```

Prepare your environment.
```shell
export AWS_ACCESS_KEY_ID=000_YOUR_AWS_ACCESS_KEY_HERE;
export AWS_SECRET_ACCESS_KEY=000_AWS_SECRET_KEY_HERE;
export AWS_REGION=eu-central-1;
export MIRROR=https://ftp.fr.openbsd.org/pub/OpenBSD/
```

Build and upload your image.
```shell
curl -sS -O https://raw.githubusercontent.com/ajacoutot/aws-openbsd/master/create-ami.sh;
ksh create-ami.sh -r "6.1" -d "OpenBSD 6.1 - my AMI";
```

Launch your newly created AMI, check public IP and login "ssh ec2-user@public_IP". 
You might want to delete S3 volume and EBS volume used during creating process as well as destroying your vagrant instance.


## Script output

```shell
=========================================================================
| creating image container
=========================================================================
vmctl: imagefile created
=========================================================================
| creating and mounting image filesystem
=========================================================================
Writing MBR at offset 0.
Label editor (enter '?' for help at any prompt)
> > > > > [+|-]new size (with unit): [436448] > offset: [9567904] size: [7209296] FS type: [4.2BSD] mount point: [none] Rounding size to bsize (32 sectors): 7209280
> Write new label?: [y] /dev/rvnd1a: 131.2MB in 268672 sectors of 512 bytes
4 cylinder groups of 32.80MB, 2099 blocks, 4224 inodes each
super-block backups (for fsck -b #) at:
 32, 67200, 134368, 201536,
/dev/rvnd1i: 3520.2MB in 7209280 sectors of 512 bytes
18 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
super-block backups (for fsck -b #) at:
 32, 414688, 829344, 1244000, 1658656, 2073312, 2487968, 2902624, 3317280, 3731936, 4146592, 4561248, 4975904, 5390560, 5805216, 6219872, 6634528, 7049184,
newfs: reduced number of fragments per cylinder group from 25840 to 25728 to enlarge last cylinder group
/dev/rvnd1d: 201.9MB in 413472 sectors of 512 bytes
5 cylinder groups of 50.25MB, 3216 blocks, 6528 inodes each
super-block backups (for fsck -b #) at:
 32, 102944, 205856, 308768, 411680,
/dev/rvnd1f: 951.2MB in 1948032 sectors of 512 bytes
5 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
super-block backups (for fsck -b #) at:
 32, 414688, 829344, 1244000, 1658656,
newfs: reduced number of fragments per cylinder group from 69464 to 69184 to enlarge last cylinder group
/dev/rvnd1g: 542.7MB in 1111456 sectors of 512 bytes
5 cylinder groups of 135.12MB, 8648 blocks, 17408 inodes each
super-block backups (for fsck -b #) at:
 32, 276768, 553504, 830240, 1106976,
/dev/rvnd1h: 2150.4MB in 4404000 sectors of 512 bytes
11 cylinder groups of 202.47MB, 12958 blocks, 25984 inodes each
super-block backups (for fsck -b #) at:
 32, 414688, 829344, 1244000, 1658656, 2073312, 2487968, 2902624, 3317280, 3731936, 4146592,
/dev/rvnd1e: 512.0MB in 1048576 sectors of 512 bytes
4 cylinder groups of 128.00MB, 8192 blocks, 16384 inodes each
super-block backups (for fsck -b #) at:
 32, 262176, 524320, 786464,
=========================================================================
| fetching sets from ftp.fr.openbsd.org/pub/OpenBSD/
=========================================================================
bsd          100% |*************************************************************************************************************************************************************************************************************************************************************| 10433 KB    00:12
bsd.mp       100% |*************************************************************************************************************************************************************************************************************************************************************| 10499 KB    00:12
bsd.rd       100% |*************************************************************************************************************************************************************************************************************************************************************|  9210 KB    00:10
base61.tgz   100% |*************************************************************************************************************************************************************************************************************************************************************| 52322 KB    01:02
comp61.tgz   100% |*************************************************************************************************************************************************************************************************************************************************************| 46070 KB    00:55
game61.tgz   100% |*************************************************************************************************************************************************************************************************************************************************************|  2707 KB    00:02
man61.tgz    100% |*************************************************************************************************************************************************************************************************************************************************************|  8719 KB    00:10
xbase61.tgz  100% |*************************************************************************************************************************************************************************************************************************************************************| 17497 KB    00:20
xshare61.tgz 100% |*************************************************************************************************************************************************************************************************************************************************************|  4406 KB    00:04
xfont61.tgz  100% |*************************************************************************************************************************************************************************************************************************************************************| 39342 KB    00:45
xserv61.tgz  100% |*************************************************************************************************************************************************************************************************************************************************************| 13001 KB    00:15
=========================================================================
| fetching ec2-init
=========================================================================
ec2-init.sh  100% |*************************************************************************************************************************************************************************************************************************************************************|  3342       00:00
=========================================================================
| extracting sets
=========================================================================
=========================================================================
| installing MP kernel
=========================================================================
=========================================================================
| installing ec2-init
=========================================================================
=========================================================================
| creating devices
=========================================================================
=========================================================================
| storing entropy for the initial boot
=========================================================================
=========================================================================
| installing master boot record
=========================================================================
=========================================================================
| configuring the image
=========================================================================
=========================================================================
| unmounting the image
=========================================================================
=========================================================================
| removing downloaded and temporary files
=========================================================================
=========================================================================
| image available at: /tmp/aws-ami.iZa8EwvRnj/openbsd-6.1-amd64-20170512T114247Z
=========================================================================
=========================================================================
| converting image to stream-based VMDK
=========================================================================
=========================================================================
| uploading image to S3 and converting to volume in region eu-central-1
=========================================================================
Requesting volume size: 8 GB
TaskType        IMPORTVOLUME    TaskId  import-vol-fhe7ofgr     ExpirationTime  2017-05-19T11:48:25Z    Status  active  StatusMessage   Pending
DISKIMAGE       DiskImageFormat VMDK    DiskImageSize   218832384       VolumeSize      8       AvailabilityZone        eu-central-1a   ApproximateBytesConverted       0       Description     openbsd-6.1-amd64-20170512T114247Z
Creating new manifest at openbsd-6.1-amd64-20170512t114247z/f8025ed1-3c09-4d31-a493-0933aba7a28c/openbsd-6.1-amd64-20170512T114247Z.vmdkmanifest.xml
Uploading the manifest file
Uploading 218832384 bytes across 21 parts
----------------------------------------------------------------------------------------------------
   Upload progress              Estimated time      Estimated speed
 - 100% [====================>]                     8.574 MBps
********************* All 218832384 Bytes uploaded in 25s  *********************
Done uploading.
Average speed was 8.574 MBps
The disk image for import-vol-fhe7ofgr has been uploaded to Amazon S3
where it is being converted into an EBS volume.  You may monitor the
progress of this task by running ec2-describe-conversion-tasks.  When
the task is completed, you may use ec2-delete-disk-image to remove the
image from S3.

=========================================================================
| creating snapshot in region eu-central-1
=========================================================================
SNAPSHOT        snap-010990909c356e639  vol-07f26466f264949e0   pending 2017-05-12T11:50:59+0000                495039774644    8       openbsd-6.1-amd64-20170512T114247Z      Not Encrypted
=========================================================================
| registering new AMI in region eu-central-1: openbsd-6.1-amd64-20170512T114247Z
=========================================================================
IMAGE   ami-1398417c
```
