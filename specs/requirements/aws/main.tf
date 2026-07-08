################################################################################
# endpoint-exposer service — assume-role IAM
#
# Only needed when AUTH_TYPE=aws-avp. In that mode, the service calls the
# Amazon Verified Permissions API directly (ensure_policy_store / create_policies /
# sync_policies / delete_policies) to manage the policy store backing route
# authorization. As with other AWS-integrated nullplatform services, this uses
# the ASSUME-ROLE pattern: this dedicated role holds the permissions and the
# nullplatform agent assumes it (sts:AssumeRole). The consuming stack passes
# this role's ARN to the agent (assume_role_arns) and publishes it to the
# nullplatform AWS IAM provider.
#
# When AUTH_TYPE=aws-cognito, route authorization is enforced entirely by
# Istio validating the Cognito JWT against its JWKS endpoint — no AWS API
# calls are made, so this module is not needed (set iam_create_role=false).
#
# The role trusts the agent role BY NAME (derived default) rather than by a
# module output, so the consuming stack can wire the ARN back into the agent
# without creating a dependency cycle. The agent role name is the conventional
# "nullplatform-{cluster_name}-agent-role".
################################################################################

resource "aws_iam_role" "nullplatform_endpoint_exposer" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for the endpoint-exposer service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

# --- Amazon Verified Permissions management -----------------------------------
# Covers the lifecycle calls made by scripts/avp/*: looking up or creating the
# policy store, and creating/updating/deleting/listing the policies that back
# route authorization. Resource stays "*" because AVP policy store ARNs are
# only known after creation; narrow it in the consuming stack once the store
# ARN is stable, if desired.
resource "aws_iam_policy" "nullplatform_endpoint_exposer_avp" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}_endpoint_exposer_avp_policy"
  description = "Policy for managing the Amazon Verified Permissions policy store used by the endpoint-exposer service"
  tags        = local.iam_default_tags

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "verifiedpermissions:GetPolicyStore",
          "verifiedpermissions:ListPolicyStores",
          "verifiedpermissions:CreatePolicyStore",
          "verifiedpermissions:UpdatePolicyStore",
          "verifiedpermissions:GetSchema",
          "verifiedpermissions:PutSchema",
          "verifiedpermissions:CreatePolicy",
          "verifiedpermissions:GetPolicy",
          "verifiedpermissions:UpdatePolicy",
          "verifiedpermissions:DeletePolicy",
          "verifiedpermissions:ListPolicies",
          "verifiedpermissions:TagResource",
          "verifiedpermissions:UntagResource",
          "verifiedpermissions:ListTagsForResource"
        ],
        "Resource" : "*"
      }
    ]
  })
}

# --- Attach the policy to the assume-role -------------------------------------
resource "aws_iam_role_policy_attachment" "endpoint_exposer_avp" {
  count = local.iam_create ? 1 : 0

  role       = aws_iam_role.nullplatform_endpoint_exposer[0].name
  policy_arn = aws_iam_policy.nullplatform_endpoint_exposer_avp[0].arn
}
