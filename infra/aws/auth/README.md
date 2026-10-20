# Optional Muni accounts

This is an isolated Terraform root for Cognito, its certificate and sending
identity, WAF, encrypted runtime parameters, and account alerts. **Do not apply
`../terraform` to an existing production host to add accounts.** No Supah overlay,
user migration, identity pool, operator authorization, or inference is included.

## Application contract

`MUNI_AUTH_MODE=off` is the default: public pages and ordinary local development
need no provider credentials. `pilot` enables account routes without public
navigation; the Cognito WAF allowlist is the actual enrollment restriction.
`public` exposes navigation. Restart the application after configuration changes.
`MUNI_AUTH_PASSKEYS_ENABLED=0` keeps passkey management closed during the password
pilot; enable it only alongside the pool's `passkeys_enabled=true`.

- `/signup`, `/login`, and `/recover` start hosted Cognito flows. The callback
  uses code + S256 PKCE, browser-bound state, nonce, trusted JWKS, and live
  verified-user checks. Transactions expire after ten minutes and are consumed
  once. External return URLs are ignored.
- Identity is the pool issuer plus subject, never email or legacy identifiers.
  SQLite `accounts`, `account_sessions`, and `account_auth_transactions` are
  operational tables created additively through the existing writer lock.
- The browser holds an opaque `__Host-muni_session` cookie. SQLite holds its
  SHA-256 hash and authenticated AES-256-GCM ciphertext for retained tokens.
  Sessions expire after 24 hours idle or seven days total. Refresh leases are
  serialized in SQLite; provider calls never hold the database writer lock.
  A simultaneous request may receive a retryable 503 while refresh completes.
- `/account` shows verified email, city preference, and account controls. All
  account responses are private/no-store. Mutations require a CSRF token and
  the exact Origin, or `Origin: null` with browser Fetch Metadata reporting
  `Sec-Fetch-Site: same-origin`. The latter supports form submissions under
  `no-referrer`; missing metadata, sibling sites and foreign origins fail closed.
  Account requests require the configured HTTPS host. Configure
  trusted proxies to match actual socket peers, not all private networks.
- Passkey enrollment always starts with fresh, same-subject authentication and
  then Cognito's `/passkeys/add`. List/removal use the user's access token.
  Removal, deletion, and global logout require authentication within five minutes.
  If reauthentication is needed, the user returns to settings and repeats the
  action. Removing the last passkey is allowed; email/password remains available.
- `/recover` records recovery intent. After reset and successful authentication,
  it deletes all local sessions, calls global sign-out, and requires a new sign-in.
  A standalone Cognito reset page cannot directly delete Muni sessions; provider
  revocation is also checked on token refresh. Use Muni's recovery link.
- Logout deletes the local session before attempting refresh-token revocation,
  then clears the managed-login browser session. Global logout invalidates all
  local sessions first. Other browsers' Cognito cookies are not remotely erased;
  Muni requires fresh login and rejects authentication older than local revocation.
- Deletion disables local access first and removes email, preference, and sessions.
  A failed Cognito deletion remains `deletion_pending` for operator retry. After
  successful deletion, only a subject tombstone remains for at most seven days
  plus the interval until the next authentication transaction cleanup. Municipal
  records are untouched. Existing backups expire under their established policy.

## Provisioning

Use Terraform 1.10+ and the checked-in provider lock. Copy `variables.example`
and `backend.hcl.example` to a private directory outside the repository. The state
bucket must block public access, encrypt objects, enable versioning and restrict
access to operators. State and plan files contain secrets. Use separate state,
pool, client, and auth domain for any future staging environment.

```sh
terraform -chdir=infra/aws/auth init -backend-config=/private/path/backend.hcl
terraform -chdir=infra/aws/auth validate
terraform -chdir=infra/aws/auth plan -var-file=/private/path/production.tfvars -out=/private/path/accounts.tfplan
terraform -chdir=infra/aws/auth apply /private/path/accounts.tfplan
```

Review every plan. Refuse replacements/deletions of the pool, client, key or
authentication domain. Pool deletion protection and Terraform lifecycle guards
are intentional. The fixed region is `us-east-1` for Cognito, SES and custom-domain
ACM. Do not change the relying-party ID after passkeys have been enrolled.

For initial DNS validation only, a reviewed targeted plan may create
`aws_acm_certificate.auth` and `aws_sesv2_email_identity.sender`. Publish exactly
the returned certificate-validation CNAME and three DKIM CNAMEs through the DNS
provider, DNS-only, TTL 300. Retain certificate validation for renewals. Once ACM
is issued and SES DKIM succeeds, apply the full reviewed plan. Publish the auth
CNAME to `auth_dns_target`, also DNS-only, TTL 300. Preserve apex, MX, existing
SPF/DKIM and unrelated records. Default SES MAIL FROM avoids an apex SPF change.

The pool uses Essentials and managed login v2, case-insensitive email sign-in,
verified-email recovery, 15-character passwords without character classes,
MFA off and required passkey user verification. The confidential client allows
only code flow, exact callback/logout URLs, five-minute access/ID tokens and
seven-day rotating refresh tokens. Final factors are PASSWORD and WEB_AUTHN.
Default branding is created explicitly for the API-created client.

Request SES production access early. Verify a pilot recipient while sandboxed;
public signup waits for approval and delivery tests. Confirm the SNS subscription
in the alert inbox. Suppression covers bounces and complaints; CloudWatch records
aggregate delivery events and alerts on delivery delays, rejects and reputation.
Do not automatically remove suppressed recipients. WAF logs/samples are disabled
to avoid collecting account request contents; aggregate block metrics remain.

