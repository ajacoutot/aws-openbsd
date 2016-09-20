# AWS-OpenBSD

AWS playground for OpenBSD kids

Running whatever is in this repo will propably end up destroying a kitten factory.


## Prerequisites

* not less than 16GB free space available in /tmp (8GB for disk image and 8GB for temporary files)
* doas configured; for building as a root the "permit nopass keepenv root as root" in /etc/doas.conf is enough
* awscli, ec2-api-tools, jdk packages installed
* shell environment variables available

    export EC2_HOME=/usr/local/ec2-api-tools/;
    export JAVA_HOME=/usr/local/jdk-1.7.0/;
    export AWS_ACCESS_KEY=YOUR_AWS_ACCES_KEY;
    export AWS_SECRET_KEY=YOUR_AWS_SECRET_KEY;

* Identity and Access Management configured

> YOUR_AWS_ACCES_KEY and YOUR_AWS_SECRET_KEY should have AmazonEC2FullAccess and AmazonS3FullAccess policies assigned.


## Usage

sh create-ami.sh;

## References
http://blog.d2-si.fr/2016/02/15/openbsd-on-aws/


## Unofficial builds

### OpenBSD 6.0 

 * EU Frankfurt
 
    AMI Id: ami-ac32cfc3
    AMI Name: openbsd-6.0-amd64
    AMI Source: 495039774644/openbsd-6.0-amd64
    AMI Description: OpenBSD 6.0 unofficial built by https://github.com/wilkart

 * EU Ireland
 
    AMI Id: ami-4e96ed3d
    AMI Name: openbsd-6.0-amd64
    AMI Source: 495039774644/openbsd-6.0-amd64
    AMI Description: OpenBSD 6.0 unofficial built by https://github.com/wilkart

