# Contributing

Thank you for your interest in improving this sample.

## Before you submit a change

1. Create a branch or fork. Do not push directly to the default branch.
1. Keep changes focused on the sample scenario.
1. Do not commit credentials, connection strings, subscription or tenant IDs,
   customer data, internal resource names, or personal information.
1. Do not include internal platform component names or implementation details
   in external documentation.
1. Run:

   ```shell
   go test -count=1 ./...
   go vet ./...
   ```

1. Build and run the real Chromium integration target as documented in
   [README.md](README.md).
1. Build the final Linux AMD64 image.
1. Update the README when behavior, dependencies, limits, or deployment steps
   change.

## Pull requests

Describe:

- what changed and why;
- which tests and container builds passed;
- whether the worker-image contract or Azure deployment shape changed;
- any preview limitations or security tradeoffs.

Microsoft repositories can require a Contributor License Agreement. If a CLA
bot comments on your pull request, follow its instructions.

This project follows the [Microsoft Open Source Code of
Conduct](CODE_OF_CONDUCT.md).