The account loader reads exactly the two SSM SecureString parameters. An
explicit deny prevents `AmazonSSMManagedInstanceCore` from granting access to
other parameters, except exact existing host dependencies explicitly listed in
`existing_parameter_arns`. Inventory the current role and host first; preserve
existing collection secrets without granting new access to them.
There is no application Cognito admin permission. Account operations use user
access tokens; confidential client credentials remain on the backend.

## Release and cutover

1. Record DNS, current immutable image, service/drop-ins, mounts, proxy, protected
   configuration, backup receipts and collection health. Check no overlay is
   mounted or loaded. Keep deployment evidence outside Git; no tokens or codes.
2. Run Ruby 3.3.12 `./setup`, `bin/test-all`, `bin/lint --cache false`,
   `python3 bin/test-http-security.py`, host-operation tests, dependency/secret
   audits and container checks. Push a PR; require current-head `test`,
   `dependencies`, `secrets`, `container` checks and an up-to-date branch. Squash
   merge without bypass, then verify merged-main checks.
3. Build an immutable `linux/amd64` image with the merged revision label. Upload
   to the existing private release bucket, record SHA-256, verify after download
   through SSM, and verify the loaded image's architecture/revision. Retain the
   previous image and mode-0600 configuration. Do not rebuild on the host.
4. Install `load-secrets.py` root-owned under `/opt/muni`. Add a service drop-in
   `ExecStartPre=/usr/bin/python3 /opt/muni/load-account-secrets.py /etc/muni/app.env /YOUR_AUTH_PREFIX us-east-1`.
   It preserves unrelated settings, atomically loads secrets without printing
   them, and performs no AWS call while mode is off. Keep `/etc/muni` mode 0700
   and its env/config files 0600. Never use shell tracing or dump container env.
5. Apply the Caddyfile log filters to **both global runtime and access logs** in
   the deployed custom proxy: remove `request>uri`, `request>headers`, and
   `resp_headers`; use `Referrer-Policy: no-referrer`. Preserve TLS, public assets,
   streaming and routing. Validate with the new image's Caddy before restart.
   Keep debug/credential logging disabled. Existing application logs must have
   30-day retention. Test with synthetic query/cookie markers and confirm neither
   successful responses nor proxy errors leak them.
6. Take and verify a fresh SQLite backup. Pause the health restart timer; stop
   the sole application/collector cleanly. Install image/config with auth off,
   then start once: `bin/start` applies additive schema before the supervisor.
   Verify public Cambridge/Boston pages, health, collection, backup operation and
   no authentication navigation. Re-enable the health timer.
7. With WAF restricted to tester networks and the production host, set pilot
   mode. Verify signup, email verification, password sign-in, recovery, two-session
   logout, provider-failure behavior and same-subject reauthentication. Use a real
   inbox and never record passwords/codes/tokens in evidence. The human tester
   enters passwords and approves platform passkey gestures directly.
8. Enable passkeys in the pool and application. In Safari and Chromium verify a
   platform passkey, same-account password/passkey sign-in, enrollment cancellation,
   unsupported-browser password fallback, removal including the last credential,
   password reset/lost-passkey replacement, and account deletion/retry handling.
9. Drill rollback with authentication off: restart the previous immutable image
   against the **current** additive database, verify public pages/collector, and
   return to the new image. Keep the new tables. Do not run orphan-table pruning
   from the old image. Recheck collection and a verified backup.
10. Only after all gates and SES approval, remove the pilot WAF restriction and
    set mode public. Keep the 300-requests/IP/five-minute rate rule with backend
    exclusion. Observe auth errors, WAF blocks and email delivery for at least
    one hour; review again the following day. Record results, not credentials.

## Recovery and rollback

First set auth off, restrict the pool with the pilot WAF rule, and restart the
application. If necessary, restore the previous image/configuration. **Keep the
pool, domain, passkeys and additive tables. Never restore an older database over
new municipal data or new accounts.** Fixes go through a new PR and immutable image.

For a pending deletion, an operator inspects only `accounts` rows whose status is
`deletion_pending`, through the protected host session. Match the stored issuer
to this pool. With operator credentials (never the app instance role), call
`aws cognito-idp admin-delete-user --user-pool-id POOL --username SUBJECT` in the
pool region. Treat `UserNotFoundException` as already deleted. Only after success,
call `Muni::Accounts.deletion_complete(ACCOUNT_ID)` via the application's Ruby
environment; it uses the writer lock and is safe to retry. If AWS fails, retain
the pending row and disabled access. Check pending rows during the daily review.

For encryption-key compromise, disable authentication and revoke all local
sessions/transactions through the writer lock, rotate the SSM key, restart and
require new sign-in. Do not silently change the key while retaining sessions.

The $25 monthly budget covers Cognito, SES and WAF; it is an alert, not a hard
spending cap. CloudWatch/SNS and the alert encryption key add small separate
charges. Credits and Cognito free-tier eligibility require account-level billing
verification and do not replace budget monitoring.

References: [managed endpoints](https://docs.aws.amazon.com/cognito/latest/developerguide/managed-login-endpoints.html),
[custom domains](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-add-custom-domain.html),
[WAF integration](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-waf.html),
[Caddy filtering](https://caddyserver.com/docs/caddyfile/directives/log).
