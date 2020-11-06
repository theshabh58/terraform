# Terraform Configurations
* Contains a terraform configurations for aws using a default VPC - **default_vpc**
  * Spins up an EC2 instance with an Nginx Configuration that has a public facing IP.
* Contains a terraform configuration for creating a vpc from scratch in aws - **vpc**
  * Spins up two load balanced EC2 instances with Elastic Load Balancer.
  * Each EC2 instance is displaying a seprate index.html using nginx. 
