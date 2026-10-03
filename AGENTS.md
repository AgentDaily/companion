# Quenda Companion

- This repository owns Mac/iPhone presentation, pairing, connectivity and reconnect logic.
- Quenda is an independently running Gateway. Never embed its Python runtime or change its lifecycle automatically.
- Keep pairing credentials in Keychain; never log or commit them.
- Run `swift test` and `scripts/build-apps.sh` for relevant changes.
- Real iPhone/background/power claims require device evidence; compilation alone is not a device test.
