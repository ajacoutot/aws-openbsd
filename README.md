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

```shell
create-ami.sh [-dins]
    -d "OpenBSD-current amd64"
    -i /path/to/image
    -n only create the RAW image (not the AMI)
    -s image/AMI size (in GB; default to 8)
    -r build released version (6.0|5.9)
```

## References
http://blog.d2-si.fr/2016/02/15/openbsd-on-aws/


## Unofficial builds

### OpenBSD 6.0 

 * EU Frankfurt
 
    AMI Id: ami-d51be6ba  
    AMI Name: openbsd-6.0-amd64  
    AMI Description: OpenBSD 6.0 x86_64. Unofficial build by https://github.com/wilkart  

 * EU Ireland
 
    AMI Id: ami-8fcdb6fc  
    AMI Name: openbsd-6.0-amd64  
    AMI Description: OpenBSD 6.0 x86_64. Unofficial build by https://github.com/wilkart  

### OpenBSD 5.9 

 * EU Frankfurt
 
    AMI Id: ami-ae19e4c1  
    AMI Name: openbsd-5.9-amd64  
    AMI Description: OpenBSD 5.9 x86_64. Unofficial build by https://github.com/wilkart  

 * EU Ireland
 
    AMI Id: ami-ccceb5bf  
    AMI Name: openbsd-5.9-amd64  
    AMI Description: OpenBSD 5.9 x86_64. Unofficial build by https://github.com/wilkart  
