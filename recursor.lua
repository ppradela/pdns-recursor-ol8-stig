--------------------------------------------------------------------------------
-- /etc/pdns-recursor/recursor.lua
-- PowerDNS Recursor 4.8.9 — Lua configuration
--
-- Platform:    Oracle Linux 8
-- Maintainer:  <your-org-security-team>
--
-- The 'trust-anchor' INI key does not exist in 4.8.x. Using it produces:
--   Fatal error: Trying to set unknown setting 'trust-anchor'
-- All DNSSEC trust anchors must be set here with addTA() and loaded via:
--   lua-config-file=/etc/pdns-recursor/recursor.lua   (in recursor.conf)
--
-- Compliance
--   DISA STIG V-215606: explicit trust anchors required
--   NIST SP 800-81r2 §3.6.2: trust anchor management
--
-- Updating trust anchors
--   Source:  https://data.iana.org/root-anchors/root-anchors.xml
--   Verify:  openssl smime -verify -in root-anchors.p7s -inform DER \
--                          -content root-anchors.xml -noverify
--------------------------------------------------------------------------------


-- SECTION 1 — DNSSEC TRUST ANCHORS ----------------------------------------

-- Root KSK-2017  key tag 20326  algorithm 8 (RSA/SHA-256)
-- Status: VALID — active production root KSK as of 2026-03
addTA('.', '20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D')

-- Root KSK-2024  key tag 38696  algorithm 8 (RSA/SHA-256)
-- Status: VALID — active production root KSK, verified against IANA root-anchors.xml
-- Both anchors are carried simultaneously during the KSK-2017 → KSK-2024 rollover.
-- Monitor: https://www.iana.org/dnssec/files
addTA('.', '38696 8 2 683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16')

-- Internal zone trust anchors — add one addTA() per internally-signed zone.
-- addTA('internal.example.mil', '<keytag> <alg> <dtype> <digest>')


-- SECTION 2 — NEGATIVE TRUST ANCHORS (NTA) ----------------------------------
--
-- NTAs bypass DNSSEC validation for a zone. Use ONLY during incident response
-- when a zone's signatures are broken and cannot be immediately repaired.
-- Remove as soon as the zone operator restores valid DNSSEC signatures.
--
-- Runtime management (changes survive until next restart only):
--   rec_control add-nta broken.example.com "reason — ticket #XXXX"
--   rec_control get-ntas
--   rec_control clear-nta broken.example.com
--
-- Persistent NTAs (survive restart) — add here:
-- addNTA('broken.example.com', 'reason — ticket #XXXX — expires YYYY-MM-DD')


-- SECTION 3 — STARTUP CONFIRMATION ------------------------------------------

pdnslog('recursor.lua loaded — DNSSEC trust anchors active: KSK-2017 (tag 20326), KSK-2024 (tag 38696)',
        pdns.loglevels.Info)
