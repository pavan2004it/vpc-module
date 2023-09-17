locals {
  len_public_subnets      = max(length(var.public_subnets), length(var.public_subnet_ipv6_prefixes))
  len_private_subnets     = max(length(var.private_subnets), length(var.private_subnet_ipv6_prefixes))
  len_database_subnets    = max(length(var.database_subnets), length(var.database_subnet_ipv6_prefixes))
  len_alb_subnets         = max(length(var.alb_subnets), length(var.alb_subnet_ipv6_prefixes))
  len_azdo_subnets        = max(length(var.azdo_subnets), length(var.azdo_subnet_ipv6_prefixes))
  len_firewall_subnets =  max(length(var.firewall_subnets), length(var.firewall_subnet_ipv6_prefixes))

  max_subnet_length = max(
    local.len_private_subnets,
    local.len_public_subnets,
    local.len_database_subnets,
    local.len_alb_subnets,
    local.len_azdo_subnets,
    local.len_firewall_subnets
  )

  # Use `local.vpc_id` to give a hint to Terraform that subnets should be deleted before secondary CIDR blocks can be free!
  vpc_id = try(aws_vpc_ipv4_cidr_block_association.this[0].vpc_id, aws_vpc.this[0].id, "")

  create_vpc = var.create_vpc
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0
  cidr_block          = var.use_ipam_pool ? null : var.vpc_cidr
  ipv4_ipam_pool_id   = var.ipv4_ipam_pool_id
  ipv4_netmask_length = var.ipv4_netmask_length

  assign_generated_ipv6_cidr_block     = var.enable_ipv6 && !var.use_ipam_pool ? true : null
  ipv6_cidr_block                      = var.ipv6_cidr
  ipv6_ipam_pool_id                    = var.ipv6_ipam_pool_id
  ipv6_netmask_length                  = var.ipv6_netmask_length
  ipv6_cidr_block_network_border_group = var.ipv6_cidr_block_network_border_group

  instance_tenancy                     = var.instance_tenancy
  enable_dns_hostnames                 = var.enable_dns_hostnames
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.vpc_tags,
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "this" {
  count = local.create_vpc && length(var.secondary_cidr_blocks) > 0 ? length(var.secondary_cidr_blocks) : 0

  # Do not turn this into `local.vpc_id`
  vpc_id = aws_vpc.this[0].id

  cidr_block = element(var.secondary_cidr_blocks, count.index)
}

################################################################################
# DHCP Options Set
################################################################################

resource "aws_vpc_dhcp_options" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  domain_name          = var.dhcp_options_domain_name
  domain_name_servers  = var.dhcp_options_domain_name_servers
  ntp_servers          = var.dhcp_options_ntp_servers
  netbios_name_servers = var.dhcp_options_netbios_name_servers
  netbios_node_type    = var.dhcp_options_netbios_node_type

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.dhcp_options_tags,
  )
}

resource "aws_vpc_dhcp_options_association" "this" {
  count = local.create_vpc && var.enable_dhcp_options ? 1 : 0

  vpc_id          = local.vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.this[0].id
}

################################################################################
# Publiс Subnets
################################################################################

locals {
  create_public_subnets = local.create_vpc && local.len_public_subnets > 0
}

