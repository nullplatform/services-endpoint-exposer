terraform {
  backend "s3" {
    key = "endpoint-exposer/install/terraform.tfstate"
  }
}
