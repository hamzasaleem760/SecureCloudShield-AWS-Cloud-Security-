provider "aws" {
  region = "eu-west-3" # Paris
}

# --- 0. ZERO TRUST UPGRADE: GET YOUR IP ---
# This automatically finds your laptop's public IP address
# We use this to lock the "Front Door" so only YOU can enter.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

# --- 1. AMI SELECTION (Amazon Linux 2023) ---
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# --- 2. KEYS (ED25519) ---
resource "tls_private_key" "pk" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated_key" {
  key_name   = "thesis-key-zero-trust"
  public_key = tls_private_key.pk.public_key_openssh
}

resource "local_file" "ssh_key" {
  content  = tls_private_key.pk.private_key_openssh
  filename = "${path.module}/thesis_key.pem"
}

# --- 3. VPC & Network ---
resource "aws_vpc" "secure_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "SecureCloudShield-VPC" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.secure_vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.secure_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-3a"
  tags = { Name = "Public-Subnet-DMZ" }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.secure_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-3a"
  tags = { Name = "Private-Subnet-Secure" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.secure_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# --- 4. ZERO TRUST SECURITY GROUPS (UPDATED) ---

resource "aws_security_group" "bastion_sg" {
  name        = "bastion_sg_strict"
  description = "Bastion SG with Zero Trust Ingress"
  vpc_id      = aws_vpc.secure_vpc.id

  # INGRESS: Allow SSH ONLY from YOUR Laptop
  # This replaces the "0.0.0.0/0" rule
  ingress {
    description = "SSH from Admin Laptop Only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
  }

  # EGRESS: Allow SSH to Private Subnet (So you can jump)
  egress {
    description = "Allow SSH to Private Subnet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.2.0/24"]
  }

  # EGRESS: Allow HTTPS (443) and HTTP (80) to Internet
  # Necessary for installing tools like Nmap/Git during your demo
  egress {
    description = "Allow HTTPS for updates/tools"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allow HTTP for updates/tools"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "private_sg" {
  name        = "private_sg_strict"
  description = "Private SG - No Outbound Internet Access"
  vpc_id      = aws_vpc.secure_vpc.id

  # INGRESS: Allow SSH ONLY from Bastion
  ingress {
    description     = "SSH from Bastion Only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  # EGRESS: BLOCKED
  # We leave this empty to strictly block all outbound traffic.
  # This ensures the server is a "Vault" - data can't leak out.
}

# --- 5. EC2 Instances ---
resource "aws_instance" "bastion" {
  ami             = data.aws_ami.amazon_linux.id
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.bastion_sg.id]
  key_name        = aws_key_pair.generated_key.key_name
  tags            = { Name = "Bastion-ZeroTrust" }
}

resource "aws_instance" "private_app" {
  ami             = data.aws_ami.amazon_linux.id
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.private_subnet.id
  security_groups = [aws_security_group.private_sg.id]
  key_name        = aws_key_pair.generated_key.key_name
  tags            = { Name = "Private-ZeroTrust" }
}

# --- 6. OUTPUT ---
output "bastion_ip" {
  value = aws_instance.bastion.public_ip
}
output "private_ip" {
  value = aws_instance.private_app.private_ip
}

# --- 7. ALERTS ---
resource "aws_sns_topic" "security_alerts" {
  name = "guardduty-security-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "hamza-bin.saleem@epita.fr"
}

resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "capture-all-guardduty-findings"
  description = "Capture ALL GuardDuty findings"

  event_pattern = jsonencode({
    "source": ["aws.guardduty"],
    "detail-type": ["GuardDuty Finding"]
  })
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.security_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}