resource "aws_subnet" "public" {
  count = local.create_public_subnets && (!var.one_nat_gateway_per_az || local.len_public_subnets >= length(var.azs)) ? local.len_public_subnets : 0

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.public_subnet_ipv6_native ? true : var.public_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.public_subnet_ipv6_native ? null : element(concat(var.public_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.public_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.public_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.public_subnet_ipv6_native && var.public_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.public_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.public_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.public_subnet_ipv6_native
  map_public_ip_on_launch                        = var.map_public_ip_on_launch
  private_dns_hostname_type_on_launch            = var.public_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.public_subnet_names[count.index],
        format("${var.name}-${var.public_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.public_subnet_tags,
    lookup(var.public_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

resource "aws_route_table_association" "public-association" {
  count = local.create_public_subnets ? local.len_public_subnets : 0
  subnet_id = element(aws_subnet.public[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.protected_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
}


################################################################################
# Public Network ACLs
################################################################################

resource "aws_network_acl" "public" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? 1 : 0

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.public[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.public_subnet_suffix}" },
    var.tags,
    var.public_acl_tags,
  )
}

resource "aws_network_acl_rule" "public_inbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress          = false
  rule_number     = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "public_outbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress          = true
  rule_number     = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Private Subnets
################################################################################

locals {
  create_private_subnets = local.create_vpc && local.len_private_subnets > 0
}

resource "aws_subnet" "private" {
  count = local.create_private_subnets ? local.len_private_subnets : 0

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.private_subnet_ipv6_native ? true : var.private_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.private_subnet_ipv6_native ? null : element(concat(var.private_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.private_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.private_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.private_subnet_ipv6_native && var.private_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.private_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.private_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.private_subnet_names[count.index],
        format("${var.name}-${var.private_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.private_subnet_tags,
    lookup(var.private_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

resource "aws_route_table" "private_route_table" {
  count = var.create_private_subnet_route_table ? 1 : 0

  vpc_id = local.vpc_id

  tags = {
    "Name" = "Private-RT"
  }
}

resource "aws_route_table_association" "private-association" {
  count = local.create_private_subnets ? local.len_private_subnets : 0
  subnet_id      = element(aws_subnet.private[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.private_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
}

resource "aws_route" "private_route" {
  count = length(var.private_routes)
  route_table_id = element(
    coalescelist(aws_route_table.private_route_table[*].id),
    var.create_private_subnet_route_table ? 1: 0,
  )
  destination_cidr_block = var.private_routes[count.index].destination_cidr_block
  gateway_id = var.private_routes[count.index].gateway_id
  vpc_endpoint_id = var.private_routes[count.index].endpoint_id
}

################################################################################
# Private Network ACLs
################################################################################

locals {
  create_private_network_acl = local.create_private_subnets && var.private_dedicated_network_acl
}

resource "aws_network_acl" "private" {
  count = local.create_private_network_acl ? 1 : 0

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.private[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.private_subnet_suffix}" },
    var.tags,
    var.private_acl_tags,
  )
}

resource "aws_network_acl_rule" "private_inbound" {
  count = local.create_private_network_acl ? length(var.private_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress          = false
  rule_number     = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "private_outbound" {
  count = local.create_private_network_acl ? length(var.private_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress          = true
  rule_number     = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# AZDO Subnets
################################################################################

locals {
  create_azdo_subnets     = local.create_vpc && local.len_azdo_subnets > 0
  create_azdo_route_table = local.create_azdo_subnets && var.create_azdo_subnet_route_table
}

resource "aws_subnet" "azdo" {
  count = local.create_azdo_subnets ? local.len_azdo_subnets : 0

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.azdo_subnet_ipv6_native ? true : var.azdo_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.azdo_subnet_ipv6_native ? null : element(concat(var.azdo_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.azdo_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.azdo_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.azdo_subnet_ipv6_native && var.azdo_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.azdo_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.azdo_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.azdo_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.azdo_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.azdo_subnet_names[count.index],
        format("${var.name}-${var.azdo_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.azdo_subnet_tags,
  )
}

resource "aws_route_table_association" "azdo-association" {
  count = local.create_azdo_subnets ? local.len_azdo_subnets : 0
  subnet_id = element(aws_subnet.azdo[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.protected_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
}

################################################################################
# ALB Subnets
################################################################################


locals {
  create_alb_subnets     = local.create_vpc && local.len_alb_subnets > 0
  create_alb_route_table = var.create_alb_subnets && var.create_alb_subnet_route_table
}

resource "aws_subnet" "alb" {

  count = var.create_alb_subnets ? local.len_alb_subnets : 0
  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.alb_subnet_ipv6_native ? true : var.alb_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.alb_subnet_ipv6_native ? null : element(concat(var.alb_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.alb_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.alb_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.alb_subnet_ipv6_native && var.alb_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.alb_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.alb_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.alb_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.alb_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.alb_subnet_names[count.index],
        format("${var.name}-${var.alb_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.alb_subnet_tags,
  )
}

resource "aws_route_table" "protected_route_table" {
  depends_on = [aws_networkfirewall_firewall.rp-firewall]
  count = var.create_protected_route_table ? 1 : 0

  vpc_id = local.vpc_id

  tags = {
    "Name" = "Protected-RT"
  }
}

resource "aws_route_table_association" "protected-association" {
  count = local.create_alb_subnets ? local.len_alb_subnets : 0
  subnet_id = element(aws_subnet.alb[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.protected_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
}

resource "aws_route" "protected_route" {
  count = length(var.protected_routes)
  route_table_id = element(
    coalescelist(aws_route_table.protected_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
  destination_cidr_block = var.protected_routes[count.index].destination_cidr_block
  vpc_endpoint_id = var.protected_routes[count.index].endpoint_id
  gateway_id = var.protected_routes[count.index].gateway_id
}

################################################################################
# firewall Subnets
################################################################################


locals {
  create_firewall_subnets     = local.create_vpc && local.len_firewall_subnets > 0
  create_firewall_route_table = local.create_firewall_subnets && var.create_firewall_subnet_route_table
}

resource "aws_subnet" "firewall" {
  count = local.create_firewall_subnets ? local.len_firewall_subnets : 0

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.firewall_subnet_ipv6_native ? true : var.firewall_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.firewall_subnet_ipv6_native ? null : element(concat(var.firewall_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.firewall_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.firewall_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.firewall_subnet_ipv6_native && var.firewall_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.firewall_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.firewall_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.firewall_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.firewall_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.firewall_subnet_names[count.index],
        format("${var.name}-${var.firewall_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.firewall_subnet_tags,
  )
}

resource "aws_route_table" "firewall_route_table" {
  count = local.create_firewall_route_table  ? 1 : 0
  vpc_id = local.vpc_id
  tags = {
    "Name" = "Firewall-RT"
  }
}

resource "aws_route_table_association" "firewall-association" {
  count = local.create_firewall_subnets ? local.len_firewall_subnets : 0

  subnet_id = element(aws_subnet.firewall[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.firewall_route_table[*].id),
    var.create_firewall_subnet_route_table ? 1: 0,
  )
}

resource "aws_route" "firewall_route" {
  count = length(var.firewall_routes)
  route_table_id = aws_route_table.firewall_route_table[0].id
  destination_cidr_block = var.firewall_routes[count.index].destination_cidr_block
  gateway_id = aws_internet_gateway.this[0].id
}

################################################################################
# Database Subnets
################################################################################

locals {
  create_database_subnets     = local.create_vpc && local.len_database_subnets > 0
  create_database_route_table = local.create_database_subnets && var.create_database_subnet_route_table
}

resource "aws_subnet" "database" {
  count = local.create_database_subnets ? local.len_database_subnets : 0

  assign_ipv6_address_on_creation                = var.enable_ipv6 && var.database_subnet_ipv6_native ? true : var.database_subnet_assign_ipv6_address_on_creation
  availability_zone                              = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id                           = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  cidr_block                                     = var.database_subnet_ipv6_native ? null : element(concat(var.database_subnets, [""]), count.index)
  enable_dns64                                   = var.enable_ipv6 && var.database_subnet_enable_dns64
  enable_resource_name_dns_aaaa_record_on_launch = var.enable_ipv6 && var.database_subnet_enable_resource_name_dns_aaaa_record_on_launch
  enable_resource_name_dns_a_record_on_launch    = !var.database_subnet_ipv6_native && var.database_subnet_enable_resource_name_dns_a_record_on_launch
  ipv6_cidr_block                                = var.enable_ipv6 && length(var.database_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.database_subnet_ipv6_prefixes[count.index]) : null
  ipv6_native                                    = var.enable_ipv6 && var.database_subnet_ipv6_native
  private_dns_hostname_type_on_launch            = var.database_subnet_private_dns_hostname_type_on_launch
  vpc_id                                         = local.vpc_id

  tags = merge(
    {
      Name = try(
        var.database_subnet_names[count.index],
        format("${var.name}-${var.database_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.database_subnet_tags,
  )
}

resource "aws_db_subnet_group" "database" {
  count = local.create_database_subnets && var.create_database_subnet_group ? 1 : 0

  name        = lower(coalesce(var.database_subnet_group_name, var.name))
  description = "Database subnet group for ${var.name}"
  subnet_ids  = aws_subnet.database[*].id

  tags = merge(
    {
      "Name" = lower(coalesce(var.database_subnet_group_name, var.name))
    },
    var.tags,
    var.database_subnet_group_tags,
  )
}

resource "aws_route_table" "db_route_table" {
  count = var.create_db_subnet_route_table ? 1 : 0

  vpc_id = local.vpc_id

  tags = {
    "Name" = "DB-RT"
  }
}

resource "aws_route_table_association" "db-association" {
  count = local.create_alb_subnets ? local.len_alb_subnets : 0
  subnet_id      = element(aws_subnet.database[*].id, count.index)
  route_table_id = element(
    coalescelist(aws_route_table.db_route_table[*].id),
    var.create_protected_route_table ? 1: 0,
  )
}

resource "aws_route" "db_route" {
  count = length(var.db_routes)
  route_table_id = element(
    coalescelist(aws_route_table.db_route_table[*].id),
    var.create_database_subnet_route_table ? 1: 0,
  )
  destination_cidr_block = var.db_routes[count.index].destination_cidr_block
  gateway_id = var.db_routes[count.index].gateway_id
}

################################################################################
# Database Network ACLs
################################################################################

locals {
  create_database_network_acl = local.create_database_subnets && var.database_dedicated_network_acl
}

resource "aws_network_acl" "database" {
  count = local.create_database_network_acl ? 1 : 0

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.database[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.database_subnet_suffix}" },
    var.tags,
    var.database_acl_tags,
  )
}

resource "aws_network_acl_rule" "database_inbound" {
  count = local.create_database_network_acl ? length(var.database_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.database[0].id

  egress          = false
  rule_number     = var.database_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.database_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.database_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.database_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.database_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.database_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.database_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.database_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.database_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "database_outbound" {
  count = local.create_database_network_acl ? length(var.database_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.database[0].id

  egress          = true
  rule_number     = var.database_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.database_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.database_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.database_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.database_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.database_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.database_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.database_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.database_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

################################################################################
# Network Firewall
################################################################################

resource "aws_networkfirewall_firewall" "rp-firewall" {
  name                = "rp-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.rp-policy.arn
  vpc_id              = aws_vpc.this[0].id

  subnet_mapping {
    subnet_id = aws_subnet.firewall[0].id
  }
}

resource "aws_networkfirewall_firewall_policy" "rp-policy" {
  name = var.rule_policy_name

  firewall_policy {
    stateless_default_actions = ["aws:pass"]
    stateless_fragment_default_actions = ["aws:drop"]
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.rp_rule_group.arn
    }
  }
}

# Ensure you associate this rule group with a firewall policy and the firewall.
resource "aws_networkfirewall_rule_group" "rp_rule_group" {
  capacity = var.rule_group_capacity
  name     = var.rule_group_name
  type     = var.rule_group_type
  dynamic "rule_group" {
    for_each = var.stateful_rule_group
    content {
      dynamic "rule_variables"{
        for_each = try([rule_group.value.rule_variables], [])
        content {
          dynamic "ip_sets" {
            for_each = try(rule_variables.value.ip_sets, [])
            content {
              key = ip_sets.value.key
              dynamic "ip_set" {
                for_each = [ip_sets.value.ip_set]
                content {
                  definition = ip_set.value.definition
                }
              }
            }
          }
          dynamic "port_sets" {
            for_each = try(rule_variables.value.port_sets, [])
            content {
              key = port_sets.value.key
              dynamic "port_set" {
                for_each = [port_sets.value.port_set]
                content {
                  definition = port_set.value.definition
                }
              }
            }
          }
          }
        }
        rules_source {
          rules_string = var.suricata_file
        }
      }
    }
  }


################################################################################
# Route Tables
################################################################################



resource "aws_route_table" "ingress_igw_route_table" {
  count  = var.create_ingress_route_table ?  1 : 0
  vpc_id = local.vpc_id
  tags   = {
    "Name" = "Ingress-IGW-RT"
  }
}

resource "aws_route_table_association" "ingress-igw-association" {
  count = local.create_alb_subnets ? local.len_alb_subnets : 0
  route_table_id = element(
    coalescelist(aws_route_table.ingress_igw_route_table[*].id),
    var.create_alb_subnet_route_table ? 1: 0,
  )
  gateway_id = aws_internet_gateway.this[0].id
}

resource "aws_route" "ingress-igw-route" {
  count = length(var.ingress_igw_routes)
  route_table_id = element(
    coalescelist(aws_route_table.ingress_igw_route_table[*].id),
    var.create_ingress_route_table ? 1: 0,
  )
  destination_cidr_block = var.ingress_igw_routes[count.index].destination_cidr_block
  vpc_endpoint_id = var.ingress_igw_routes[count.index].endpoint_id
}


################################################################################
# NAT Gateway
################################################################################

resource "aws_eip" "nat_ip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "rp-nat" {
  subnet_id = aws_subnet.public[0].id
  connectivity_type = "public"
  allocation_id = aws_eip.nat_ip.id
  tags = {
    "Name" = "Rp-Central-Nat-Gwy"
  }
}

resource "aws_route" "nat_route" {
  route_table_id = aws_route_table.private_route_table[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.rp-nat.id
}


################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "this" {
  count = local.create_public_subnets && var.create_igw ? 1 : 0

  vpc_id = local.vpc_id

  tags = {
    "Name" = "RP-IGW-NF"
  }
}

################################################################################
# Customer Gateways
################################################################################

resource "aws_customer_gateway" "this" {
  for_each = var.customer_gateways

  bgp_asn     = each.value["bgp_asn"]
  ip_address  = each.value["ip_address"]
  device_name = lookup(each.value, "device_name", null)
  type        = "ipsec.1"

  tags = each.value["tags"]
}

################################################################################
# VPN Gateway
################################################################################

resource "aws_vpn_gateway" "this" {
  count = local.create_vpc && var.enable_vpn_gateway ? 1 : 0

  vpc_id            = local.vpc_id
  amazon_side_asn   = var.amazon_side_asn
  availability_zone = var.vpn_gateway_az

  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.vpn_gateway_tags,
  )
}

resource "aws_vpn_gateway_attachment" "this" {
  count = var.vpn_gateway_id != "" ? 1 : 0

  vpc_id         = local.vpc_id
  vpn_gateway_id = var.vpn_gateway_id
}

resource "aws_vpn_gateway_route_propagation" "protected" {
  count = local.create_vpc && var.enable_vpn_gateway  ? 1 : 0

  route_table_id = element(aws_route_table.protected_route_table[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count = local.create_vpc && var.enable_vpn_gateway  ? 1 : 0

  route_table_id = element(aws_route_table.private_route_table[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "db" {
  count = local.create_vpc && var.enable_vpn_gateway  ? 1 : 0

  route_table_id = element(aws_route_table.db_route_table[*].id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this[*].id,
      aws_vpn_gateway_attachment.this[*].vpn_gateway_id,
    ),
    count.index,
  )
}


################################################################################
# VPN Connection
################################################################################

resource "aws_vpn_connection" "vpn-connections" {
  for_each = var.vpn_connections
  type = each.value["type"]
  static_routes_only = each.value["static_routes_only"]
  customer_gateway_id = each.value["customer_gateway_id"]
  vpn_gateway_id = each.value["vpn_gateway_id"]
  tags = each.value["tags"]
}

resource "aws_vpn_connection_route" "vpn_connection_routes" {
  for_each = var.aws_vpn_connection_routes
  destination_cidr_block = each.value["destination_cidr_block"]
  vpn_connection_id = each.value["vpn_connection_id"]
}