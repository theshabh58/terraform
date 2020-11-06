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
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
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
resource "aws_vpc" "terra_vpc" {
  cidr_block           = var.network_address_space
  enable_dns_hostnames = "true"
}

resource "aws_internet_gateway" "terra_igw" {
  vpc_id = aws_vpc.terra_vpc.id
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

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = self.public_ip
    private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "echo '<html><head><title>Blue Team Server</title></head><body style=\"background-color:#1F778D\"><p style=\"text-align: center;\"><span style=\"color:#FFFFFF;\"><span style=\"font-size:28px;\">Blue Team</span></span></p></body></html>' | sudo tee /usr/share/nginx/html/index.html"
    ]
  }
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

  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "echo '<html><head><title>Green Team Server</title></head><body style=\"background-color:#16a596\"><p style=\"text-align: center;\"><span style=\"color:#FFFFFF;\"><span style=\"font-size:28px;\">Green Team</span></span></p></body></html>' | sudo tee /usr/share/nginx/html/index.html"
    ]
  }
}

#################################################
#############       Output         ############## 
#################################################
output "aws_instance_public_dns" {
  value = aws_elb.terra_web.dns_name
}
