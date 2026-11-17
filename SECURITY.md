# Security

## Reporting security issues

Do not report security vulnerabilities through public GitHub issues.

Report Microsoft product or service vulnerabilities to the
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report).

For vulnerabilities that apply only to this sample's source code, use a private
security advisory in the repository when that feature is available.

## Sample security scope

This sample renders HTML with Chromium. Even with sandboxing and resource
limits, rendering untrusted HTML remains high risk.

Before production use, evaluate:

- authentication and authorization;
- rate limiting and abuse prevention;
- tenant and process isolation;
- workload-specific HTML sanitization;
- network egress controls;
- dependency and container vulnerability scanning;
- Chromium and OS patch cadence;
- logging, alerting, and incident response.

Never commit Azure credentials, registry credentials, connection strings,
subscription or tenant IDs, customer data, or personal information.
