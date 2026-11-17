# Path of Exile 2 — every route to character stats, build data and live data

Researched 2026-11-17, Europe/Oslo. Target: **stats** in the widest useful sense — your own character's numbers, the composition of a build (tree, gems, gear), live market data, and the raw game tables behind all of it. Both for code and for no-code use.

Everything marked **[verified]** was probed from this machine on 2026-11-17 against the live services; the transcript is `probe-output-2026-11-17-012725.txt` beside this file, produced by `probe-poe2-endpoints.sh` (also beside it, re-runnable). **[documented]** means it comes from GGG's or poe.ninja's own docs. **[unverified]** means it is community knowledge or a route I could not confirm.

---

## 0. The single most important finding

**No API anywhere returns computed character stats.** Not GGG's, not poe.ninja's, not the trade API. Every public route gives you the *composition* of a build — which passives are allocated, which gems are socketed, which items are worn, with their full modifier text — and stops there.

DPS, effective HP, life, resistances, armour, block chance, spirit, "Archmage mana cost" — the numbers on the in-game character sheet — come out of **a calculator that evaluates the composition against game data**. There are only three places they exist:

1. The in-game sheet (screen only, no export).
2. A third-party calculator that has both the composition and the game tables — in practice **Path of Building 2**, and secondarily poe.ninja's server-side calculation shown on its character pages.
3. Your own implementation, which means getting the composition (below) *and* the game data tables (section 5) and reimplementing PoB's maths. PoB's calculation engine is `src/Modules/Calc*.lua`, roughly 20k lines; nobody has reimplemented it successfully and stayed current.

So the practical question is never "which API gives me my DPS" — it is "which tool can compute it, and how do I get its output as text". Sections 6 and 7 answer that.

---

## 1. What "stats" resolves into (four different datasets)

| Dataset | What it is | Where the authoritative copy lives | Live? |
|---|---|---|---|
| **Build composition** | class, ascendancy, level, allocated passive hashes, quest-granted passives, weapon-set specialisations, socketed gems per item, equipped items with full mod text | GGG account API (`account:characters`) and PoB2's import of it | on demand, per character |
| **Item text** | the in-game tooltip text of an item: rarity lines, mods, implicits, requirements | GGG API `extended.text` on items / clipboard in game | on demand |
| **Computed stats** | DPS, EHP, life, ES, resists, armour, evasion, block, stun threshold, ailment maths | the game client's sheet, or a calculator (PoB2, poe.ninja) | only recomputed, never served |
| **Market + game data** | prices, listings, currency ratios; base items, mods, stats, passive tree tables, gem data | trade2 API, poe.ninja economy, poe2scout, RePoE exports | live to hourly |

Conflating these is where most tool attempts go wrong: people ask for "the PoE2 stats API" expecting the fourth column of the first row, and it does not exist.

---

## 2. Option A — GGG's official API (OAuth 2.1) **[documented, endpoints verified]**

Server endpoint: `https://api.pathofexile.com`.

GGG's own reference page opens with a warning worth quoting: *"There are currently limited APIs that return PoE2 game information."* That is accurate — the account-scoped endpoints work for `realm=poe2`, several others are PoE1-only.

### 2.1 What PoE2 supports

| Endpoint | Scope | PoE2? | Verified response unauth |
|---|---|---|---|
| `GET /profile` | `account:profile` | yes | n/a |
| `GET /league?realm=poe2` | `service:leagues` | **yes** | `401 Unauthorized` **[verified]** |
| `GET /league/{league}/ladder?realm=poe2` | `service:leagues:ladder` | **yes**, top **1000** entries (PoE1 top 15000) | `401` **[verified]** |
| `GET /character[?realm=poe2]` — list own characters | `account:characters` | **yes** | `401` **[verified]** |
| `GET /character/{name}?realm=poe2` — one character with equipment, skills, passives | `account:characters` | **yes** | `401` **[verified]** |
| `GET /currency-exchange/{realm}/{id}` | "Public API" per docs | docs imply yes | **`401` [verified]** — see §2.5 |
| item filters (`/item-filter`) | `account:item_filter` | yes, `realm: "poe2"` in the body | n/a |
| stashes, public stashes (psapi), guild stashes, league accounts, PvP | — | **PoE1 only** | — |

Ladder note from the docs, measured echo of the privacy problem: only the top 1000 PoE2 characters exist in the ladder at all, so "find my character on the ladder" is not a route for most accounts.

### 2.2 Authorization, the part that actually blocks people

OAuth **2.1**, two client types, and the choice decides everything:

| | Confidential client | Public client |
|---|---|---|
| Who | you run a server with a registered HTTPS redirect URI | desktop app on the user's machine |
| Grants | any | **Authorization Code + PKCE only** |
| Redirect | HTTPS domain you control; **no IP addresses, no localhost** | **local only** — `http://127.0.0.1:8080/callback` |
| Access token life | 28 days | **10 hours** |
| Refresh token life | 90 days | **7 days** |
| Rate limits | per client | **shared between all public clients** |
| `service:*` scopes | allowed (via `client_credentials`) | **not allowed** |

The trap: a personal script on this machine is a **public client**, which cannot use `service:leagues` or `service:leagues:ladder`. Those ladder/service scopes need a confidential client with `client_credentials`, which needs a hosted HTTPS app. Your own characters, however, only need `account:characters` — a public client with PKCE on `127.0.0.1` is enough, which is exactly what PoB2 does.

