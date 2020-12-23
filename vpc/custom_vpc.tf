#################################################
#############       Variables      ############## 
#################################################
variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "private_key_path" {}
variable "key_name" {}
variable "region" {
  default = "us-east-2"
}

variable "network_address_space" {
  default = "10.1.0.0/16"
}

variable "subnet1_address_space" {
  default = "10.1.0.0/24"
}
variable "subnet2_address_space" {
  default = "10.1.1.0/24"
}

variable "bucket_name_prefix"{}
variable "env_tag"{}

#################################################
#############       Provider       ############## 
#################################################
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

#################################################
#############       Local Config   ############## 
#################################################
locals {
  tags = {
    Env = var.env_tag
  }
  s3_bucket_name = "${var.bucket_name_prefix}-${var.env_tag}-${random_integer.rand.result}"
}
#################################################
#############       Data           ############## 
#################################################
data "aws_availability_zones" "available" {}

data "aws_ami" "aws-linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-hvm*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
#################################################
#############       Resources      ############## 
#################################################
resource "random_integer" "rand" {
  min = 1000
  max = 9999
}
resource "aws_vpc" "terra_vpc" {
  cidr_block           = var.network_address_space
  enable_dns_hostnames = "true"
  tags = merge(local.tags, {Name = "${var.env_tag}-vpc"})
}

resource "aws_internet_gateway" "terra_igw" {
  vpc_id = aws_vpc.terra_vpc.id
  tags = merge(local.tags, {Name = "${var.env_tag}-igw"})
}
#################################################
#############       Network        ############## 
#################################################
resource "aws_subnet" "terra_subnet1" {
  cidr_block              = var.subnet1_address_space
  vpc_id                  = aws_vpc.terra_vpc.id
  map_public_ip_on_launch = "true"
  availability_zone       = data.aws_availability_zones.available.names[0]
}
resource "aws_subnet" "terra_subnet2" {
  cidr_block              = var.subnet2_address_space
  vpc_id                  = aws_vpc.terra_vpc.id
  map_public_ip_on_launch = "true"
  availability_zone       = data.aws_availability_zones.available.names[1]
}

resource "aws_route_table" "terra_rtb" {
  vpc_id = aws_vpc.terra_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.terra_igw.id
  }
}

resource "aws_route_table_association" "terra_rta_subnet1" {
  subnet_id      = aws_subnet.terra_subnet1.id
  route_table_id = aws_route_table.terra_rtb.id
}

resource "aws_route_table_association" "terra_rta_subnet2" {
  subnet_id      = aws_subnet.terra_subnet2.id
  route_table_id = aws_route_table.terra_rtb.id
}

#################################################
#############    Security Groups   ############## 
#################################################
resource "aws_security_group" "terra_elb_sg" {
  name        = "terra_nginx_elb_sg"
  description = "Allow ports for testing nginx and terraform"
  vpc_id      = aws_vpc.terra_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "terra_nginx_sg" {
  name        = "terra_nginx_sg"
  description = "Allow ports for testing nginx and terraform"
  vpc_id      = aws_vpc.terra_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.network_address_space]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}
