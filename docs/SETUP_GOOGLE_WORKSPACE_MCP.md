# ARGUS — Connect Google Drive, Gmail & Docs to CoCo

*Created by TCC · Snowflake CoCo Hack (GCC Edition)*

| | |
|---|---|
| **Google Cloud project** | `ultra-mediator-506312-t2` (name: *Aegis-Agentic-Google-Hackathon*) |
| **MCP server** | [`workspace-mcp`](https://github.com/taylorwilsdon/google_workspace_mcp) — open source (MIT), works with free Gmail accounts |
| **Services used** | Google Drive, Gmail, Google Docs |
| **Time needed** | about 15 minutes |

**What this gives ARGUS:** CoCo can read new circulars and past filings from a Drive
folder, and (in Week 4) deliver drafted findings to Gmail and Google Docs — always as a
draft that you confirm before anything is sent.

**Hackathon rule:** Google is only a *source and destination* reached through MCP.
Snowflake stays the system of record and does all the processing.

**Who does what**

| Step | Where | Who |
|---|---|---|
| 1. Enable the APIs | Cloud Shell | You |
| 2. Consent screen | Cloud Console | You |
| 3. Test user | Cloud Console | You |
| 4. OAuth client | Cloud Console | You |
| 5. Save the client values | PowerShell on your laptop | You |
| 6. Upload the PDFs | Google Drive | You |
| 7. Connect to CoCo | Laptop | Claude |
| 8. Approve Google sign-in | Browser | You |
| 9. Check it works | Laptop | Claude |

---

## Step 1 — Enable the APIs (Cloud Shell)

Open **https://shell.cloud.google.com** signed in with the Gmail account you'll use for
ARGUS. If it asks to authorize Cloud Shell, click **Authorize**. Run these one at a time.

Set the project ID:

```bash
PROJECT_ID="ultra-mediator-506312-t2"
```

Make it the active project:

```bash
gcloud config set project "$PROJECT_ID"
```

Enable the Drive, Gmail and Docs APIs (free; APIs already on are skipped):

```bash
gcloud services enable drive.googleapis.com gmail.googleapis.com docs.googleapis.com
```

Check all three are on — you should see **3 rows**:

```bash
gcloud services list --enabled --filter="config.name:(drive.googleapis.com gmail.googleapis.com docs.googleapis.com)"
```

Print the Console links you'll need for steps 2–4:

```bash
printf "Branding:   https://console.cloud.google.com/auth/branding?project=%s\nAudience:   https://console.cloud.google.com/auth/audience?project=%s\nClients:    https://console.cloud.google.com/auth/clients?project=%s\n" "$PROJECT_ID" "$PROJECT_ID" "$PROJECT_ID"
```

> Steps 2–4 have no command-line option: Google only offers OAuth-client creation for
> ordinary apps in the Console (`gcloud iam oauth-clients` is for Workforce Identity
> Federation only).

---

## Step 2 — Consent screen (Branding link)

This is the screen Google shows when you approve access.

- **If you see "Get started"** (not set up yet):
  1. App name: `ARGUS MCP`
  2. User support email: your Gmail
  3. Audience: **External**
  4. Developer contact email: your Gmail
  5. Tick the user data policy box → **Create**
- **If it's already set up** (from Aegis): leave it as is. Google's sign-in screen will
  show the existing app name — that's fine, it's only a label. You can rename it here if
  you prefer.

---

## Step 3 — Test user (Audience link)

1. Look at **Publishing status**.
2. **If it says "Testing":** under **Test users** click **+ Add users**, enter your Gmail
   address, **Save**. Only listed test users can sign in.
3. **If it says "In production":** nothing to add. At sign-in Google will warn that the
   app isn't verified — expected for a personal project (see Step 8).

---

## Step 4 — Create the OAuth client (Clients link)

Create a **new** client just for ARGUS, so Aegis's existing credentials stay untouched.

1. Click **+ Create client**.
2. Application type: **Web application**
3. Name: `argus-cortex-mcp`
4. Under **Authorized redirect URIs** click **+ Add URI** and enter exactly:

   ```
   http://localhost:8000/oauth2callback
   ```

5. Click **Create**.
6. A dialog shows the **Client ID** and **Client secret**. Keep it open for Step 5
   (you can also download the JSON). Don't paste either value into chat.

---

## Step 5 — Save the two values on your laptop (PowerShell)

Do this on the **Windows laptop where CoCo runs** — not in Cloud Shell. The MCP server
runs on your laptop and reads these values from your user environment, so the secret
never goes through chat or into a config file.

Open **Windows PowerShell** and run each line, pasting your own values in place of the
placeholders.

Save the Client ID:

```powershell
[Environment]::SetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_ID", "PASTE_CLIENT_ID_HERE", "User")
```

Save the Client secret:

```powershell
[Environment]::SetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_SECRET", "PASTE_CLIENT_SECRET_HERE", "User")
```

Check both are saved **without displaying them** — each should print `True`:

```powershell
[bool][Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_ID", "User")
```

```powershell
[bool][Environment]::GetEnvironmentVariable("GOOGLE_OAUTH_CLIENT_SECRET", "User")
```

Then **fully quit and reopen the Claude app** so new processes pick up the values.

---

## Step 6 — Upload the documents to Drive

1. Open **https://drive.google.com** with the same Gmail account.
2. **New → New folder** → name it exactly `ARGUS Policy Corpus`.
3. Open the folder and drag in all **7 PDFs**:
   - from `D:\hackathon\Snowflake hackathon\policy_corpus\pdf\` — 4 circulars
     (CBUAE, FATF R16, SAMA, CBB)
   - from `D:\hackathon\Snowflake hackathon\filings_corpus\pdf\` — 3 past STRs

---

## Step 7 — Connect to CoCo (Claude does this)

Reply **"go ahead with Part D"**. Claude will:

1. Install `uv` (a Python package runner) into the project's `.venv`.
2. Register the server with CoCo, limited to Drive, Gmail and Docs:
   `cortex mcp add google-workspace <.venv>/Scripts/uvx.exe workspace-mcp --tools drive gmail docs --tool-tier core`
3. Confirm it with `cortex mcp list`.

No secrets are written anywhere — the server reads the two values from Step 5.

---

## Step 8 — Approve Google sign-in (you, once)

The first time CoCo uses a Google tool, a browser tab opens:

1. Choose your Gmail account.
2. If you see **"Google hasn't verified this app"**: it's your own app — click
   **Advanced → Go to (app name) (unsafe)**.
3. Review the Drive, Gmail and Docs permissions and click **Continue / Allow**.
4. The tab says authentication succeeded — close it.

The token is stored locally by the server in `.credentials/` (excluded from git).

---

## Step 9 — Check it works (Claude does this)

CoCo lists the files in `ARGUS Policy Corpus` through the MCP server — you should see
the 7 PDFs. Then CoCo session **S7** downloads them into Snowflake
(`@ARGUS.GOVERNED.DOCS_STAGE`) and re-runs the document pipeline
(`sql/08_documents.sql`) — the same path a newly published circular would take.

---

## Troubleshooting

| What you see | Fix |
|---|---|
| `Error 400: redirect_uri_mismatch` | The redirect URI in Step 4 must be exactly `http://localhost:8000/oauth2callback` — no trailing slash, `http` not `https`. |
| `Error 403: access_denied` | App is in **Testing** and your Gmail isn't a test user — redo Step 3. |
| "Google hasn't verified this app" | Expected for personal projects — **Advanced → Go to (app name)**. |
| Server says client ID/secret missing | Values weren't picked up — re-check Step 5 prints `True`, then fully restart the Claude app. |
| Sign-in page won't load / port error | Something else is using port 8000 — tell Claude, it can move the server to another port (the redirect URI must change to match). |
| Folder not found | The folder name must be exactly `ARGUS Policy Corpus`, in the same Google account you signed in with. |

## Security

- Only the Gmail accounts you list can sign in while the app is in Testing.
- The secret stays in your Windows user environment; it's never in chat, the repo or
  CoCo's config.
- Revoke access any time: **https://myaccount.google.com/permissions** → your app →
  **Remove access**. To stop it entirely, delete the `argus-cortex-mcp` client (Step 4 page).
- Gmail sending (Week 4) is always draft-first with your explicit confirmation.
