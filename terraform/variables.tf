variable "environment" {
  type = string
}

variable "project" {
  type = string
}

variable "terraform_provider_role" {
  type = string
}

variable "terraform_lock_table_read_capacity" {
  default = 1
}

variable "terraform_lock_table_write_capacity" {
  default = 1
}

variable "codecommit_arn" {
  type = string
}

variable "codepipeline_arn" {
  type = string
}

variable "account_number" {
  type = string
}
