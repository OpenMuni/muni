terraform {
  required_version = ">= 1.10, < 2.0"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.69.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project_name, Component = "accounts", ManagedBy = "terraform" }
  }
}
