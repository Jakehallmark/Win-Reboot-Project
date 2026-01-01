# UUP Dump API Analysis & Implementation Notes

## Overview
This document outlines the correct way to interact with the UUP Dump API based on review of the official source code at https://git.uupdump.net/uup-dump/api

## Critical Finding: API Endpoint Misuse

### What Was Wrong
The previous implementation incorrectly assumed that `/get.php` would return edition and language information in `editionFancyNames` and `langList` fields.

**These fields NEVER exist in get.php responses.**

### What get.php Actually Returns
According to `get.php` lines 370-379, the response contains:
```json
{
  "apiVersion": "...",
  "updateName": "...",
  "arch": "amd64",
  "build": "22621.1",
  "sku": 48,
  "hasUpdates": true,
  "appxPresent": true,
  "files": { ... }
}
```

The edition/language data comes from the internal `uupApiGetPacks()` function which reads from `packs/{updateId}.json.gz`, but this is **never exposed** in the API response.

## Correct API Endpoints

### 1. Fetch Latest Build (Already Correct)
```
GET https://api.uupdump.net/fetchupd.php?arch=amd64&ring=retail&build=latest
```

Parameters:
- `arch`: amd64, x86, arm64, all
- `ring`: Canary, Dev, Beta, ReleasePreview, Retail (or WIF, WIS, RP)
- `flight`: Mainline, Active, Skip
- `build`: Build number or "latest"

Returns: `updateId`, `updateTitle`, `foundBuild`, and update array

### 2. Query Available Languages
```
GET https://api.uupdump.net/listlangs.php?id={updateId}
```

Parameters:
- `id`: Update ID (UUID format)

Returns: Array of language codes
```json
["en-us", "de-de", "fr-fr", ...]
```

### 3. Query Available Editions for a Language
```
GET https://api.uupdump.net/listeditions.php?lang={language}&id={updateId}
```

Parameters:
- `lang`: Language code (e.g., "en-us")
- `id`: Update ID (UUID format)

Returns: Array of edition codes
```json
["CORE", "PROFESSIONAL", "ENTERPRISE", ...]
```

### 4. Get Files for Specific Edition/Language Combination
```
GET https://api.uupdump.net/get.php?id={updateId}&lang={language}&edition={edition}
```

Parameters:
- `id`: Update ID
- `lang`: Language code
- `edition`: Edition code

Returns: File list for that specific combination

## Rate Limiting

The API enforces rate limiting on `get.php` in particular. Recommended practices:
- Wait **10+ seconds** between API calls
- Use this pattern:
  1. Query fetchupd (wait 10s)
  2. Query listlangs (wait 10s)
  3. Query listeditions (wait 10s)
  4. Query get (wait 10s)

## Handling Insider Builds

Insider Preview builds may not have edition/language data:
- If `listlangs.php` returns empty → Insider build, skip language selection
- If `listeditions.php` returns empty → Insider build, skip edition selection
- These builds are pre-configured single-edition, single-language

Recommended approach:
1. Try to fetch languages
2. If empty, mark as Insider build and skip menu selection
3. If languages exist, continue to fetch editions

## Special Build Types

Different Windows editions may return different response structures:
- Windows Server builds (SKU 189)
- WCOS/HoloLens builds (SKU 135)
- Consumer Windows (SKU 48)

The API handles these transparently in most cases.

## API Error Codes

Common errors you may encounter:

### From fetchupd.php
- `UNKNOWN_ARCH` - Invalid architecture
- `UNKNOWN_RING` - Invalid ring/channel
- `UNKNOWN_COMBINATION` - Invalid ring+flight combination
- `NO_UPDATE_FOUND` - No builds available for that configuration
- `WU_REQUEST_FAILED` - Windows Update servers unreachable

### From get.php
- `UNSUPPORTED_LANG` - Language not available for this build
- `UNSUPPORTED_EDITION` - Edition not available for this build
- `UNSUPPORTED_COMBINATION` - Edition+language combination invalid
- `EMPTY_FILELIST` - No files available
- `WU_REQUEST_FAILED` - Windows Update servers unreachable

## Implementation Notes

### Edition Name Mapping
The API returns short edition codes like `CORE`, `PROFESSIONAL`, etc.

For user-friendly names, use this mapping (from `shared/packs.php`):
```
CORE → Windows Home
PROFESSIONAL → Windows Pro
ENTERPRISE → Windows Enterprise
...
```

### Response Format
All API endpoints return JSON. Always handle:
1. Empty responses (network errors, rate limiting)
2. Error fields in response
3. Missing fields (Insider builds)

### Caching
The official API uses caching. You can safely cache:
- Build IDs (stable)
- Language lists (stable per build)
- Edition lists (stable per language+build)
- File lists (cache for 30+ minutes)

## References
- API Documentation: https://git.uupdump.net/uup-dump/api
- Main API File: https://git.uupdump.net/uup-dump/api/src/branch/master/shared/main.php
- Pack/Edition Handling: https://git.uupdump.net/uup-dump/api/src/branch/master/shared/packs.php
