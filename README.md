# codex_auth

`codex_auth` is a pure-Dart, host-storage-owned client for the Codex
subscription device authorization flow. Its public client is
`CodexAuthClient`; its accepted maintainer is Matt Spurlin.

The package deliberately does not expose access tokens, refresh tokens,
production endpoint overrides, arbitrary authenticated URLs, or remote logout.
Hosts provide a transactional credential store and presentation callback. The
library holds that transaction through refresh and protected-request dispatch so
clients sharing one namespace cannot spend a rotating refresh token together.

```dart
final client = CodexAuthClient(CodexAuthOptions(store: store, transport: transport));
await client.loginDevice(onPrompt: (prompt) => showCode(prompt.userCode));
final catalog = await client.listModels(const CatalogQuery('0.154.0'));
final admission = await client.admitModel(catalog, 'gpt-5.6-sol', 'medium');
final response = await client.sendResponses(admission, CodexResponsesRequest(input: 'Hello'));
await response.bytes.drain();
await response.close();
```

Only an exact catalog admission can authorize a request. The client constructs
model and reasoning fields itself and refuses redirects for every
credential-bearing request. Local logout clears only the injected store; it
makes no remote-revocation claim.

This repository is an MVP evidence project, not a published production SDK.
The protocol comparison and physical AYN Thor evidence requirements are tracked
in `.agents/plans/ayn-thor-mvp-auth-evidence/` and must be completed before a
subscription compatibility claim is made.
