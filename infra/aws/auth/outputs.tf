output "dns_validation_records" {
  value = [for record in aws_acm_certificate.auth.domain_validation_options : {
    type = record.resource_record_type, name = record.resource_record_name, content = record.resource_record_value
  }]
}
output "ses_dkim_records" {
  value = [for token in aws_sesv2_email_identity.sender.dkim_signing_attributes[0].tokens : {
    type = "CNAME", name = "${token}._domainkey.${var.domain}", content = "${token}.dkim.amazonses.com"
  }]
}
output "auth_dns_target" { value = aws_cognito_user_pool_domain.auth.cloudfront_distribution }
output "pool_id" { value = aws_cognito_user_pool.accounts.id }
output "client_id" { value = aws_cognito_user_pool_client.web.id }
output "secret_parameter_names" {
  value = [aws_ssm_parameter.client_secret.name, aws_ssm_parameter.session_key.name]
}
