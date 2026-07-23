# bettingpair-fetch

Small Windows CLI for fetching the BettingPair click schedule with TLS 1.3 through rustls instead of Windows Schannel.

It reads these environment variables:

- `BETTINGPAIR_API_KEY`
- `BETTINGPAIR_CLOUDFLARE_ID`
- `BETTINGPAIR_CLOUDFLARE_SECRET`

Usage:

```powershell
.\bin\bettingpair-fetch.exe --from 2026-07-23 --to 2026-07-31
```

Build from the repository root:

```powershell
Push-Location .\tools\bettingpair-fetch
cargo build --release
Pop-Location
Copy-Item .\tools\bettingpair-fetch\target\release\bettingpair-fetch.exe .\bin\bettingpair-fetch.exe -Force
```
