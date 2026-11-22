config {
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended" # flags deprecated syntax, unused declarations, missing versions
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# CI fails if any taggable resource lacks one of the 5 mandatory tags
# (provider default_tags are taken into account).
rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Project", "Environment", "Owner", "ManagedBy", "Repository"]
}