Grants: `authorization_code` (+PKCE, `S256`), `client_credentials` (service scopes, no expiry), `refresh_token` (inherits the old token's expiry, old token immediately dies). Authorization codes last **30 seconds**.

Registered applications live at `pathofexile.com/my-account/applications`; users can revoke any token there.

### 2.3 What one character response contains

`GET /character/{name}?realm=poe2` returns a `Character`:

```
id, name, realm, class, league, level, experience
current, expired, deleted        (flags)
equipment[]   -> Item objects, full mod text
skills[]      -> Item objects (PoE2 only field)
jewels[]      -> Item objects
passives { hashes[], specialisations{set1,set2,set3} (PoE2 only),
           skill_overrides{}, quest_stats[] (PoE2 only), jewel_data{} }
metadata { version }             -> game version for the realm
```

Field-level PoE2 details that matter for a tool:

- `passives.specialisations` is **the weapon-set split** (`set1`, `set2`, `set3`) — PoE2-only, and essential, because a PoE2 tree is per weapon set.
- `passives.quest_stats` is PoE2-only: passives granted by quests, not by points.
- `skills[]` is PoE2-only; PoE1 puts gems inside item sockets instead.
- `inventory`, `rucksack`, `guardian`, `wickerman` are PoE1-only.
- **No stat block.** Nothing resembling life/DPS/resists appears. `experience` and `level` are the only numeric character progression fields.

An `Item` gives you `name`, `typeLine`, `baseType`, `rarity`, `ilvl`, `corrupted`, `gemSockets` (PoE2), `socketedItems[]` (gems, each with `support: true|false`), and modifiers with their text; PoE2-specific flags include `mutated` (Vaal uniques) and `iconTierText`. That is everything a calculator needs and nothing a spreadsheet can display without computing.

### 2.4 Passive tree links are decodable data **[documented]**

The official passive-tree URL is a **base64url binary blob**, and GGG documents the byte layout. For PoE2 the format is **version 7** (introduced with 0.5.0, *Return of the Ancients*):

```
uint32 version (always 7)
uint8  class
uint8  ascendancy
uint16 count of data (n)
data[n]:
  uint16 node hash
  uint16 flags          // bit0 = weapon set present, bit1 = skill override present
  ?uint8 weapon_set     // if flags & 0b00000001
  ?uint16 skill_override_hash  // if flags & 0b00000010
```

PoE2 example from the docs:

```
https://pathofexile2.com/game/passive-skill-tree/AAAABwoAAAXO9AAArTcAAjpP1-wAAjpPNGMAAjpPvEYAAA==AAAABwoAAAXO9AAArTcAAjpP1-wAAjpPNGMAAjpPvEYAAA==
```

So a pasted tree link is a **complete, offline-readable list of allocated passives** — the cheapest route to "my build as text" that needs no OAuth at all. You still have to resolve node hashes to names via the game data tables (§5).

### 2.5 The currency exchange API is labelled public and answers 401 **[verified discrepancy]**

The reference page has a `## Currency Exchange` section headed **"Public API"**, documenting `GET /currency-exchange/{realm}/{id}` — hourly aggregate trade history per market pair, with `volume_traded`, `lowest_stock`, `highest_stock`, `lowest_ratio`, `highest_ratio`, and the note that responses are purely historical (no current hour).

Probed: `GET https://api.pathofexile.com/currency-exchange/poe2` → `401 Unauthorized`. Either the route differs from my reconstruction (the markdown-stripped doc shows `< realm>< id>`, so a path parameter may be mandatory) or it still requires a token with `service:cxapi`. **Not resolved.** Until it is, treat official currency-exchange data as unavailable without auth, and use poe.ninja or poe2scout.

---

## 3. Option B — the trade2 API: the most live thing that exists, and it needs no auth at all **[verified]**

This is the API the official trade site calls. It is not documented by GGG, but it is stable, public, unauthenticated for reads, and it is where real-time item supply lives. Everything below was measured from this machine.

Base: `https://www.pathofexile.com/api/trade2`.

### 3.1 Static catalogues (cache these, they change per patch)

| Endpoint | What | Verified |
|---|---|---|
| `GET /data/leagues` | leagues with `realm` | `200`, e.g. `Forbidden Rites`, `HC Forbidden Rites`, `Runes of Aldur`, `HC Runes of Aldur`, `Standard`, `Hardcore` |
| `GET /data/items` | base item types (not probed here, same family) | — |
| `GET /data/filters` | filterable fields, grouped; includes `status` options `available`, `securable`, `onlineleague`, `online` | `200` |
| `GET /data/stats` | every searchable stat id, e.g. `pseudo.pseudo_total_cold_resistance`, grouped `pseudo`/`explicit`/`implicit` | `200` |
| `GET /data/static` | currency and stackable groups with icons and ids, `realm: poe2` in the image payloads | `200` |

`/data/stats` + `/data/filters` are what you need to build trade queries programmatically: they are the vocabulary.

### 3.2 Search → fetch (the two-step)

```
POST /api/trade2/search/poe2/{league}          Content-Type: application/json
{
  "query": { "status": {"option": "online"}, "stats": [{"type":"and","filters":[]}] },
  "sort": { "price": "asc" }
}
```

Verified response shape:

```json
{"id":"H4sIAAAAAAAAA6tWKi5J...","complexity":4,"result":["<64-hex>", ...],"total":10000}
```

- league names contain spaces → **URL-encode** (`Forbidden%20Rites`); unencoded spaces produce `curl: (3) URL failed` locally and a 4xx from the server.
- `total` is **capped at 10000** — it is a ceiling, not a count of the market.
- `id` is an opaque continuation token; it must be passed to fetch as `?query=`.

```
GET /api/trade2/fetch/{id1,id2,...}?query={id}     (up to 10 ids per call, per docs/community)
```

Verified: `200`, and each result carries the whole listing — this is the real item river:

```json
{"id":"4526f55b...","listing":{
   "method":"psapi",
   "indexed":"2026-11-16T01:53:50Z",
   "stash":{"name":"Sales","x":0,"y":9},
   "price":{"type":"~price","amount":1,"currency":"aug"},
   "account":{"name":"Statueman12#2481","online":{"league":"Forbidden Rites"},
              "lastCharacterName":"sandythehook","language":"en_US","realm":"poe2"},
   "whisper":"@sandythehook Hi, I would like to buy your Black Sun Crest Wrapped Greathelm listed for 1 aug in Forbidden Rites (stash tab \"Sales\"; position: left 1, top 10)"
 },
 "item":{"realm":"poe2","verified":true,"w":2,"h":2,"icon":"https://web.poecdn.com/gen/image/...","league":"Forbidden Rites","id":"4526f55b...", ... }}
```

Note `method: "psapi"` on a PoE2 listing — the item feed is the public-stash pipeline; you simply are not given the raw stash stream for PoE2 the way PoE1's `service:psapi` gives it.

### 3.3 Currency exchange (bulk)

```
POST /api/trade2/exchange/poe2/{league}
{"query":{"status":{"option":"online"},"have":["divine"],"want":["exalted"]},"sort":{"have":"asc"},"engine":"new"}
```

Verified `200`; `result` is an **object keyed by listing id**, each value `{id, item, listing{indexed, account{...}, ...}}` — note `item: null` for pure currency swaps. This is live currency-ratio data at listing granularity, which is the closest thing to an official price feed without a token.

### 3.4 Live search (the "notify me when it's listed" feed)

The site subscribes over WebSocket to `/api/trade2/live/poe2/{league}/{query_id}`. Probed over plain HTTP it returns **`403`** rather than 404 — the route exists and rejects the wrong protocol. **[verified]**

The message shape is inherited from PoE1 (`wss://www.pathofexile.com/api/trade/live/{league}/{id}`, server pushes `{"new": [...]}` with new result ids, which you fetch as in §3.2). **[unverified for trade2 specifically]** — I did not complete a WebSocket handshake. Practical notes from the community clients: it needs the trade site's cookie/origin in PoE1, and the PoE2 live feed has had outages reported on the official bug forum.

### 3.5 Rate limits — measured, verbatim

Every response carries the policy and the budget for your IP. Format per rule is `max_hits:period_seconds:restrict_seconds`.

| Policy | `X-Rate-Limit-Ip` (measured) | Read as |
|---|---|---|
| `trade-search-request-limit` | `5:10:60, 15:60:300, 30:300:1800, 600:21600:3600` | 5 per 10s; 15/min; 30/5min (5-min block); 600/6h (1-hour block) |
| `trade-fetch-request-limit` | `12:4:10, 16:12:300, 50:300:300, 1000:21600:1800` | 12 per 4s; 16/12s (5-min block); 50/5min; 1000/6h (30-min block) |
| `trade-exchange-request-limit` | `5:15:60, 10:90:300, 30:300:1800` | 5/15s; 10/90s (5-min block); 30/5min |

`X-Rate-Limit-Ip-State` reports your current count per rule. Practical design: **fetch 10 per call, one search per query, cache for 30–60s**, and back off on the first `429` rather than parsing the state header.

### 3.6 Why this is the best "live" option

- No auth, no client registration, no token expiry.
- Sub-second responses (measured 0.4s for leagues).
- Listing-level detail including the exact whisper text — the same string a player would send.
- Currency exchange aggregates in one POST.
- Same API that the site and every price-check overlay uses, so it is exercised constantly and does not quietly die.

Its limit is equally clear: it knows **nothing about your character**. It is a market, not a mirror.

---

## 4. Option C/D — economy aggregators, and an important closed door

### 4.1 poe.ninja: **economy is open, builds are deliberately closed** **[documented]**

poe.ninja publishes an API reference (`poe.ninja/docs/api`) that is unusually explicit about the boundary:

- **Allowed**: economy overview endpoints for PoE1 and PoE2 — economy leagues, exchange overview, stash item overview (PoE2 uniques; PoE1 also currency).
- **Not allowed**: *"The builds / profiles API, and every other non-economy endpoint (character, Path of Building, authentication), are internal. They are undocumented, unsupported, and not available for third-party use, and they may change or break at any time."*
- The stated reasons: it is expensive to serve, and **many players hide their characters**, so serving that data to third parties would bypass a privacy choice. Clients that misbehave *"will be blocked"*.

This kills the obvious idea "scrape poe.ninja's build pages to get my stats". It is not just unsupported — it is refused in writing, and the site actively blocks misbehaving clients. The site's own UI is a different matter (§7).

PoE2 economy paths, verified live:

```
GET https://poe.ninja/poe2/api/economy/leagues
    -> [{"id":"Forbidden Rites","name":"Forbidden Rites"}, ...]
GET https://poe.ninja/poe2/api/economy/exchange/current/overview?league={id}&type=Currency
    -> {"core":{"items":[{"id":"divine","name":"Divine Orb",...},{"id":"exalted",...}],
               "primary":..., "rates":{...}},
        "lines":[{"id":..., "primaryValue":..., "volumePrimaryValue":...,
                  "maxVolumeCurrency":..., "sparkline":...}]}
GET https://poe.ninja/poe2/api/economy/stash/current/item/overview?league={id}&type=UniqueWeapons
```

PoE2 `type` values for exchange: `Currency`, `Fragments`, `Abyss`, `UncutGems`, `LineageSupportGems`, `Essences`, `SoulCores`, `Idols`, `Runes`, `Ritual`, `Expedition`, `Delirium`, `Breach`, `Verisium`.
PoE2 `type` values for stash items: `UniqueWeapons`, `UniqueArmours`, `UniqueAccessories`, `UniqueFlasks`, `UniqueCharms`, `UniqueJewels`, `UniqueSanctumRelics`, `UniqueTablets`, `PrecursorTablets`.

Freshness and etiquette (from their docs): HTTP-cached ~5 min with ETags, **underlying data refreshes about hourly for PoE2** (~15 min for PoE1), send a descriptive User-Agent, do not bypass the cache, and proxy through a backend rather than hitting them from every end-user machine.

### 4.2 poe2scout: price **history**, which poe.ninja does not give you **[verified]**

Base: `https://api.poe2scout.com` — **no `/api/v1` prefix**; realm and league are path segments. Confirmed by reading the service's own route registrations (`net/Poe2scout.Api/Handlers/*/GetHandler.cs`) and then hitting them.

| Endpoint | Returns | Verified |
|---|---|---|
| `GET /Realms` | realms incl. `poe1/pc`, `poe1/xbox`, `poe1/sony`, `poe2/...`, each with `TradeApiPath` and `DefaultLeagueValue` | `200` |
| `GET /{realm}/Leagues` | league list with `DivinePrice`, `ChaosDivinePrice`, `BaseCurrencyApiId`, icon | `200` |
| `GET /{realm}/Leagues/{league}/Items` | the priced item catalogue for a league | `200` |
| `GET /{realm}/Leagues/{league}/Items/{itemId:int}/History` | price history series for one item | not probed |
| `GET /{realm}/Leagues/{league}/Currencies/{apiId}` | one currency, converted | not probed |
| `GET /{realm}/Leagues/{league}/Currencies/{apiId}/History` (pair history family) | currency pair history | not probed |
| `GET /{realm}/Leagues/{league}/ExchangeSnapshot`, `/SnapshotHistory`, `/SnapshotPairs`, `/ReferenceCurrencies` | currency-exchange snapshots and the base currencies usable for display | not probed |
| `GET /{realm}/Leagues/{league}/Uniques/{category}` | unique prices by category | not probed |

Sample, live: `GET /poe2/Leagues` returned `Forbidden Rites`, `ShortName: forbiddenrites`, `IsCurrent: true`, `DivinePrice: 491.9452924798352`, `ChaosDivinePrice: 10.417469704921846`, `BaseCurrencyApiId: "exalted"`, `BaseCurrencyText: "Exalted Orb"`.

Practical: poe.ninja is the cleaner current-price feed; poe2scout is the one with **time series** and an easy league/currency model. Both are community-run, undocumented as a contract, and can change.

`docs.poe.watch` was also surfaced as a price API; not probed, treat as a third option of the same class.

---

## 5. Option E — the game's data files (everything that is not about *your* character)

For anything that needs base items, mods, stat translation, passive nodes, gem data or monster stats, the answer is a data export, not an API.

| Source | What you get | Notes |
|---|---|---|
| **RePoE fork — PoE2 export** `repoe-fork.github.io/poe2` | JSON export of the game tables in the same shape as PoE1: `base_items`, `mods`, `stats`, `stat_translations`, `gems`, `gem_tags`, `item_classes`, `tags`, `default_monster_stats`, `characters`, `flavour`, plus schemas in `data-formats` | community-maintained, regenerated per patch, includes machine-readable schemas — generate your own structs with quicktype |
| **PoB data export** `repoe-fork.github.io/pob-data/poe2` | the data inside PoB2's source, including `Uniques` which is **hand-maintained** because it is not in the game files | the only route to correct unique-item data |
| **poe2db** | browsable item/gem/mod/passive database with tiers and weights | HTML/UI oriented; good for humans, scrape-hostile for tools |
| **ggpk-exposed** (`image.ggpk.exposed/{game}/{path}`) | any asset referenced by the data, e.g. `.dds` icons as PNG with `?format=png` | use for icons without shipping the game files |
| **Extractors**: `POEFixer/GGPKExplorer`, `juddisjudd/ggpk-explorer` (Rust), `aianlinb/VisualGGPK2`, `HeartofPhos/exile-export` | browse/extract `Content.ggpk` and the PoE2 bundle index; export tables to SQLite/JSON | needed only if you want a table the exports do not cover, or a different patch |
| **jchantrell/exiledb** | CLI that dumps PoE data into SQLite and other formats | PoE1-centric; check PoE2 support before relying on it |

For "passive node hash → node name", the exports plus `stat_translations` are the join. Passive tree **layout** (x/y coordinates, connections) is also in the exports; the official tree viewer at `pathofexile2.com/game/passive-skill-tree/<blob>` renders from the same tables.

---

## 6. Option F — no code at all: getting stats out of the game and out of calculators

### 6.1 In game

There is **no export**. No clipboard command, no chat command, no file drop. The character sheet is read only by eye. What *is* exportable from the client is:

- **Item tooltip text** — Ctrl+C on a hovered item copies its full text (this is what every price-check overlay relies on).
- **Passive tree link** — the game's tree screen can produce the `pathofexile2.com/game/passive-skill-tree/…` string; that blob is the §2.4 binary format.

So the no-code text route for a *character* is: copy each item, screenshot the sheet, and paste the tree link. Tedious but complete.

### 6.2 Path of Building 2 — the only real calculator **[documented + community]**

Repo: `PathOfBuildingCommunity/PathOfBuilding-PoE2`. This is the single tool that turns composition into numbers.

- **Import**: Import/Export → Character Import. It runs an OAuth 2.1 **PKCE** flow from a local HTTP server (`src/LaunchServer.lua`), stores the tokens in `Settings.xml`, and calls the official API with `account:characters`. Tokens are 10h/7d (public-client lifetimes) with a `refresh_token` grant. You authorise your own account only — the API gives nobody else's characters.
- **What it shows**: the Calcs tab — DPS by skill, hit damage, life/ES, armour, evasion, block, resistances, ailment and DoT maths, spirit, mana. This is the closest thing to "the stats" that exists as text you can select and copy.
- **Share code**: Import/Export → *Generate* → *Share* → *Copy* produces a code. Format: **URL-safe base64 of a zlib-compressed XML document** (`Build:SaveDB()`), with `-`/`_` instead of `+`/`/`. That XML holds the tree node list, items in in-game text form, gems, config flags and notes — **not** the computed numbers, which are evaluated at load time.
- **Developer escape hatch**: in development mode PoB2 can import **raw JSON character data** (`src/Classes/ImportTab.lua`), which lets you test with an API dump instead of authorising.
- **Party-play export**: an option that includes auras/curses affecting allies, so support builds compute their contribution.

Everything PoB2 computes comes from its own Lua data tables, so it is only as correct as its last patch update — but it is the community's reference implementation and every guide site disagrees with it at its peril.

### 6.3 `.build` files — the official machine-readable build format **[documented]**

GGG documents this at `pathofexile.com/developer/docs/game` (Build Planner, PoE2 only). Facts that matter:

- A `.build` file is **JSON**, one `Build` object, read from `C:\Users\<you>\Documents\My Games\Path of Exile 2\BuildPlanner`. The game runs a file watcher on that folder.
- **The game is a viewer only**: *"Editing or creating builds within Path Of Exile 2 is currently not supported."* You cannot export your character to `.build` from inside the game.
- You can also **subscribe** to builds via `pathofexile2.com/my-account/builds`, or upload your own `.build`.
- Meta gems are **not supported** in the format.

Schema (version 1, experimental):

```
Build {
  name            string
  author          ?string
  link            ?string
  description     ?string
  ascendancy      ?string
  passives        ?array of (string | BuildPassive)
  skills          ?array of (string | BuildSkill)
  inventory_slots ?array of BuildInventorySlot
}
BuildPassive { id (passive id e.g. "strength89"), level_interval ?(uint | uint[]),
               weapon_set ?uint 0..2, additional_text ?string }
BuildSkill   { id (BaseItemTypes id e.g. "Metadata/Items/Gems/SkillGemEarthquake"),
               level_interval ?, additional_text ?,
               support_skills ?array of (string | BuildSupport) }
BuildSupport { id, level_interval ?, additional_text ? }
BuildInventorySlot { inventory_id (e.g. "Weapon1", "Boots1", "Ring1"), additional_text ? }
```

`additional_text` uses a light markup — `{Heading}` sections and `\n` — which is why a `.build` can carry per-node explanations and stat priorities ("1. Increased Health / 2. Increased Resistances …").

Because it is plain JSON, **a `.build` file is the easiest fully-legal way to get a build out as text**, and it round-trips through `poe2-tools/poe2-build-planner` (a local-first editor that preserves unknown fields) or a browser converter that decodes a PoB share code (URL-safe base64 + zlib XML) into `.build`, mapping PoB node ids to GGG passive ids.

### 6.4 Site UIs that already do the work for you

| Site | What it gives | Caveats |
|---|---|---|
| **poe.ninja** PoE2 build pages | per-character computed totals (DPS, life, ES, resists) rendered server-side; a **Build Planner export** button that generates a `.build` from a character (early prototype, items not included), next to a Path of Building export | the *API* is closed (§4.1); the *UI* is fine for a human. Characters must be public |
| **poe2.dev / poe2planner** | build planner with import/export; exports **JSON** or a compressed share URL encoding the whole build | saved builds live in browser localStorage — export or lose them |
| **Mobalytics / Maxroll** | curated guides, leveling trees, per-skill setups; Mobalytics also has an item/mod database | editorial, not data: conclusions, not tables |
| **fextralife wiki (poe2)** | Build Planner page documenting the `.build` format in prose; item/skill pages | fan wiki, can lag a patch |
| **poe2db** | raw tables with tiers/weights: mods, bases, gems, passives | the site to consult when a number must be exact |
| **Exiled Exchange 2** (`Kvan7/Exiled-Exchange-2`) | desktop overlay: copies the hovered item's text, parses it, builds a trade2 query, shows prices; folders in lots of other features (currency, map mods) | price checking, not character stats; it is the PoE2 successor to Awakened PoE Trade |
| **poe2 price-check tools generally** | several forks/wrappers rebuilt on EE2's matching engine | same caveat |
| **PoE2TradeHelper** and similar | MCP/REST wrappers around trade2 live search, fetch, exchange | useful if you want an assistant to query the market |

### 6.5 The honest no-code answer to "export my stats to text"

1. Set characters to **public** on `pathofexile.com` (privacy settings; hidden characters are hidden from every tool, and PoE2 profiles default to private-ish behaviour).
2. Open your character on **poe.ninja** and copy the numbers you need; or
3. Open **PoB2**, import the character (one-time OAuth), read the **Calcs** tab, and copy the rows.
4. For a build file: use poe.ninja's Build Planner export, or PoB2 → share code → converter → `.build`, which lands as JSON in `Documents\My Games\Path of Exile 2\BuildPlanner`.
5. For the tree alone: copy the `pathofexile2.com/game/passive-skill-tree/…` link and decode it (§2.4).

---

## 7. Decision matrix

### By "what do you actually need"

| Need | Best route | Second | Code required? |
|---|---|---|---|
| My character's computed DPS/EHP/resists as text | **PoB2** Calcs tab (or poe.ninja character page) | screenshot + OCR of the in-game sheet | no |
| My build as structured text | **`.build` JSON** (poe.ninja export, or PoB code → converter) | GGG account API JSON | no (JSON), yes (API) |
| My passives as ids, offline | **passive tree URL**, format v7 | GGG API `passives.hashes` | yes (decode) |
| My gear with full mod text | **GGG API** `/character` (OAuth) | Ctrl+C item text in game | yes |
| Whether an item is worth anything *right now* | **trade2** search + fetch | poe.ninja stash overview | yes |
| Currency ratios, live | **trade2** `/exchange` POST | poe.ninja exchange overview | yes |
| Price over time | **poe2scout** `/Items/{id}/History` | poe.ninja sparklines | yes |
| Notify me when an item lists | **trade2** live WebSocket | poll search/fetch | yes |
| Base items, mods, stat ids, gem data | **RePoE poe2 export** + `trade2/data/{stats,filters}` | game extraction | either |
| Unique item corrections | **PoB data export** (`Uniques`) | poe2db | either |
| Ladder standings (top 1000 only) | GGG `/league/{l}/ladder` (confidential client) | screenshot the site | yes |

### By live-ness

| Source | Latency to reality |
|---|---|
| trade2 fetch / exchange | seconds |
| trade2 live WebSocket | push, seconds |
| poe.ninja PoE2 economy | ~1 hour behind, HTTP-cached 5 min |
| poe2scout | same class as poe.ninja, plus history |
| GGG account API character | current as of last save |
| RePoE / PoB data exports | per patch |
| `.build` files | static once written |

### By friction

| Source | Auth | Registration | Fragility |
|---|---|---|---|
| trade2 | **none** | none | undocumented but heavily exercised |
| poe.ninja economy | none | none (User-Agent requested) | "supported but not stable"; can block misuse |
| poe2scout | none | none | small community service |
| GGG characters | **OAuth PKCE** | **client registration required** | official but "limited" for PoE2 |
| GGG ladder/service | confidential client | HTTPS redirect URI required | unavailable to a local script |
| PoB2 | OAuth PKCE (built in) | none (PoB's client id) | app updates per patch |
| `.build` | none | none | format is v1/experimental |
| Data exports | none | none | regenerate per patch |

---

## 8. Recipes

### 8.1 List PoE2 leagues and current prices — no auth, no key

```bash
UA="my-tool/1.0 (contact: you@example.com)"
curl -sS -A "$UA" https://www.pathofexile.com/api/trade2/data/leagues
curl -sS -A "$UA" "https://poe.ninja/poe2/api/economy/exchange/current/overview?league=Forbidden%20Rites&type=Currency"
curl -sS -A "$UA" https://api.poe2scout.com/poe2/Leagues
```

### 8.2 Decode a passive tree link into node hashes

```python
import base64, struct
def tree_nodes(url_or_blob: str):
    blob = url_or_blob.rsplit("/", 1)[-1]
    raw = base64.urlsafe_b64decode(blob + "=" * (-len(blob) % 4))
    ver, cls, asc, n = struct.unpack_from("<IBBH", raw, 0)
    assert ver == 7, f"unexpected PoE2 tree version {ver}"
    off, out = 9, []
    for _ in range(n):
        h, flags = struct.unpack_from("<HH", raw, off); off += 4
        rec = {"hash": h, "flags": flags}
        if flags & 1:
            rec["weapon_set"] = raw[off]; off += 1
        if flags & 2:
            rec["skill_override"], = struct.unpack_from("<H", raw, off); off += 2
        out.append(rec)
    return {"class": cls, "ascendancy": asc, "nodes": out}
```

(Byte layout straight from GGG's docs; resolve `hash` → node name with the RePoE export.)

### 8.3 Decode a PoB2 share code into readable XML

```python
import base64, zlib
def pob_code_to_xml(code: str) -> str:
    b = code.strip().replace("-", "+").replace("_", "/")
    return zlib.decompress(base64.b64decode(b + "=" * (-len(b) % 4))).decode("utf-8")
```

Gives `<PathOfBuilding>…<Build …><Tree><Spec nodes="…"/></Tree><Skills …/><Items …/></Build>`. Readable, greppable, diffable.

### 8.4 A minimal `.build` file

```json
{
  "name": "my build",
  "author": "me",
  "ascendancy": "Deadeye",
  "passives": [
    {"id": "strength89", "additional_text": "{Take first}\nCheap and early"},
    "dexterity_1"
  ],
  "skills": [
    {"id": "Metadata/Items/Gems/SkillGemEarthquake",
     "support_skills": ["Metadata/Items/Gems/SupportGemFastForward"]}
  ],
  "inventory_slots": [{"inventory_id": "Boots1", "additional_text": "{Any Boots}\n1. Movement Speed"}]
}
```

Save as `Documents\My Games\Path of Exile 2\BuildPlanner\<name>.build`; the game picks it up by file watch.

### 8.5 OAuth for your own characters (public client, PKCE)

```
1. register a client at pathofexile.com/my-account/applications  -> client_id
   + a local redirect, e.g. http://127.0.0.1:8080/callback
2. code_verifier = base64url(random 32 bytes)
   code_challenge = base64url(sha256(code_verifier))
3. open:
   https://www.pathofexile.com/oauth/authorize?client_id=…&response_type=code
     &scope=account:characters&state=…&redirect_uri=http://127.0.0.1:8080/callback
     &code_challenge=…&code_challenge_method=S256
4. catch ?code=… on your local listener (codes live 30 seconds)
5. POST https://www.pathofexile.com/oauth/token
     client_id, grant_type=authorization_code, code, redirect_uri,
     scope=account:characters, code_verifier
6. GET https://api.pathofexile.com/character?realm=poe2
     Authorization: Bearer <access_token>
```

`401` = expired/revoked; `403` = wrong scope. Public clients get 10h access / 7d refresh and **cannot** use `service:*` scopes.

---

## 9. Failure modes and gotchas, all observed

1. **League names have spaces.** `Forbidden Rites` → `Forbidden%20Rites` everywhere (trade2, poe.ninja, poe2scout). Unencoded spaces make curl refuse the URL and the server 4xx.
2. **`total` is capped at 10000.** Do not read it as market size.
3. **A search `id` is not optional.** Fetch without `?query=` fails; the id also encodes the sort and league context.
4. **Search is IP-rate-limited hard**: 5 per 10 s. A price-check loop that searches per item will hit the 5-minute rule quickly. Fetch is the cheap call (12 per 4 s).
5. **`401` vs `403` on the official API mean different things** — expired token vs missing scope. Both are fixed by re-authorising, not by retrying.
6. **A local script cannot get ladder data.** `service:leagues:ladder` requires a confidential client with an HTTPS redirect, which a personal machine is not. Only the top **1000** PoE2 entries exist anyway.
7. **The currency-exchange API is documented as public and answered 401.** Unresolved (§2.5). Use poe.ninja/poe2scout for currency until it is.
8. **poe.ninja's build/character API is closed by policy**, and they block clients that hammer it. Scrape the site UI for yourself if you like; do not build a service on it. The sanctions are explicit.
9. **PoE2 character privacy.** If characters are hidden, no tool sees them — not PoB2, not poe.ninja. "API returns nothing" is usually this.
10. **There is no computed-stat endpoint anywhere.** Any tool claiming otherwise is running a calculator.
11. **`.build` is v1/experimental** and cannot express meta gems; the game only reads, never writes.
12. **Public stash API for PoE2 does not exist** as an endpoint (`service:psapi` is PoE1), yet PoE2 trade listings show `method: "psapi"` — the feed exists server-side, it is just not exposed to you.
13. **PoB2 share codes are not stats.** Decode them and you get composition; the numbers are recomputed on load.

---

## 10. Verification gaps I did not close

- The **live-search WebSocket** for trade2: confirmed the route exists (`403` on plain HTTP), never completed a handshake, so the push payload shape is assumed from PoE1.
- **`/currency-exchange/poe2`**: docs say public, probe says 401; possibly needs the hour `id` parameter or a `service:cxapi` token.
- **poe2scout history pagination and the uniques/currencies detail routes**: catalogue and leagues verified, the per-item history endpoints were only read from the service's own route definitions, not called.
- **`trade2/data/items`**: same family as the verified `/data/*` endpoints, not probed.
- **Whether poe.ninja's Build Planner export button is still a prototype** — their post called it early and item-less; the button's presence is documented, its current field coverage is not.
- Whether GGG has added a PoE2 **stash** scope since the last changelog entry; the reference currently marks stashes and psapi PoE1-only.

---

## 11. Sources

Primary, read 2026-11-17:

- `pathofexile.com/developer/docs` — index, OAuth 2.1, client types, scopes, grants, token lifetimes
- `pathofexile.com/developer/docs/reference` — endpoint list, `Character`/`Item`/`League`/`LadderEntry` types, PoE2 realm parameters, top-1000 ladder note, passive tree binary format v1–v7, currency exchange section
- `pathofexile.com/developer/docs/game` — Build Planner, `.build` JSON schema, BuildPlanner directory per platform, PoE2-only statement
- `poe.ninja/docs/api` — what is supported (economy), what is refused (builds/characters) and why, PoE2 endpoint paths and `type` enums, hourly PoE2 refresh, ETag/UA etiquette
- `PathOfBuildingCommunity/PathOfBuilding-PoE2` — README, `src/Classes/PoEAPI.lua`, `LaunchServer.lua`, `ImportTab.lua`, `Modules/Build.lua` (share code + XML), `Modules/BuildSiteTools.lua`
- `repoe-fork.github.io` + `/poe2` + `/pob-data/poe2` — data export contents, schemas, hand-maintained uniques
- `poe2scout/poe2scout` — README (API base), `net/Poe2scout.Api/Handlers/*/GetHandler.cs` (literal routes)
- Community: `Kvan7/Exiled-Exchange-2`, `poe2-tools/poe2-build-planner`, `zenojunior/poe2-trade-api`, `Underslumber/PoE2TradeHelper`, `POEFixer/GGPKExplorer`, `juddisjudd/ggpk-explorer`, `aianlinb/VisualGGPK2`, `HeartofPhos/exile-export`, `jchantrell/exiledb`; r/pathofexiledev threads on trade2 endpoints; official PoE2 bug-forum threads on trade2 live search and on the account API after privacy changes.

Measured by me, this machine, 2026-11-17: `probe-output-2026-11-17-012725.txt` (17 endpoints; statuses `200` for trade2 `/data/*`, trade2 fetch, all three poe.ninja PoE2 endpoints, all three poe2scout endpoints; `401` for the four official API routes; `403` for the plain-HTTP live-search route).

---
---

# Part 2 — the actual job: one character, into text

Everything above answers "what data exists". This part answers the question that was actually asked: **take a character — mine, a friend's, or a stranger's — and get its stats and build out as text, as live as the game allows, without retyping it.** Written after the first version of this file missed that target. Nothing above is deleted; where Part 2 contradicts Part 1, Part 2 is the correction and the old text stays for the record.

## 12. The task, stated once

1. Input: a character. Any character. Whose does not matter.
2. Output: its **build** (class, ascendancy, level, passive tree, gems, gear with mod lines) and its **numbers** (DPS, life, ES, armour, evasion, block, resists, spirit), as text.
3. Constraint: as current as the character is, with no retyping and no screenshotting.
4. Allowed: clicking through an app, and/or writing code.

## 13. The one fact that decides every route: public ≠ accessible

These are two separate switches, and conflating them is what makes people believe a public character should be readable by their tooling.

| Switch | What it controls | Effect |
|---|---|---|
| **Visibility** (character privacy on pathofexile.com) | whether *public aggregators* may publish the character | poe.ninja can index and show it; you can read that page with no login |
| **Access** (OAuth `account:characters`) | which characters an API token may read | **only the token owner's own account** |

PoE1 had a public character surface: `pathofexile.com/account/view-profile/<account>/characters` and PoB could import by account name. **PoE2 has no equivalent** — the developer docs restrict `GET /character` to the bearer's realm and account, and PoB2's import is an OAuth flow for the signed-in user. Consequence, stated plainly:

> Making a character public does **not** let anyone pull it through the API. It only lets a site that already publishes public characters show it.

That single fact determines which of the three cases below you are in.

## 14. Case 1 — your own character, **no code at all**

The shortest route in the whole file, because PoB2 carries both the authorisation and the calculator.

1. **Unhide the character.** pathofexile.com → account → Privacy settings → uncheck "Hide characters"; unhide the individual character if it is hidden separately. (Not strictly required for PoB2's own OAuth import, but required for poe.ninja and every aggregator.)
2. **PoB2 → Import/Export → Character Import → Start.** A browser opens the official authorise page; you log in and approve `account:characters`. You are riding PoB2's own registered client, so there is no client_id, no secret, no redirect URI to arrange. Tokens: **10 hours** access, **7 days** refresh, renewed automatically.
3. **Pick the character → Import.** Tree ("Passive Tree and Jewels"), "Items and Skills", and quest points all fill in. Per-character; re-import after you change gear.
4. **The numbers are now on the Calcs tab** — DPS per skill, hit damage, life, ES, armour, evasion, block, resistances, spirit, mana, ailment and DoT maths.
5. **The build is already text on disk.** PoB stores every build as an **XML file in its `Builds` folder** (PoB's own maintainers state this: builds are XML files under the install location's `Builds` directory). Save the build once and you have a readable XML file — no export step, no share code needed.
6. **If you also want JSON:** poe.ninja character page → **Build Planner** export → a `.build` file (JSON). Early prototype: tree and skills, items not yet included.

What you never touch in this route: OAuth endpoints, client registration, PKCE, the trade API, or a text editor.

## 15. Case 2 — your own character, **with code** (unattended)

Same data, no clicking, once a client exists.

1. **Register a public client** at `pathofexile.com/my-account/applications`: any name, client type **public**, redirect URI **local** (`http://127.0.0.1:8080/callback`), scope **`account:characters`**. Public clients may *only* use Authorization Code + PKCE and get no client secret. Copy the `client_id`.
2. **PKCE**: `code_verifier` = base64url(32 random bytes); `code_challenge` = base64url(sha256(verifier)).
3. Open `https://www.pathofexile.com/oauth/authorize?client_id=…&response_type=code&scope=account:characters&state=…&redirect_uri=http://127.0.0.1:8080/callback&code_challenge=…&code_challenge_method=S256`, approve, catch `?code=` on the local listener. **Codes expire in 30 seconds.**
4. `POST https://www.pathofexile.com/oauth/token` with `client_id`, `grant_type=authorization_code`, `code`, `redirect_uri`, `scope`, `code_verifier`.
5. `GET https://api.pathofexile.com/character?realm=poe2` → list; `GET /character/{name}?realm=poe2` → full composition per character.
6. Dump to text; feed the numbers step (§18).

Token lifetimes and failure modes: access **10h**, refresh **7d** for public clients (confidential clients get 28d/90d but cannot use a localhost redirect). `401` = expired/revoked, `403` = wrong scope — both fixed by re-authorising, not retrying. A **local** script can never obtain `service:*` scopes (leagues, ladder, psapi, cxapi): those need a confidential client with an HTTPS redirect on a domain you control, i.e. a hosted app.

## 16. Case 3 — someone else's character (a friend, or a stranger)

No login, no API, no scraping required — the build travels as a file.

| Route | Quality | What it contains | Who acts |
|---|---|---|---|
| **Friend sends their PoB build** (Generate → Share → Copy, or the saved `.xml`) | **best** — real numbers when you load it | full composition, and Calcs recomputes the true stats locally | friend authorises once in PoB2, you paste and compute |
| **Friend sends the `.build` JSON** (poe.ninja Build Planner export) | composition only | tree + skills, no items, no numbers | friend clicks export |
| **poe.ninja already indexes them** | numbers + build on screen, no login | whatever ninja publishes for that character | nobody — just open the page |
| **You log in as them** | works, and is not something to do | everything | — |
| **Ask GGG's API** | impossible | nothing | — |

The mechanism that makes route 1 work: **a PoB share code is portable build data, not account data.** It is URL-safe base64 of zlib-compressed XML — tree node ids, items in in-game text form, gems, config flags. Load it in any PoB2 install and the engine computes as if the character were there. That is why "someone else's character" is a solved problem *without any access at all*: the owner exports once, and the file does the rest.

Route 3 depends on coverage, not on permission: ninja publishes characters it has indexed (ladder and tracked accounts), so a random friend may simply not be there even when fully public.

## 17. The compute step — corrected: PoB **can** be driven headlessly

Part 1 says the numbers need a calculator and implies that means a GUI. That is too pessimistic. PoB ships **`HeadlessWrapper.lua`**, and driving the calculation engine from a command line is a working, published pattern:

- **`ianderse/pob-mcp`** uses an **unmodified** PoB source tree plus a compatible **LuaJIT**, ships a stdio adapter that loads `HeadlessWrapper.lua` as a library, and drives the engine. Configured with `POB_LUA_ENABLED=true`, `POB_CMD=<luajit>`, `POB_PATH=<PoB>/src`, `POB_DIRECTORY=<Builds>`.
- Its tool list is the capability list: **`lua_import_code`** decodes a PoB import/export code (from pobb.in or the desktop app's Generate button) and loads it into the engine; **`lua_import_pobb`** fetches from pobb.in / poedb.tw; **`lua_get_stats`** returns calculated stats by category (`offense` / `defense` / `all`); **`export_full_stats`** returns *every* numeric stat PoB calculated — several hundred keys; `lua_save_build` writes a `.xml`; `export_full_stats` is the text output you were told does not exist.
- There is also a community PR adding the same idea inside PoB itself (`src/PoBMCP.lua`), and a `r/pathofexiledev` thread on running PoB headless with `luajit` and `LUA_PATH` appended to the runtime Lua paths.
- Caveats from that project that matter before you build on it: newer PoB sources use compound assignment (`count += 1`) which **older LuaJIT cannot parse** (needs LuaJIT ≥ mid-2026 or a patched interpreter); a checkout may need native Lua modules (`lua-utf8` via luarocks); on Windows PoB's bundled `lua51.dll` is **not** a command-line interpreter, you need a CLI `luajit`.

**Verification status:** confirmed as a working pattern **for PoE1's `PathOfBuildingCommunity/PathOfBuilding`**. Whether `PathOfBuilding-PoE2`'s `HeadlessWrapper.lua` is equally drivable is **[unverified]** — same architecture, different data tables and tree code, and I have not run it. Treat the headless path as "probably, test it" rather than "known good" for PoE2.

## 18. The full pipeline, with and without code

**Without code (works today, any character whose build you can obtain):**

```
character  --(PoB2 import: your account)------------> .xml in Builds/  (build as text)
           --(friend sends code / .xml)------------->
           --(poe.ninja: any indexed character)-----> .build JSON     (build as text)
                                     |
                                     +--(load in PoB2)---> Calcs tab   (numbers, screen)
```

**With code (the automation ceiling, now higher than Part 1 said):**

```
own account:   PKCE OAuth  -> /character?realm=poe2  -> character JSON
any character: poe.ninja page / friend's code        -> PoB share code (base64url+zlib XML)
                       |
                       +-- decode (5 lines)  ------------------------------> composition as text
                       +-- lua_import_code -> headless PoB --export_full_stats--> numbers as text
```

So the corrected ceiling: **composition and numbers are both automatable** — composition from the API or from a share code, numbers from a headless PoB engine. The genuinely irreducible step is getting *the composition of a character you do not own*: it must come from the owner (a code, a file) or from a published page (poe.ninja). No amount of code changes that; it is a policy boundary, not a technical one.

**Live-ness, per artefact:** character JSON = as of the character's last save; PoB XML = as of export; share code = as of export; headless recomputation = immediate but over whatever data was loaded; `.build` from ninja = as of ninja's last index of that character; sim usage on the Calcs tab = recomputed locally, so "live" only means the inputs are current.

## 19. Gaps specific to this job (kept explicit rather than papered over)

1. **`PathOfBuilding-PoE2` headless** — pattern proven on PoE1, not on PoE2. Test before depending on it.
2. **PoB2's exact menu labels and Builds path** — the XML-in-`Builds`/ statement is PoB's own, and PoB2 inherits the design, but I have not read PoB2's save path out of its source on this machine (PoB is not installed here).
3. **poe.ninja PoE2 build pages** — the page family exists and the Build Planner export is documented by them; whether *their* pages render computed DPS/life for PoE2 characters the way the PoE1 pages do is **[unverified]** — the site is client-rendered and my one browser attempt was cut short.
4. **Whether a friend's `.build` can carry items** — the export is an early prototype and items were explicitly out of it when announced.
5. **The OAuth `account:characters` rate limit** — not documented and not measured; the trade2 numbers in §3.5 are unrelated. Handle `429` plus `X-Rate-Limit-*` generically.
6. **PoE2 "public profile" page** — PoE1 has one; for PoE2 I found no URL that renders a character's items to an anonymous browser. If one exists, it would be a third no-login route and this file should be updated.

## 20. Additions to sources (Part 2)

- `ianderse/pob-mcp` README — `HeadlessWrapper.lua`, LuaJIT requirement, `POB_*` env vars, `lua_import_code`, `lua_get_stats`, `export_full_stats`, snapshot/reload behaviour
- `PathOfBuildingCommunity/PathOfBuilding` issue #1825 — "Your builds are stored as XML files in your PoB install location in the folder named `Builds`"
- `TomaDev1/PathOfBuilding` PR #1 (`src/PoBMCP.lua`) — headless engine exposed without the GUI
- `r/pathofexiledev` — running PoB headless via `luajit` with runtime Lua paths appended
- `r/PathOfExile2` — PoB2 character import requires OAuth; no website access to PoE2 characters
- GGG developer docs (already cited in Part 1) — public vs confidential clients, local-redirect rule, 10h/7d lifetimes, `service:*` restriction
- poe.ninja (already cited) — Build Planner export availability, and the builds/character API refusal that makes the owner-or-ninja rule unavoidable
