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

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

#################################################
#############       Data           ############## 
#################################################
#Gets the most recent ami id
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
resource "aws_default_vpc" "terra_test" {}

resource "aws_security_group" "allow_ssh" {
  name        = "terra_test_nginx"
  description = "Allow ports for testing nginx and terraform"
  vpc_id      = aws_default_vpc.terra_test.id

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
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "terra_nginx" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = ["sudo yum install nginx -y", "sudo service nginx start"]
  }
}


#################################################
#############       Output         ############## 
#################################################
output "aws_instance_public_dns" {
  value = aws_instance.terra_nginx.public_dns
}



