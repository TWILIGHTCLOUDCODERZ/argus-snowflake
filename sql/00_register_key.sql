/* ============================================================================
   ARGUS · 00_register_key.sql — one-time setup, run by YOU in Snowsight.
   Paste this whole file into a new SQL worksheet and click "Run All".
   Nothing here needs editing: it detects your own username automatically.
   The key below is the PUBLIC half — safe to share. The private key never
   leaves your laptop (~/.snowflake/keys/argus_rsa_key.p8).
   ============================================================================ */

-- STEP A: register the ARGUS public key on your own user
SET my_user = CURRENT_USER();
ALTER USER IDENTIFIER($my_user) SET RSA_PUBLIC_KEY='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArti7gS+B4NnXOvMkPZ4U3PkxW5ANIf4+jeKUj3hTizY/n+Xut/mmilCtVH7RJ1tL0lgh7zssYdaakm3IWGIoRHNop1dngR89Bpm/qF5u8Uw2fOQMqC5g3UbSUfptcH4dWIqGiovwEnsQofXslg7OxpdeJzn5r2DoYmsJslYRwwAkoxmJWjOholZ0NfsBNsFbaVIoSqbsZV70akkXYUE2tb/02Ljceh3AT+YJsmwxEHXdXVXt/e+c7UDI9iB7fvBKqXKqLH3Qz9sOGGX+Lxbi6WOL1WLBZ8HrD3Vl1uGlLD9Ym/xntfVTyno/bgIIa/q0kj/5cHzDk+CvIilq3DDDRwIDAQAB';

-- STEP B: the details Claude needs (none are secrets). This is the result
-- you'll see after "Run All" — copy this one row back to Claude.
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier,
       CURRENT_USER()      AS username,
       CURRENT_ROLE()      AS role,
       CURRENT_WAREHOUSE() AS warehouse;

/* STEP C (optional check): run this on its own afterwards.
   Find the row RSA_PUBLIC_KEY_FP — it must read:
   SHA256:A2sRNaxOjbnNjVKV74WKDE2zH04xu7e8i3F6DwRszpE=

   DESC USER IDENTIFIER($my_user);
*/
