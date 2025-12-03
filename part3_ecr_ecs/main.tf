provider "aws" {
  region = var.aws_region
}

resource "aws_ecr_repository" "flask" {
  name = "flask-app-repo"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "express" {
  name = "express-app-repo"
  image_scanning_configuration { scan_on_push = true }
}

# VPC + subnets (or use data to fetch default)
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "4.0.0"
  name = "ecs-vpc"
  cidr = "10.2.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names,0,2)
  public_subnets  = ["10.2.1.0/24","10.2.2.0/24"]
  enable_nat_gateway = false
}

resource "aws_lb" "alb" {
  name               = "tf-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress { from_port=0; to_port=0; protocol="-1"; cidr_blocks=["0.0.0.0/0"] }
}

# ECS cluster
resource "aws_ecs_cluster" "cluster" {
  name = "tf-ecs-cluster"
}

# IAM role for task execution (ECR, logs)
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}
data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement { actions = ["sts:AssumeRole"] principals { type = "Service" identifiers = ["ecs-tasks.amazonaws.com"] } }
}
resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch log groups
resource "aws_cloudwatch_log_group" "flask" { name = "/ecs/flask" retention_in_days = 7 }
resource "aws_cloudwatch_log_group" "express" { name = "/ecs/express" retention_in_days = 7 }

# Task definitions (Fargate)
resource "aws_ecs_task_definition" "flask" {
  family                   = "flask-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name = "flask"
      image = "${aws_ecr_repository.flask.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 5000, hostPort = 5000 }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.flask.name
          "awslogs-region" = var.aws_region
          "awslogs-stream-prefix" = "flask"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "express" {
  family                   = "express-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name = "express"
      image = "${aws_ecr_repository.express.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 3000 }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.express.name
          "awslogs-region" = var.aws_region
          "awslogs-stream-prefix" = "express"
        }
      }
    }
  ])
}

# Target groups
resource "aws_lb_target_group" "flask_tg" {
  name     = "flask-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
  health_check { path = "/", matcher = "200-399" }
}

resource "aws_lb_target_group" "express_tg" {
  name     = "express-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
  health_check { path = "/", matcher = "200-399" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.express_tg.arn
  }
}

# Create rules to forward /api to flask
resource "aws_lb_listener_rule" "api_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  action { type = "forward"; target_group_arn = aws_lb_target_group.flask_tg.arn }
  condition { path_pattern { values = ["/api/*"] } }
}

# Services (ECS)
resource "aws_ecs_service" "express_service" {
  name            = "express-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.express.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets = module.vpc.public_subnets
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.express_tg.arn
    container_name   = "express"
    container_port   = 3000
  }
  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "flask_service" {
  name            = "flask-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.flask.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets = module.vpc.public_subnets
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.flask_tg.arn
    container_name   = "flask"
    container_port   = 5000
  }
  depends_on = [aws_lb_listener.http]
}

resource "aws_security_group" "ecs_sg" {
  name   = "ecs-sg"
  vpc_id = module.vpc.vpc_id
  ingress { from_port=0; to_port=65535; protocol="tcp"; cidr_blocks=["0.0.0.0/0"] }
  egress { from_port=0; to_port=0; protocol="-1"; cidr_blocks=["0.0.0.0/0"] }
}

output "alb_dns" { value = aws_lb.alb.dns_name }
