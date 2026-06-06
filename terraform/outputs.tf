output "public_ip" {
  value       = aws_eip.k3s.public_ip
  description = "Add this IP to MongoDB Atlas Network Access"
}

output "frontend_url" {
  value = "http://${aws_eip.k3s.public_ip}"
}

output "ssh_command" {
  value = "ssh -i terraform/devops-case-key.pem ec2-user@${aws_eip.k3s.public_ip}"
}
