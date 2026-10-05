output "instance_id" {
  value = aws_instance.demo.id
}

output "private_ip" {
  value = aws_instance.demo.private_ip
}