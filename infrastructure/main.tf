terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "Tauri-Container"
      Environment = "Production"
      ManagedBy   = "Terraform"
    }
  }
}

# =========================================================================
# CONFIGURATION
# =========================================================================
locals {
  # TODO: PASTE YOUR ECR URI HERE (e.g. "123456789.dkr.ecr.us-east-1...")
  app_image = "211125784576.dkr.ecr.us-east-1.amazonaws.com/tauri-container" 
  
  # Set to true if you have an SSL Certificate ARN ready
  use_https = false 
  cert_arn  = "" # e.g. "arn:aws:acm:us-east-1:12345:certificate/..."
}

# =========================================================================
# 1. NETWORK LAYER (VPC)
# =========================================================================
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "tauri-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  # Public Subnets: Hold the Load Balancer and NAT Gateway
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  # Private Subnets: Hold the Rust Containers (Secure Zone)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # CRITICAL: Private subnets need a NAT Gateway to pull Docker images from ECR.
  # COST WARNING: ~$0.045/hour (~$32/month). 
  enable_nat_gateway = true
  single_nat_gateway = true # Keeps costs down (1 NAT instead of 2)
}

# =========================================================================
# 2. SECURITY GROUPS (The Firewall)
# =========================================================================

# ALB Security Group: The "Front Door"
resource "aws_security_group" "alb_sg" {
  name        = "tauri-alb-sg"
  description = "Allow web traffic to Load Balancer"
  vpc_id      = module.vpc.vpc_id

  # Allow HTTP (80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS (443) - Always open even if not used yet
  ingress {
    from_port   = 443
    to_port     = 443
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

# ECS Security Group: The "VIP Room"
resource "aws_security_group" "ecs_sg" {
  name        = "tauri-ecs-sg"
  description = "Allow traffic ONLY from ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    # SECURITY: Only accept connections originating from the ALB
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================================================================
# 3. APPLICATION LOAD BALANCER (ALB)
# =========================================================================
resource "aws_lb" "main" {
  name               = "tauri-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "app_tg" {
  name        = "tauri-rust-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip" # Required for Fargate

  health_check {
    path                = "/health" # Must match your Rust route
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Listener: HTTP (Redirects to HTTPS if cert exists, else forwards)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = local.use_https ? "redirect" : "forward"
    
    # If HTTPS is enabled, redirect HTTP -> HTTPS
    dynamic "redirect" {
      for_each = local.use_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    # If HTTPS is disabled, just forward traffic to app
    target_group_arn = local.use_https ? null : aws_lb_target_group.app_tg.arn
  }
}

# Listener: HTTPS (Only created if use_https = true)
resource "aws_lb_listener" "https" {
  count             = local.use_https ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = local.cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# =========================================================================
# 4. ECS FARGATE (The Compute)
# =========================================================================
resource "aws_ecs_cluster" "main" {
  name = "tauri-cluster"
  
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "tauri-rust-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256 # .25 vCPU
  memory                   = 512 # .5 GB
  execution_role_arn       = aws_iam_role.ecs_exec_role.arn

  container_definitions = jsonencode([
    {
      name      = "rust-app"
      image     = local.app_image
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/tauri-rust"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "main" {
  name            = "tauri-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1 # Start with 1 to save money. Scale to 2+ for Prod.
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets # The Secure Zone
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = false # Strictly Private
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "rust-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}

# =========================================================================
# 5. LOGGING & PERMISSIONS
# =========================================================================
resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/tauri-rust"
  retention_in_days = 7
}

resource "aws_iam_role" "ecs_exec_role" {
  name = "tauri-ecs-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# =========================================================================
# 6. OUTPUTS
# =========================================================================
output "alb_dns_name" {
  value = aws_lb.main.dns_name
  description = "Your Enterprise API Endpoint"
}