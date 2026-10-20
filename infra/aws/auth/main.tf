resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.domain
  lifecycle { prevent_destroy = true }
}
resource "aws_sesv2_configuration_set" "accounts" {
  configuration_set_name = var.project_name
  reputation_options { reputation_metrics_enabled = true }
  suppression_options { suppressed_reasons = ["BOUNCE", "COMPLAINT"] }
}
resource "aws_acm_certificate" "auth" {
  domain_name       = var.auth_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
  }
}
resource "aws_acm_certificate_validation" "auth" {
  certificate_arn         = aws_acm_certificate.auth.arn
  validation_record_fqdns = [for record in aws_acm_certificate.auth.domain_validation_options : record.resource_record_name]
}
resource "aws_cognito_user_pool" "accounts" {
  name                     = var.project_name
  user_pool_tier           = "ESSENTIALS"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"
  mfa_configuration        = "OFF"
  username_configuration { case_sensitive = false }
  user_attribute_update_settings { attributes_require_verification_before_update = ["email"] }
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
  password_policy {
    minimum_length                   = 15
    require_lowercase                = false
    require_uppercase                = false
    require_numbers                  = false
    require_symbols                  = false
    temporary_password_validity_days = 1
  }
  sign_in_policy {
    allowed_first_auth_factors = var.passkeys_enabled ? ["PASSWORD", "WEB_AUTHN"] : ["PASSWORD"]
  }
  web_authn_configuration {
    relying_party_id  = var.auth_domain
    user_verification = "required"
  }
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }
  email_configuration {
    email_sending_account = "DEVELOPER"
    source_arn            = aws_sesv2_email_identity.sender.arn
    from_email_address    = "Muni <accounts@${var.domain}>"
    configuration_set     = aws_sesv2_configuration_set.accounts.configuration_set_name
  }
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Verify your Muni account"
    email_message        = "Your Muni verification code is {####}. Enter it on the Muni sign-up page. If you did not request this, you can ignore this email."
  }
  lifecycle { prevent_destroy = true }
}
resource "aws_cognito_user_pool_client" "web" {
  name                                 = "muni-web"
  user_pool_id                         = aws_cognito_user_pool.accounts.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "aws.cognito.signin.user.admin"]
  supported_identity_providers         = ["COGNITO"]
  explicit_auth_flows                  = ["ALLOW_USER_AUTH"]
  callback_urls                        = ["${var.app_origin}/auth/cognito/callback", "${var.app_origin}/auth/passkeys/complete"]
  logout_urls                          = ["${var.app_origin}/auth/signed-out"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 5
  id_token_validity                    = 5
  refresh_token_validity               = 7
  read_attributes                      = ["email", "email_verified"]
  write_attributes                     = ["email"]
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 5
  }
  lifecycle { prevent_destroy = true }
}
resource "aws_cognito_user_pool_domain" "auth" {
  domain                = var.auth_domain
  user_pool_id          = aws_cognito_user_pool.accounts.id
  certificate_arn       = aws_acm_certificate_validation.auth.certificate_arn
  managed_login_version = 2
  lifecycle { prevent_destroy = true }
}
resource "aws_cognito_managed_login_branding" "web" {
  depends_on                  = [aws_cognito_user_pool_domain.auth]
  user_pool_id                = aws_cognito_user_pool.accounts.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true
}
resource "random_bytes" "session_key" { length = 32 }
resource "aws_ssm_parameter" "client_secret" {
  name  = "/${var.project_name}/client-secret"
  type  = "SecureString"
  value = aws_cognito_user_pool_client.web.client_secret
}
resource "aws_ssm_parameter" "session_key" {
  name  = "/${var.project_name}/session-key"
  type  = "SecureString"
  value = random_bytes.session_key.base64
  lifecycle { prevent_destroy = true }
}
resource "aws_iam_role_policy" "runtime_secrets" {
  name = "${var.project_name}-secrets"
  role = var.instance_role_name
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect   = "Allow", Action = ["ssm:GetParameters"],
    Resource = [aws_ssm_parameter.client_secret.arn, aws_ssm_parameter.session_key.arn]
    }, {
    # AmazonSSMManagedInstanceCore otherwise permits reading every parameter.
    Effect      = "Deny", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory", "ssm:GetParametersByPath"],
    NotResource = concat([aws_ssm_parameter.client_secret.arn, aws_ssm_parameter.session_key.arn], tolist(var.existing_parameter_arns))
  }] })
}
