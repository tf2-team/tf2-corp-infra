output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID của VPC"
}

output "vpc_cidr_block" {
  value       = aws_vpc.this.cidr_block
  description = "CIDR block của VPC"
}

output "internet_gateway_id" {
  value       = aws_internet_gateway.this.id
  description = "ID của Internet Gateway"
}

# ── Public Subnets ──

output "public_subnet_ids" {
  value       = { for k, v in aws_subnet.public : k => v.id }
  description = "Bản đồ ID các Public Subnet (key = tên ngắn)"
}

output "public_subnet_ids_list" {
  value       = [for v in aws_subnet.public : v.id]
  description = "Danh sách ID các Public Subnet (dùng khi cần list, vd: EKS, ALB)"
}

# ── Private Subnets ──

output "private_subnet_ids" {
  value       = { for k, v in aws_subnet.private : k => v.id }
  description = "Bản đồ ID các Private Subnet (key = tên ngắn)"
}

output "private_subnet_ids_list" {
  value       = [for v in aws_subnet.private : v.id]
  description = "Danh sách ID các Private Subnet (dùng cho EKS worker node groups)"
}

output "private_subnet_cidrs" {
  value       = { for k, v in aws_subnet.private : k => v.cidr_block }
  description = "Map of private subnet CIDR blocks by key"
}

output "karpenter_subnet_ids" {
  value = {
    for k, v in aws_subnet.private : k => v.id
    if try(var.private_subnets[k].enable_karpenter_discovery, true)
  }
  description = "Private subnets with karpenter.sh/discovery enabled (node launch candidates)"
}

# ── NAT Gateways ──

output "nat_gateway_ids" {
  value       = { for k, v in aws_nat_gateway.this : k => v.id }
  description = "Bản đồ ID các NAT Gateway (key = tên ngắn)"
}

output "nat_gateway_public_ips" {
  value       = { for k, v in aws_eip.nat : k => v.public_ip }
  description = "Bản đồ địa chỉ IP public của các NAT Gateway (dùng để whitelist phía ngoài)"
}
# Change trail: @hungxqt - 2026-07-14 - Large /20 node subnets for VPC CNI prefix IP headroom.
