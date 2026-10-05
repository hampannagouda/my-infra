data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "demo" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
  }

  tags = {
    Name      = var.instance_name
    ManagedBy = "terraform"
  }
}