#################################################
#############    Type of Instance  ############## 
#################################################
resource "aws_elb" "terra_web" {
  name            = "terra-nginx-elb"
  subnets         = [aws_subnet.terra_subnet1.id, aws_subnet.terra_subnet2.id]
  security_groups = [aws_security_group.terra_elb_sg.id]
  instances       = [aws_instance.terra_nginx1.id, aws_instance.terra_nginx2.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
}

resource "aws_instance" "terra_nginx1" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.terra_subnet1.id
  vpc_security_group_ids = [aws_security_group.terra_nginx_sg.id]
  key_name               = var.key_name
  iam_instance_profile = aws_iam_instance_profile.terra_nginx_profile.name

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = self.public_ip
    private_key = file(var.private_key_path)
  }

  provisioner "file" {
    content = <<EOF
access_key =
secret_key =
security_token = 
use_https = True
bucket_location = US

EOF
    destination = "/home/ec2-user/.s3cfg"
  }
  
   provisioner "file" {
    content = <<EOF
/var/log/nginx/*log {
    daily
    rotate 10
    missingok
    compress
    sharedscripts
    postrotate
    endscript
    lastaction
        INSTANCE_ID=`curl --silent http://169.254.169.254/latest/meta-data/instance-id`
        sudo /usr/local/bin/s3cmd sync --config=/home/ec2-user/.s3cfg /var/log/nginx/ s3://${aws_s3_bucket.terra_nginx_bucket.id}/nginx/$INSTANCE_ID/
    endscript
}
EOF
    destination = "/home/ec2-user/terra-test-nginx"
  }  
  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "sudo cp /home/ec2-user/.s3cfg /root/.s3cfg",
      "sudo cp /home/ec2-user/terra-test-nginx /etc/logrotate.d/nginx",
      "sudo pip install s3cmd",
      "s3cmd get s3://${aws_s3_bucket.terra_nginx_bucket.id}/website/index.html .",
      "s3cmd get s3://${aws_s3_bucket.terra_nginx_bucket.id}/website/Globo_logo_Vert.png .",
      "sudo cp /home/ec2-user/index.html /usr/share/nginx/html/index.html",
      "sudo cp /home/ec2-user/Globo_logo_Vert.png /usr/share/nginx/html/Globo_logo_Vert.png",
      "sudo logrotate -f /etc/logrotate.conf"
    ]
  }
  tags = merge(local.tags, { Name = "${var.env_tag}-terra_nginx1" })
}

resource "aws_instance" "terra_nginx2" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.terra_subnet2.id
  vpc_security_group_ids = [aws_security_group.terra_nginx_sg.id]
  key_name               = var.key_name

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = self.public_ip
    private_key = file(var.private_key_path)
  }
  provisioner "file" {
    content = <<EOF
access_key =
secret_key =
security_token = 
use_https = True
bucket_location = US

EOF
    destination = "/home/ec2-user/.s3cfg"
  }
  
   provisioner "file" {
    content = <<EOF
/var/log/nginx/*log {
    daily
    rotate 10
    missingok
    compress
    sharedscripts
    postrotate
    endscript
    lastaction
        INSTANCE_ID=`curl --silent http://169.254.169.254/latest/meta-data/instance-id`
        sudo /usr/local/bin/s3cmd sync --config=/home/ec2-user/.s3cfg /var/log/nginx/ s3://${aws_s3_bucket.terra_nginx_bucket.id}/nginx/$INSTANCE_ID/
    endscript
}
EOF
    destination = "/home/ec2-user/terra-test-nginx"
  }  
  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "sudo cp /home/ec2-user/.s3cfg /root/.s3cfg",
      "sudo cp /home/ec2-user/terra-test-nginx /etc/logrotate.d/nginx",
      "sudo pip install s3cmd",
      "s3cmd get s3://${aws_s3_bucket.terra_nginx_bucket.id}/website/index.html .",
      "s3cmd get s3://${aws_s3_bucket.terra_nginx_bucket.id}/website/Globo_logo_Vert.png .",
      "sudo cp /home/ec2-user/index.html /usr/share/nginx/html/index.html",
      "sudo cp /home/ec2-user/Globo_logo_Vert.png /usr/share/nginx/html/Globo_logo_Vert.png",
      "sudo logrotate -f /etc/logrotate.conf"
    ]
  }
  tags = merge(local.tags, { Name = "${var.env_tag}-terra_nginx2" })
}

#################################################
#############       IAM Role       ############## 
#################################################
resource "aws_iam_role" "allow_terra_nginx_s3" {
  name = "allow_nginx_s3"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}

EOF
}

resource "aws_iam_instance_profile" "terra_nginx_profile" {
  name = "terra_nginx_profile"
  role = aws_iam_role.allow_terra_nginx_s3.name
}

resource "aws_iam_role_policy" "allow_s3_all" {
  name = "allow_s3_all"
  role = aws_iam_role.allow_terra_nginx_s3.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": [
                "arn:aws:s3:::${local.s3_bucket_name}",
                "arn:aws:s3:::${local.s3_bucket_name}/*"
            ]
    }
  ]
}  
EOF
}
#################################################
#############       S3             ############## 
#################################################
resource "aws_s3_bucket" "terra_nginx_bucket" {
  bucket = local.s3_bucket_name
  acl = "private"
  force_destroy = true
  tags = merge(local.tags, { Name = "${var.env_tag}-terra_nginx_bucket"})
}

resource "aws_s3_bucket_object" "website" {
  bucket = aws_s3_bucket.terra_nginx_bucket.bucket
  key = "/website/index.html"
  source = "./index.html"
}

resource "aws_s3_bucket_object" "image" {
  bucket = aws_s3_bucket.terra_nginx_bucket.bucket
  key = "/website/web.png"
  source = "./web.png"
}

#################################################
#############       Output         ############## 
#################################################
output "aws_instance_public_dns" {
  value = aws_elb.terra_web.dns_name
}
