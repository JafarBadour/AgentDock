# Agentic Phone

Flutter app (Android-first, iOS beta) for a Cursor-style **Agents** window over SSH.

- **Connect** — SSH private key (and optional Cursor API key) in the device keystore
- **Hosts** — remotes like SSH config entries
- **Repos** — remote directories under a host
- **Agents** — many chats per repo; each chat talks to **Cursor Agent CLI** (`cursor-agent acp` / `agent acp`) on the remote via stock **tmux** + ACP

This is a greenfield project. Patterns were studied from open-source tools (e.g. MonkeySSH); **no third-party app code or remote helper binaries are vendored**.

## Security

- Secrets only in `flutter_secure_storage` (Android Keystore / iOS Keychain)
- Metadata SQLite DB never stores keys
- No analytics, Firebase, Crashlytics, or ads SDKs
- Network egress is SSH to hosts you configure (plus whatever the Cursor CLI does on the remote)
- Debug logs redact PEM / API-key-looking strings
- Prefer `agent login` on the remote; phone-stored Cursor API key is optional and only injected into that agent process env

## Remote prerequisites

On each host:

```bash
# tmux
sudo apt install tmux   # or brew install tmux

# Cursor Agent CLI on PATH as `cursor-agent` or `agent`
agent login
```

## Run (Android)

```bash
flutter pub get
flutter run
```

Use JDK 17+ for Android Gradle if your machine requires it.

iOS builds are supported by the project but are secondary (beta).

## Layout

```
lib/
  features/   # Connect, Hosts, Repos, Agents UI
  data/       # models, sqflite metadata, secure store
  services/   # SSH, tmux, Cursor ACP client
  app/        # router, providers
```
