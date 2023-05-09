terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

/* Unfortunately, I feel I've run out of time to really pursue this option, so I'm abanoning it.
   The goal of establishing the VPC with subnets and ACLs was to isolate front-end (the API Gateway
   and queue lambda) from everything on the back-end such as Dyanmo and the persist lambda. I'm
   leaving it here for posterity. */

/* The idea is to setup a private VPC for our persistent storage; here's the VPC */
resource "aws_vpc" "fakecompany_data" {
  cidr_block = "10.1.0.0/16"

  tags = local.standard_tags
}

data "aws_subnet_ids" "fakecompany_data" {
  depends_on = [
    aws_vpc.fakecompany_data,
    aws_subnet.fakecompany_private_subnet
  ]
  vpc_id = aws_vpc.fakecompany_data.id
}

/* And the default ACL for the data VPC: */
resource "aws_default_network_acl" "fakecompany_data_default_acl" {
  default_network_acl_id = aws_vpc.fakecompany_data.default_network_acl_id
  subnet_ids             = data.aws_subnet_ids.fakecompany_data.ids
  tags                   = local.standard_tags

  ingress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

resource "aws_subnet" "fakecompany_private_subnet" {
  vpc_id            = aws_vpc.fakecompany_data.id
  cidr_block        = "10.1.0.0/16"
  availability_zone = "us-east-2a"

  tags = local.standard_tags
}
