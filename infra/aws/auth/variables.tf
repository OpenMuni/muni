variable "project_name" {
  type    = string
  default = "muni-auth"
}
variable "domain" { type = string }
variable "auth_domain" { type = string }
variable "app_origin" {
  type = string
  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.app_origin))
    error_message = "Use an HTTPS origin with no path or trailing slash."
  }
}
variable "alert_email" { type = string }
variable "instance_role_name" { type = string }
variable "existing_parameter_arns" {
  description = "Explicit existing host dependencies to preserve when narrowing SSM reads. No wildcards."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.existing_parameter_arns : startswith(arn, "arn:aws:ssm:") && !strcontains(arn, "*")])
    error_message = "Use exact existing SSM parameter ARNs."
  }
}
variable "backend_ipv4" { type = string }
variable "pilot_ipv4_cidrs" { type = set(string) }
variable "pilot_mode" {
  description = "Restrict all authentication to tester networks, including existing-account login."
  type        = bool
  default     = true
}
variable "signup_enabled" {
  description = "Allow self-registration independently of network access. Disable for login-only access while SES is sandboxed."
  type        = bool
  default     = true
}
variable "passkeys_enabled" {
  type    = bool
  default = false
}
variable "app_log_group" { type = string }
