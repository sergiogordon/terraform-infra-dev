terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.51.0"
    }
  }
}

# Configure the AWS provider with the desired region
provider "aws" {
  region = "us-east-2"
}

# Create an IAM role for EC2 instances to assume for accessing SSM
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2_ssm_role"

  # Define the policy that allows EC2 instances to assume the role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the AWS Systems Manager Managed Instance Core policy to the EC2 SSM role
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an EC2 instance with the following configuration:
resource "aws_instance" "web" {
  ami           = "ami-09040d770ffe2224f"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y nginx
              snap install amazon-ssm-agent --classic
              systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent
              systemctl start snap.amazon-ssm-agent.amazon-ssm-agent
              echo 'Hello world, this was deployed via Terraform Cloud!' > /var/www/html/index.html
              systemctl start nginx
              systemctl enable nginx
  EOF

  # Tag the instance with a name for easy identification
  tags = {
    Name = "web-server"
  }
}

# Create an IAM instance profile to associate with the EC2 instance
resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "ec2_ssm_profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# Create an S3 bucket with a unique name
resource "aws_s3_bucket" "terraform_bucket" {
  bucket = "sg-terraformbucket-${formatdate("YYYYMMDD", timestamp())}-${random_id.unique_id.hex}"
}

# Set the ACL for the S3 bucket
resource "aws_s3_bucket_acl" "terraform_bucket_acl" {
  bucket = aws_s3_bucket.terraform_bucket.id
  acl    = "private"
}

# Create a VPC with a specific CIDR block
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # Tag the VPC for identification
  tags = {
    Name = "main-vpc"
  }
}

# Create a public subnet within the VPC
resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block  = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

# Create an internet gateway to connect the VPC to the internet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  # Tag the internet gateway for identification
  tags = {
    Name = "main-gateway"
  }
}

# Create a route table for the public subnet
resource "aws_route_table" "public" {
  vpc_id     = aws_vpc.main.id

  # Route all traffic to the internet gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  # Tag the route table for identification
  tags = {
    Name = "public-route-table"
  }
}

# Associate the public route table with the public subnet
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Allow SSH and HTTP traffic to the EC2 instance
resource "aws_security_group" "allow_ssh_http" {
  vpc_id      = aws_vpc.main.id

  # Allow SSH and HTTP traffic from anywhere
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tag the security group for identification
  tags = {
    Name = "allow_ssh_http"
  }
}

# Create a random ID for the S3 bucket
resource "random_id" "unique_id" {
  byte_length = 8
}

# Associate an Elastic IP address with the EC2 instance
resource "aws_eip" "web_eip" {
  instance = aws_instance.web.id
  domain   = "vpc"
}

# Output the public IP address of the EC2 instance
output "instance_public_ip" {
  value = aws_instance.web.public_ip
}

# Output the public IP address of the Elastic IP
output "elastic_ip" {
  value = aws_eip.web_eip.public_ip
}

# Deploying terraform bucket for todays date and adding suffix
resource "aws_s3_bucket" "terraform_bucket" {
  bucket = "sg-terraformbucket-${formatdate("YYYYMMDD", timestamp())}-${random_id.unique_id.id}"
}

# Set the ACL for the S3 bucket
resource "aws_s3_bucket_acl" "terraform_bucket_acl" {
  bucket = aws_s3_bucket.terraform_bucket.id
  acl    = "private"
}
