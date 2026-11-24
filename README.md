# CleanUpLight (`//cul`) — Lightweight Bag Organizer for FFXI (Windower 4)

A fast, zero-hang, **single-character** Windower 4 addon that cleans up and organizes your Final Fantasy XI bags from one plain-text file: **`data/bags.txt`**.

> **All the real action happens in your bag file (`data/bags.txt`).**
> `cleanuplight.lua` is just the fast O(1) mover engine — every bag destination, item group, kit, and character role lives in `data/bags.txt` (auto-created from [`data/bags.example.txt`](data/bags.example.txt) on first load). **Open `data/bags.example.txt` / `data/bags.txt` for much more detail, examples, and inline notes!**

---

## Why CleanUpLight?

- **Zero client hang (O(1) lookup)**: Indexes `res.items` (and expands any wildcards) **once at load**, then only walks the ~80 slots in your bags — no freezing like long Itemizer `puts`/`gets` scripts that scan 23,500+ items per line.
- **Plain-text bag-first config**: Just list items under `[SATCHEL]`, `[SACK]`, `[CASE]`, `[WARDROBE1–8]`, `[SAFE]`, `[STORAGE]`, or `[LOCKER]` — no Lua syntax, no quotes, no commas.
- **Strictly single-character**: Never sends commands or IPC to other clients. Orchestrate multi-box runs externally with standard Windower `send` / `sendaga` commands.
- **Safe by default**: Uses official Windower APIs only (`windower.ffxi.move_item` / `windower.ffxi.stack_items` — zero raw packet injection), skips equipped/bazaared items, enforces equippable-only safety for Wardrobes, paces moves gently only when items actually move, and stacks each touched bag once at the end.

---

## Installation & Quick Start

1. Download or clone into `Windower4/addons/cleanuplight/`.
2. Load in-game:
   ```text
   //lua load cleanuplight
   ```
3. On first load, CleanUpLight automatically copies `data/bags.example.txt` → `data/bags.txt` (your personal `data/bags.txt` is never overwritten on updates).
4. Edit `data/bags.txt` in any text editor (see the inline guide inside the file), then reload live:
   ```text
   //cul reload
   ```
5. Preview with `//cul dry go`, then run `//cul go`.
6. Optional: add `lua load cleanuplight;` to `scripts/init.txt` to auto-load on login.

---

## Commands

Aliases: `//cleanuplight`, `//cul`, `//cleanup`

| Command | What It Does |
|---|---|
| `//cul` / `//cul help` | Prints command help (does not move items) |
| `//cul go` | **Normal sweep** — stows all `[BAG]` sections + runs your character's `hoard:` / `dump:` kits |
| `//cul all` | **Full pack-up** — stows all `[BAG]` sections **and** every `[KIT:...]` back into its home bag |
| `//cul kit <name>` | **Toggle a kit** (e.g., `//cul kit abby`) — summons it to Inventory **or** puts it back away |
| `//cul <bag\|chunk>` | Sweeps one bag (`//cul satchel`, `//cul case`) or stows one chunk (`//cul utility`, `//cul meds`) |
| `//cul put <chunk> [bag]` | Explicitly stows a chunk/kit from Inventory into `[bag]` (defaults to its home bag) |
| `//cul get <chunk> [bag]` | Explicitly pulls a chunk/kit into Inventory from `[bag]` (defaults to storage bags; skips Wardrobes) |
| `//cul dry <subcommand>` | Dry-run preview — shows exactly what would move without touching anything (e.g., `//cul dry go`) |
| `//cul list` | Lists loaded bags, chunks, kits, and your active `hoard` / `dump` roles |
| `//cul verbose` | Toggles printing `"nothing to move"` chat messages |
| `//cul reload` | Reloads `data/bags.txt` live without unloading the addon |

---

## How the Bag File Works (`data/bags.txt`)

Everything is controlled inside **`data/bags.txt`** (see [`data/bags.example.txt`](data/bags.example.txt) for the full annotated starter layout):

### 1. Normal Bag Sections (`[SATCHEL]`, `[SACK]`, `[CASE]`, `[WARDROBE1–8]`, ...)
Everything placed under a `[BAG]` header is stowed from Inventory into that bag whenever you run `//cul go` (or `//cul all`). Use optional `@chunk` headers to organize items into named blocks you can also call individually:

