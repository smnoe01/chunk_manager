# Chunk Manager

**Chunk Manager** is a server-side Minetest mod that intelligently manages the loading, unloading, and caching of map chunks based on real-time player movement and system load. Its purpose is to improve performance and reduce lag in multiplayer environments with minimal administrative effort.

---

## Features

- **Predictive chunk loading**  
  Anticipates player movement and preloads nearby areas to reduce loading delays.

- **Dynamic cache management**  
  Automatically cleans up unused chunks, limits cache size, tracks access frequency.

- **Active chunk unloading**  
  Frees memory and reduces server load by unloading distant, inactive areas.

- **Load-aware behavior**  
  Monitors system performance and enters emergency mode when thresholds are exceeded (queue size, cache misses, slow emerges).

- **Automatic suspension**  
  Temporarily pauses non-critical chunk loading during overload conditions or timeouts.

- **Administrative control**  
  Provides in-game commands to monitor status, force cache cleanup, toggle emergency mode.

---

## Commands

| Command | Description |
|--------|-------------|
| `/chunk_stats` | Shows real-time system metrics (cache size, queue, players, load state). |
| `/chunk_emergency on/off` | Manually enable or disable emergency mode. |
| `/chunk_emerge_pause` | Toggle emerge queue processing. |
| `/chunk_cleanup` | Force cache cleanup. |
| `/chunk_unload` | Force immediate unload of inactive chunks. |
| `/chunk_reset_suspension` | Reset automatic suspension after timeouts. |

---

## Configuration

All core settings are centralized in the `CONFIG` table inside `api.lua`. These control:

- Cache size and timeout
- Unload intervals
- Player view range by load
- Thresholds for overload detection
- Emergency behavior

You can modify these values to match your server's scale and performance profile.

---

## Requirements

- Minetest 5.6+

---

## License

Attribution-NoDerivatives 4.0 International

---

## Credits

Developed by [Atlante](https://github.com/smnoe01)

## Discord

[Discord Server](https://discord.gg/5FbgjvQA2P)
