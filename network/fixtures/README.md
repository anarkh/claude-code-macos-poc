These certificates and the server private key are **local test fixtures only**.
They identify `fixture.invalid` and the documentation-only IPv6 address
`2001:db8::1`. They are not provider credentials or a production trust anchor.
The CA private key was discarded after issuing the server certificate.

Tests pass `test-ca.pem` through the transport's explicit `testOnly` argument;
production code uses the platform's normal trusted CAs and verifies the target
hostname. Never package this directory in the App or disable TLS verification.
