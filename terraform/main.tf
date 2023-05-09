locals {
  // Tags we'll add to all resources
  standard_tags = {
    project     = var.project,
    environment = var.environment
  }

  // We can imagine having multiple workspaces here, Dev, QA, Prod, etc.
  env = terraform.workspace
}

// Setup terraform; the provider role is configured in Secrets Manager:
provider "aws" {
  region  = "us-east-2"
  profile = "deploy"
  alias   = "deploy"
  assume_role {
    role_arn     = var.terraform_provider_role
    session_name = "terraform"
  }
}

/* If this were a larger project and not a take home test, I'd have
   several environments as stated above. For now, we'll define a single
   profile, 'prod' that we can later change if needed. */
provider "aws" {
  region  = "us-east-2"
  alias   = "prod"
  profile = "prod"
}

data "aws_iam_account_alias" "current" {
  provider = aws.prod
}

/* This configuration was set after we manually created an S3 bucket for
   CodeBuild and used Terraform to bootstrap the DynamoDB table for state lock. */
terraform {
  backend "s3" {
    // See https://www.terraform.io/docs/backends/config.html#partial-configuration
    encrypt        = true
    dynamodb_table = "fakecompanyTerraformLock"
    bucket         = "fakecompany-test-project"
    key            = "terraform.tfstate"
    region         = "us-east-2"
  }
}

// Add a Terraform state table; we add this *before* adding the terraform block above.
resource "aws_dynamodb_table" "terraform_backend_state_lock_table" {
  name           = "fakecompanyTerraformLock"
  provider       = aws.prod
  read_capacity  = var.terraform_lock_table_read_capacity
  write_capacity = var.terraform_lock_table_write_capacity
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(local.standard_tags, {
    description = "fakecompany Terraform state lock table for ${data.aws_iam_account_alias.current.account_alias}. Managed by Terraform."
  })

  lifecycle {
    prevent_destroy = true
  }
}

/* Define a CodePipeline resource to auto build/deploy changes made to the fakecompany test project master branch */
resource "aws_codepipeline" "codepipeline" {
  name     = "fakecompany"
  role_arn = var.codepipeline_arn

  artifact_store {
    location = "fakecompany-test-project"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        RepositoryName       = "fakecompany"
        BranchName           = "master"
        OutputArtifactFormat = "CODE_ZIP"
        PollForSourceChanges = false
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["BuildArtifact"]
      version          = "1"

      configuration = {
        ProjectName = "fakecompany"
      }
    }
  }

  tags = merge(local.standard_tags, {
    description = "fakecompany CodePipeline for ${data.aws_iam_account_alias.current.account_alias}. Managed by Terraform."
  })
}

/* Setup EventBridge notifications for CodePipeline */
resource "aws_iam_role" "fakecompany_codepipeline_role" {
  name = "fakecompany-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = "fakecompanyCodePipelinePolicy"
      Principal = {
        Service = "events.amazonaws.com"
      }
    }]
  })

  tags = merge(local.standard_tags, {
    description = "fakecompany CodePipeline Policy ${data.aws_iam_account_alias.current.account_alias}. Managed by Terraform."
  })
}

resource "aws_iam_role_policy" "fakecompany_codepipeline_policy" {
  name = "fakecompany-codepipeline-policy"
  role = aws_iam_role.fakecompany_codepipeline_role.name
  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Effect : "Allow",
      Action : [
        "codepipeline:StartPipelineExecution",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      Resource : [
        aws_codepipeline.codepipeline.arn,
        "arn:aws:s3:::fakecompany-test-project/",
        "arn:aws:s3:::fakecompany-test-project/*"
      ]
    }]
  })
}

/* Setup rules to notify CodePipeline of master branch changes */
resource "aws_cloudwatch_event_rule" "codepipeline_fakecompany_master_rule" {
  name        = "codepipeline-fakecompany-master-rule"
  description = "Trigger CodePipeline on Master commits."

  event_pattern = jsonencode({
    source : ["aws.codecommit"],
    "detail-type" : ["CodeCommit Repository State Change"],
    resources : [var.codecommit_arn],
    detail : {
      event : ["referenceCreated", "referenceUpdated"],
      referenceType : ["branch"],
      referenceName : ["master"]
    }
  })
}

resource "aws_cloudwatch_event_target" "codepipeline_fakecompany_master_rule" {
  depends_on = [
    aws_iam_role.fakecompany_codepipeline_role
  ]
  target_id = "CodePipelineRule"
  rule      = aws_cloudwatch_event_rule.codepipeline_fakecompany_master_rule.name
  arn       = aws_codepipeline.codepipeline.arn
  role_arn  = aws_iam_role.fakecompany_codepipeline_role.arn
}

module "functions" {
  source         = "./modules/functions"
  project        = var.project
  environment    = var.environment
  account_number = var.account_number
  providers = {
    aws = aws.prod
  }
}

module "network" {
  source         = "./modules/network"
  project        = var.project
  environment    = var.environment
  account_number = var.account_number

  queue_integration_uri  = module.functions.queue_integration_uri
  queue_integration_name = module.functions.queue_integration_name

  providers = {
    aws = aws.prod
  }
}
