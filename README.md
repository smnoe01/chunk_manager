# Chunk Manager (2.0.2)

Chunk Manager is a server-side Luanti mod that intelligently manages the loading, unloading, and caching of map chunks based on real-time player movement and system load. Its purpose is to improve performance and reduce "lag" in multiplayer chunk-loading environments.

![screenshot](https://github.com/user-attachments/assets/9c9675d3-aa1d-43c7-8017-0aab23ed01ad)


---

## Features

- **Predictive Chunk Loading**  
  Anticipates player movement and preloads nearby areas to reduce loading delays.

- **Dynamic Cache Management**  
  Automatically cleans up unused chunks, limits cache size, tracks access frequency.

- **Active Chunk Unloading**  
  Frees memory and reduces server load by unloading distant, inactive areas.

- **Load-Aware Behavior**  
  Monitors system performance and enters emergency mode when thresholds are exceeded (queue size, cache misses, slow emerges).

- **Automatic Suspension**  
  Temporarily pauses non-critical chunk loading during overload conditions or timeouts.

- **Administrative Control**  
  Provides in-game commands to monitor status, force cache cleanup, toggle emergency mode.

---

## Commands

| Command                    | Description                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| `/chunk_manager_status`    | Show preloader status.                                             |
| `/chunk_manager_emergency` | Toggle emergency mode.                                             |
| `/chunk_manager_cleanup`   | Force cache cleanup.                                               |
| `/chunk_manager_suspend`   | Suspend chunk manager temporarily.                                 |

---

## Configuration

All core settings live in the `CONFIG` table inside `api.lua`. You can tweak:
You can also configure it by going to minetest settings.

- Cache size limits and timeouts  
- Unload intervals and emerge parameters  
- Player view range thresholds  
- Overload detection criteria  
- Emergency‑mode behavior

Adjust these values to fit your server’s scale and performance profile.

---

## Requirements

- **Luanti 5.0+**

---

## License

Attribution‑NoDerivatives 4.0 International

---

## Credits

Developed by [Atlante](https://github.com/smnoe01)

---

## Discord

[Discord Server](https://discord.gg/5FbgjvQA2P)
