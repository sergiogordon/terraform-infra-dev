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

# Create a random ID for unique names
resource "random_id" "unique_id" {
  byte_length = 2  # Generate 2 bytes (4 hex digits)
}

# Create an IAM role for EC2 instances to assume for accessing SSM
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2_ssm_role-${substr(random_id.unique_id.hex, 0, 3)}"

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
  name = "ec2_ssm_profile-${substr(random_id.unique_id.hex, 0, 3)}"
  role = aws_iam_role.ec2_ssm_role.name
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
    description = "Allow SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP access"
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
resource "random_id" "unique_id_s3" {
  byte_length = 8
}

# Associate an Elastic IP address with the EC2 instance
resource "aws_eip" "web_eip" {
  instance = aws_instance.web.id
  domain   = "vpc"
}

# Output the public IP address of the Elastic IP
output "elastic_ip" {
  value = aws_eip.web_eip.public_ip
}

# Generate a random string for the bucket name suffix
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
  lower   = true
  numeric = true # Use 'numeric' instead of 'number'
}

# Create the S3 bucket with a valid name
resource "aws_s3_bucket" "terraform_bucket" {
  bucket = "tf-bucket-${formatdate("YYYYMMDD", timestamp())}-${random_string.bucket_suffix.result}"
}

# Set the bucket ownership controls to BucketOwnerEnforced
resource "aws_s3_bucket_ownership_controls" "terraform_bucket_ownership" {
  bucket = aws_s3_bucket.terraform_bucket.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block public access to the S3 bucket
resource "aws_s3_bucket_public_access_block" "terraform_bucket_public_access" {
  bucket = aws_s3_bucket.terraform_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
