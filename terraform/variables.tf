variable "region" {
  description = "AWS region"
  default     = "eu-central-1"
}

variable "your_ip" {
  description = "Your public IP for SSH access. Run: curl ifconfig.me"
  type        = string
}
