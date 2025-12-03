provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "tf-vpc" }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags = { Name = "tf-subnet-a" }
}

data "aws_availability_zones" "available" {}

# Internet Gateway & Route table
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# Security groups
resource "aws_security_group" "flask_sg" {
  name   = "flask-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=22; to_port=22; protocol="tcp"; cidr_blocks=[var.my_ip_cidr] }
  ingress { from_port=5000; to_port=5000; protocol="tcp"; cidr_blocks=["0.0.0.0/0"] }
  egress  { from_port=0; to_port=0; protocol="-1"; cidr_blocks=["0.0.0.0/0"] }
}

resource "aws_security_group" "express_sg" {
  name   = "express-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port=22; to_port=22; protocol="tcp"; cidr_blocks=[var.my_ip_cidr] }
  ingress { from_port=3000; to_port=3000; protocol="tcp"; cidr_blocks=["0.0.0.0/0"] }
  # allow express to call flask (if needed)
  ingress { from_port=5000; to_port=5000; protocol="tcp"; security_groups=[aws_security_group.flask_sg.id] }
  egress  { from_port=0; to_port=0; protocol="-1"; cidr_blocks=["0.0.0.0/0"] }
}

# Key pair
resource "aws_key_pair" "deployer" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# Flask EC2
resource "aws_instance" "flask" {
  ami = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.flask_sg.id]
  key_name = aws_key_pair.deployer.key_name
  associate_public_ip_address = true
  user_data = file("${path.module}/user_data_flask.sh")
  tags = { Name = "flask-server" }
}

# Express EC2
resource "aws_instance" "express" {
  ami = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.express_sg.id]
  key_name = aws_key_pair.deployer.key_name
  associate_public_ip_address = true
  user_data = file("${path.module}/user_data_express.sh")
  tags = { Name = "express-server" }
}

output "flask_public_ip" { value = aws_instance.flask.public_ip }
output "express_public_ip" { value = aws_instance.express.public_ip }