```ini
[SATCHEL]
@utility
Warp Cudgel
Treat Staff II
Warp Ring
Dim. Ring (*)
Yoichi's Quiver

@meds
Remedy
Panacea
Echo Drops
Holy Water
Silent Oil
Prism Powder

[CASE]
@sortie
Octahedrite
Hexahedrite
Ra'Kaz. Sapphire
Ra'Kaz. Starstone
Mesosiderite
Voracious Psyche
```

- One item name per line — no quotes or commas required (`Yoichi's Quiver`, `Dial Key #Ab`, etc. work as-is).
- Lines starting with `#` or `//` are comments.
- Wildcards (`*` and `?`, e.g., `Dim. Ring (*)`, `P. * Card`) are expanded once at load for O(1) speed.
- Wardrobe headers (`[WARDROBE1]`–`[WARDROBE8]`) automatically skip non-equippable items.

### 2. Kits (`[KIT:name -> bag]`) — Experimental Summonable Sets
`KIT` sections are a loosely experimental feature for **summonable gear/item sets** you don't want stowed during everyday `//cul go` sweeps — for example, `[KIT:abby -> sack]` for Abyssea proc weapons:

```ini
[KIT:abby -> sack]
Irradiance Blade
Iapetus
Hoe
Lady Bell
Fermion Sword
Blurred Knife +1
Bloodrain Strap
```

- **`//cul kit abby` both summons and puts it away**:
  - **0 items in Inventory** → pulls the whole kit out into Inventory.
  - **Any item (even 1) in Inventory** → puts those items back into the kit's home bag (`sack`). *(Safe toggle: if 1 stray weapon was left out, it cleans it up instead of dumping 6 more weapons into your bag — run `//cul kit abby` again to pull the full set.)*
- Kits without `hoard:` / `dump:` are skipped by `//cul go`, toggled by `//cul kit <name>`, and stowed by `//cul all`.

### 3. Character-Specific `hoard:` and `dump:` (Multi-Box Anti-Hoarding)
Inside any `[KIT:name -> bag]`, you can optionally assign character-specific roles evaluated locally by each character during `//cul go`:

- **`hoard:`** *(also accepts `horde:`)* — **character-specific hoarding**. Characters listed here stow those items from Inventory into the kit's bag (`sack`, `case`, etc.).
- **`dump:`** — **character-specific anti-hoarding (NOT dropping, deleting, or selling!)**. `dump:` **never destroys or NPCs items** — it simply pulls those items *out* of storage bags into **main Inventory** so that character stops hoarding them and has them ready to trade/hand off to whoever is hoarding them.

```ini
[KIT:upgrade -> sack]
hoard: Character3
dump: Character1, Character2
Beitetsu Box
Beitetsu Parcel
Beitetsu
Pluton Case
Pluton Box
Pluton
Riftborn Boulder
Riftdross
Riftcinder
Heavy Metal

[KIT:limbus_mats -> sack]
hoard: Character2
dump: Character1, Character3   # or `dump: others` to apply to everyone not in `hoard:`
Tellurium Ingot
Black Jadeite
Vicuna Cloth
Ash Wood
```

Orchestrate across all characters externally with one standard Windower command:

```text
sendaga 0.2 @all cleanuplight go;
```

- **Phase 1 (Stow)** runs first on every character (`[BAG]` sections + their `hoard:` kits) to free Inventory space.
- **Phase 2 (Dump)** runs second on characters matching `dump:`, pulling those mats from storage bags into main Inventory.
- Characters not matched by `hoard:` or `dump:` skip the kit cleanly.

---

## More Details

See [`data/bags.example.txt`](data/bags.example.txt) for full settings (`move_delay`, `stack_delay`, `job_settle_delay`, `quiet_empty`), built-in starter categories (`utility`, `meds`, `ninjatools`, `sortie`, `sheolc`, `omen`, `dnamis`, `limbus`, `abby`, `upgrade`, `limbus_mats`, `ambuscade`), and inline formatting examples.

## License

MIT — see [LICENSE](LICENSE).
