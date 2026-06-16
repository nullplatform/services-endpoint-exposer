terraform {
  required_providers {
    nullplatform = {
      source  = "nullplatform/nullplatform"
      version = ">= 0.0.67, < 0.1.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "nullplatform" {
  api_key = var.np_api_key
}

provider "github" {
  token = var.github_token
}
