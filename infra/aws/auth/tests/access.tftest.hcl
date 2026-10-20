# Mocked providers only (no AWS calls): use the same login-only overlay as the production cutover.
mock_provider "aws" {}
mock_provider "random" {}

variables {
  domain             = "muni.example"
  auth_domain        = "auth.muni.example"
  app_origin         = "https://muni.example"
  alert_email        = "ops@example.test"
  instance_role_name = "test-role"
  backend_ipv4       = "192.0.2.1"
  pilot_ipv4_cidrs   = ["198.51.100.1/32"]
  app_log_group      = "/test/app"
}

run "login_only" {
  command = plan

  assert {
    condition     = !var.pilot_mode && !var.signup_enabled
    error_message = "Run with -var-file=login-only.example: login must be open and self-registration closed."
  }
  assert {
    condition     = aws_cognito_user_pool.accounts.admin_create_user_config[0].allow_admin_create_user_only
    error_message = "Closing signup must be enforced by Cognito, including direct SignUp API calls."
  }
  assert {
    condition     = toset([for rule in aws_wafv2_web_acl.accounts.rule : rule.name]) == toset(["authentication-rate"])
    error_message = "Login-only access must remove the pilot IP block and retain rate protection."
  }
  assert {
    condition     = length(one(aws_wafv2_web_acl.accounts.default_action).allow) == 1
    error_message = "Ordinary authentication traffic must remain allowed."
  }
  assert {
    condition = alltrue([for rule in aws_wafv2_web_acl.accounts.rule :
      one(one(rule.statement).rate_based_statement).limit == 300 &&
      one(one(rule.statement).rate_based_statement).evaluation_window_sec == 300 &&
      one(one(rule.statement).rate_based_statement).aggregate_key_type == "IP" &&
      length(one(one(one(one(one(rule.statement).rate_based_statement).scope_down_statement).not_statement).statement).ip_set_reference_statement) == 1 &&
      length(one(rule.action).block) == 1
    ])
    error_message = "Keep the 300 requests/IP/five-minute blocking rule."
  }
}

run "restricted_pilot" {
  command = plan
  variables {
    pilot_mode     = true
    signup_enabled = true
  }
  assert {
    condition     = toset([for rule in aws_wafv2_web_acl.accounts.rule : rule.name]) == toset(["pilot-only", "authentication-rate"])
    error_message = "An explicit pilot must retain its IP restriction and rate protection."
  }
  assert {
    condition     = !aws_cognito_user_pool.accounts.admin_create_user_config[0].allow_admin_create_user_only
    error_message = "Pilot testers must still be able to exercise signup when enabled."
  }
}

run "public_signup" {
  command = plan
  variables {
    pilot_mode     = false
    signup_enabled = true
  }
  assert {
    condition     = !aws_cognito_user_pool.accounts.admin_create_user_config[0].allow_admin_create_user_only
    error_message = "Approved public signup must be independently enableable after SES approval."
  }
  assert {
    condition     = toset([for rule in aws_wafv2_web_acl.accounts.rule : rule.name]) == toset(["authentication-rate"])
    error_message = "Public signup must retain rate protection without the pilot IP block."
  }
}
