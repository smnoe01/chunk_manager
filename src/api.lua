
local modname = core.get_current_modname()
local S = core.get_translator(modname)

local CHUNK_SIZE = 16
local MIN_HEAP_SIZE = 0
local MAX_EMERGENCE_HISTORY = 100
local DEFAULT_VIEW_DISTANCE = 5
local UNLOAD_DISTANCE_SQ = 40000 -- (200 blocks)^2


local function validate_config_value(value, min_val, max_val, default)
    local num = tonumber(value)
    if not num then
        return default
    end
    return math.max(min_val or 0, math.min(max_val or math.huge, num))
end

local config = {
    view_distance = validate_config_value(core.settings:get("view_distance"), 1, 20, DEFAULT_VIEW_DISTANCE),
    emergency_view_distance = validate_config_value(core.settings:get("emergency_view_distance"), 1, 10, 3),
    max_cache_size = validate_config_value(core.settings:get("max_cache_size"), 100, 10000, 1000),
    emergency_cache_size = validate_config_value(core.settings:get("emergency_cache_size"), 50, 5000, 500),
    prediction_interval = validate_config_value(core.settings:get("prediction_interval"), 0.1, 5, 0.5),
    emergency_prediction_interval = validate_config_value(core.settings:get("emergency_prediction_interval"), 0.1, 5, 0.5),
    timeout_threshold = validate_config_value(core.settings:get("timeout_threshold"), 1, 30, 5),
    queue_size_threshold = validate_config_value(core.settings:get("queue_size_threshold"), 10, 500, 50),
    cache_miss_threshold = validate_config_value(core.settings:get("cache_miss_threshold"), 0.1, 1, 0.7),
    emergence_time_threshold = validate_config_value(core.settings:get("emergence_time_threshold"), 0.1, 10, 1),
    compression_threshold = validate_config_value(core.settings:get("compression_threshold"), 50, 1000, 100),
    max_timeouts = validate_config_value(core.settings:get("max_timeouts"), 5, 100, 10),
    suspend_duration = validate_config_value(core.settings:get("suspend_duration"), 1, 60, 5),
    batch_size = validate_config_value(core.settings:get("batch_size"), 1, 20, 5),
    batch_interval = validate_config_value(core.settings:get("batch_interval"), 0.05, 1, 0.1),
    unload_timeout = validate_config_value(core.settings:get("unload_timeout"), 10, 300, 30),
    max_players_reduction = validate_config_value(core.settings:get("max_players_reduction"), 0.1, 1, 0.8),
    compression_batch_size = validate_config_value(core.settings:get("compression_batch_size"), 1, 50, 10),
    max_operations_per_tick = validate_config_value(core.settings:get("max_operations_per_tick"), 1, 20, 5),
    max_memory_usage_ratio = validate_config_value(core.settings:get("max_memory_usage_ratio"), 0.1, 0.8, 0.3),
    max_batch_queue_size = validate_config_value(core.settings:get("max_batch_queue_size"), 100, 5000, 1000),
    async_processing = core.settings:get_bool("async_processing", true),
    compression_ratio_threshold = 0.8,
    metrics_log_interval = validate_config_value(core.settings:get("metrics_log_interval"), 10, 3600, 60),
}


local heap = {}

local function heap_compare(cache, a, b)
    local cache_a = cache[a]
    local cache_b = cache[b]

    if not cache_a or not cache_b then
        return cache_a == nil
    end

    local priority_order = {CRITICAL = 4, HIGH = 3, MEDIUM = 2, LOW = 1, BACKGROUND = 0}
    local prio_a = priority_order[cache_a.priority] or 0
    local prio_b = priority_order[cache_b.priority] or 0

    if prio_a ~= prio_b then
        return prio_a < prio_b
    end
    return cache_a.last_used < cache_b.last_used
end


local function heap_heapify_up(h, cache, i)
    while i > 1 do
        local parent = math.floor(i / 2)
        if not heap_compare(cache, h.items[i], h.items[parent]) then
            break
        end
        h.items[i], h.items[parent] = h.items[parent], h.items[i]
        i = parent
    end
end


local function heap_heapify_down(h, cache, i)
    local size = h.size
    while true do
        local left = 2 * i
        local right = 2 * i + 1
        local smallest = i

        if left <= size and heap_compare(cache, h.items[left], h.items[smallest]) then
            smallest = left
        end

        if right <= size and heap_compare(cache, h.items[right], h.items[smallest]) then
            smallest = right
        end

        if smallest == i then
            break
        end

        h.items[i], h.items[smallest] = h.items[smallest], h.items[i]
        i = smallest
    end
end


function heap.insert(h, cache, chunk_key)
    if not chunk_key then return end

    h.size = h.size + 1
    h.items[h.size] = chunk_key
    h.deleted[chunk_key] = false
    heap_heapify_up(h, cache, h.size)
end


function heap.extract_min(h, cache)
    while h.size > MIN_HEAP_SIZE do
        local min_key = h.items[1]

        if not h.deleted[min_key] and cache[min_key] then
            h.items[1] = h.items[h.size]
            h.items[h.size] = nil
            h.size = h.size - 1
            h.deleted[min_key] = nil

            if h.size > MIN_HEAP_SIZE then
                heap_heapify_down(h, cache, 1)
            end

            return min_key
        end

        h.items[1] = h.items[h.size]
        h.items[h.size] = nil
        h.size = h.size - 1
        h.deleted[min_key] = nil

        if h.size > MIN_HEAP_SIZE then
            heap_heapify_down(h, cache, 1)
        end
    end
    return nil
end


function heap.mark_deleted(h, chunk_key)
    if chunk_key then
        h.deleted[chunk_key] = true
    end
end


function heap.new()
    return {
        items = {},
        size = 0,
        deleted = {}
    }
end


local cache_module = {}

local function compress_chunk_data(data, threshold)
    if type(data) ~= "string" or #data <= threshold then
        return data, false
    end

    local success, compressed = pcall(core.compress, data, "deflate")
    if not success then
        return data, false
    end

    if #compressed >= #data * config.compression_ratio_threshold then
        return data, false
    end
    return compressed, true
end


local function decompress_chunk_data(data, is_compressed)
    if not is_compressed or type(data) ~= "string" then
        return data
    end

    -- verif header deflate (0x78)
    if data:sub(1, 1) ~= "\x78" then
        return data
    end

    local success, result = pcall(core.decompress, data, "deflate")
    if not success then
        core.log("warning", "[ChunkManager] Decompression failed, returning raw data")
        return data
    end
    return result
end


local function get_cached_time(cache_time)
    local current_time = core.get_us_time()
    if current_time - cache_time.last > 1000 then
        cache_time.last = current_time
    end
    return cache_time.last
end


function cache_module.add(cache_state, chunk_key, data, priority)
    if not chunk_key or not data then
        return
    end

    local compressed_data, is_compressed = compress_chunk_data(data, config.compression_threshold)
    local was_new = cache_state.cache[chunk_key] == nil

    cache_state.cache[chunk_key] = {
        data = compressed_data,
        is_compressed = is_compressed,
        priority = priority or "MEDIUM",
        last_used = get_cached_time(cache_state.time_cache),
        access_count = cache_state.cache[chunk_key] and (cache_state.cache[chunk_key].access_count + 1) or 1,
    }

    if was_new then
        heap.insert(cache_state.heap, cache_state.cache, chunk_key)
    end
end


function cache_module.get(cache_state, chunk_key)
    if not chunk_key then
        return nil
    end

    local cached = cache_state.cache[chunk_key]
    if not cached then
        cache_state.metrics.cache_misses = cache_state.metrics.cache_misses + 1
        return nil
    end

    cached.access_count = cached.access_count + 1
    cached.last_used = get_cached_time(cache_state.time_cache)
    cache_state.metrics.cache_hits = cache_state.metrics.cache_hits + 1

    return decompress_chunk_data(cached.data, cached.is_compressed)
end


function cache_module.remove(cache_state, chunk_key)
    if cache_state.cache[chunk_key] then
        heap.mark_deleted(cache_state.heap, chunk_key)
        cache_state.cache[chunk_key] = nil
    end
end


function cache_module.cleanup(cache_state, max_size, max_ops)
    local current_size = 0
    for _ in pairs(cache_state.cache) do
        current_size = current_size + 1
    end

    if current_size <= max_size then
        return
    end

    local operations = 0
    while current_size > max_size and operations < max_ops do
        local chunk_key = heap.extract_min(cache_state.heap, cache_state.cache)
        if not chunk_key then
            break
        end

        if cache_state.cache[chunk_key] then
            cache_module.remove(cache_state, chunk_key)
            current_size = current_size - 1
        end

        operations = operations + 1
    end
end


function cache_module.size(cache_state)
    local count = 0
    for _ in pairs(cache_state.cache) do
        count = count + 1
    end
    return count
end


local utils = {}

function utils.get_chunk_key(pos)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        return nil
    end

    return string.format("%d,%d,%d",
        math.floor(pos.x / CHUNK_SIZE),
        math.floor(pos.y / CHUNK_SIZE),
        math.floor(pos.z / CHUNK_SIZE))
end


function utils.parse_chunk_key(chunk_key)
    if not chunk_key or type(chunk_key) ~= "string" then
        return nil
    end

    local cx, cy, cz = chunk_key:match("^([^,]+),([^,]+),([^,]+)$")
    if not cx or not cy or not cz then
        return nil
    end

    return {
        x = tonumber(cx) * CHUNK_SIZE,
        y = tonumber(cy) * CHUNK_SIZE,
        z = tonumber(cz) * CHUNK_SIZE
    }
end


function utils.distance_squared(pos1, pos2)
    if not pos1 or not pos2 then return nil end
    if not pos1.x or not pos1.y or not pos1.z then return nil end
    if not pos2.x or not pos2.y or not pos2.z then return nil end

    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return dx * dx + dy * dy + dz * dz
end


function utils.is_valid_vector(vec)
    return vec and type(vec) == "table" and
           type(vec.x) == "number" and
           type(vec.y) == "number" and
           type(vec.z) == "number"
end


local chunk_manager = {
    enabled = true,
    emergency_mode = false,
    suspended = false,
    suspend_time = 0,

    cache_state = {
        cache = {},
        heap = heap.new(),
        time_cache = {last = core.get_us_time()},
        metrics = {
            cache_hits = 0,
            cache_misses = 0,
        }
    },

    prediction_queue = {},
    batch_queue = {},
    player_data = {},

    metrics = {
        operations_this_tick = 0,
        timeout_count = 0,
        emergence_times = {},
        last_tick_time = core.get_us_time(),
        emergency_triggers = {queue = 0, cache_miss = 0, emergence = 0},
        last_log_time = 0,
    },
    -- flag d'arrêt pour éviter récursion infinie (au cas ou on sais jamais)
    running = false,
}


local function predict_player_movement(player, view_distance)
    if not player then return {} end

    local name = player:get_player_name()
    if not name then return {} end

    local pos = player:get_pos()
    if not utils.is_valid_vector(pos) then return {} end

    local look_dir = player:get_look_dir()
    if not utils.is_valid_vector(look_dir) then
        look_dir = {x = 0, y = 0, z = 1}
    end

    local velocity = player:get_velocity()
    if not utils.is_valid_vector(velocity) then
        velocity = {x = 0, y = 0, z = 0}
    end

    local player_data = chunk_manager.player_data[name]
    if not player_data then
        player_data = {
            last_pos = pos,
            last_time = get_cached_time(chunk_manager.cache_state.time_cache),
            speed = 0,
            direction = look_dir
        }
        chunk_manager.player_data[name] = player_data
    end

    local current_time = get_cached_time(chunk_manager.cache_state.time_cache)
    local dt = (current_time - player_data.last_time) / 1000000

    if dt > 0 then
        local dist_sq = utils.distance_squared(pos, player_data.last_pos) or 0
        player_data.speed = dist_sq > 0 and math.sqrt(dist_sq) / dt or 0
        player_data.last_pos = pos
        player_data.last_time = current_time
        player_data.direction = look_dir
    end

    local predictions = {}
    local current_chunk = utils.get_chunk_key(pos)
    if current_chunk then
        predictions[1] = {pos = pos, priority = "CRITICAL", chunk = current_chunk}
    end

    for i = 1, view_distance do
        local predicted_pos = vector.add(pos, vector.multiply(look_dir, i * CHUNK_SIZE))
        local chunk_key = utils.get_chunk_key(predicted_pos)
        if chunk_key then
            predictions[#predictions + 1] = {pos = predicted_pos, priority = "HIGH", chunk = chunk_key}
        end
    end

    if player_data.speed > 0 then
        local movement_prediction = vector.add(pos, vector.multiply(velocity, 2.0))
        local chunk_key = utils.get_chunk_key(movement_prediction)
        if chunk_key then
            predictions[#predictions + 1] = {pos = movement_prediction, priority = "MEDIUM", chunk = chunk_key}
        end

        -- coté latéraux
        local lateral_offsets = {
            {x = CHUNK_SIZE, y = 0, z = 0},
            {x = -CHUNK_SIZE, y = 0, z = 0},
            {x = 0, y = 0, z = CHUNK_SIZE},
            {x = 0, y = 0, z = -CHUNK_SIZE}
        }

        for _, offset in ipairs(lateral_offsets) do
            local lateral_pos = vector.add(movement_prediction, offset)
            local lateral_chunk_key = utils.get_chunk_key(lateral_pos)
            if lateral_chunk_key then
                predictions[#predictions + 1] = {pos = lateral_pos, priority = "LOW", chunk = lateral_chunk_key}
            end
        end
    end
    return predictions
end


local function queue_emergence(pos, priority)
    if chunk_manager.suspended or not utils.is_valid_vector(pos) then
        return
    end

    local chunk_key = utils.get_chunk_key(pos)
    if not chunk_key then return end

    if cache_module.get(chunk_manager.cache_state, chunk_key) then
        return
    end

    local queue_item = {
        pos = pos,
        priority = priority or "MEDIUM",
        chunk = chunk_key,
        timestamp = get_cached_time(chunk_manager.cache_state.time_cache)
    }

    if priority == "CRITICAL" or priority == "HIGH" then
        table.insert(chunk_manager.prediction_queue, 1, queue_item)
    elseif #chunk_manager.batch_queue < config.max_batch_queue_size then
        chunk_manager.batch_queue[#chunk_manager.batch_queue + 1] = queue_item
    end
end


local function create_emergence_callback(item)
    return function(blockpos, action, calls_remaining, param)
        if not item then return end

        local end_time = get_cached_time(chunk_manager.cache_state.time_cache)
        local emergence_time = end_time - item.timestamp
        local times = chunk_manager.metrics.emergence_times

        times[#times + 1] = emergence_time
        if #times > MAX_EMERGENCE_HISTORY then
            table.remove(times, 1)
        end

        if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
            chunk_manager.metrics.timeout_count = chunk_manager.metrics.timeout_count + 1
        else
            cache_module.add(chunk_manager.cache_state, item.chunk, "loaded", item.priority)
        end
    end
end


local function process_emergence_queue()
    if #chunk_manager.prediction_queue == 0 then
        return
    end

    local item = table.remove(chunk_manager.prediction_queue, 1)
    if not item or not utils.is_valid_vector(item.pos) then
        return
    end

    item.timestamp = get_cached_time(chunk_manager.cache_state.time_cache)

    local success, err = pcall(core.emerge_area, item.pos, item.pos, create_emergence_callback(item), item)
    if not success then
        chunk_manager.metrics.timeout_count = chunk_manager.metrics.timeout_count + 1
        core.log("warning", "[ChunkManager] Emergence failed: " .. tostring(err))
    end
end


local function process_batch_queue()
    if #chunk_manager.batch_queue == 0 then
        return
    end

    local batch_size = math.min(config.batch_size, #chunk_manager.batch_queue)
    for i = 1, batch_size do
        local item = table.remove(chunk_manager.batch_queue, 1)
        if item and utils.is_valid_vector(item.pos) then
            item.timestamp = get_cached_time(chunk_manager.cache_state.time_cache)
            local success, err = pcall(core.emerge_area, item.pos, item.pos, create_emergence_callback(item), item)
            if not success then
                chunk_manager.metrics.timeout_count = chunk_manager.metrics.timeout_count + 1
            end
        end
    end
end


local function check_system_load()
    local current_time = get_cached_time(chunk_manager.cache_state.time_cache)
    chunk_manager.metrics.last_tick_time = current_time

    local queue_size = #chunk_manager.prediction_queue + #chunk_manager.batch_queue
    local total_cache_ops = chunk_manager.cache_state.metrics.cache_hits + chunk_manager.cache_state.metrics.cache_misses
    local cache_miss_ratio = total_cache_ops > 0 and (chunk_manager.cache_state.metrics.cache_misses / total_cache_ops) or 0

    local avg_emergence_time = 0
    local emergence_count = #chunk_manager.metrics.emergence_times
    if emergence_count > 0 then
        local sum = 0
        for _, time in ipairs(chunk_manager.metrics.emergence_times) do
            sum = sum + time
        end
        avg_emergence_time = sum / emergence_count / 1000000 -- converssion en secondes
    end

    local was_emergency = chunk_manager.emergency_mode
    chunk_manager.emergency_mode = queue_size > config.queue_size_threshold or
                                   cache_miss_ratio > config.cache_miss_threshold or
                                   avg_emergence_time > config.emergence_time_threshold

    if chunk_manager.emergency_mode and not was_emergency then
        if queue_size > config.queue_size_threshold then
            chunk_manager.metrics.emergency_triggers.queue = chunk_manager.metrics.emergency_triggers.queue + 1
        end
        if cache_miss_ratio > config.cache_miss_threshold then
            chunk_manager.metrics.emergency_triggers.cache_miss = chunk_manager.metrics.emergency_triggers.cache_miss + 1
        end
        if avg_emergence_time > config.emergence_time_threshold then
            chunk_manager.metrics.emergency_triggers.emergence = chunk_manager.metrics.emergency_triggers.emergence + 1
        end
    end

    if chunk_manager.metrics.timeout_count > config.max_timeouts then
        chunk_manager.suspended = true
        chunk_manager.suspend_time = current_time + (config.suspend_duration * 1000000)
        core.log("warning", "[ChunkManager] System suspended due to timeouts")
    end

    if chunk_manager.suspended and current_time > chunk_manager.suspend_time then
        chunk_manager.suspended = false
        chunk_manager.metrics.timeout_count = 0
        core.log("action", "[ChunkManager] System resumed after suspension")
    end
end


local function unload_old_chunks()
    local current_time = get_cached_time(chunk_manager.cache_state.time_cache)
    local players = core.get_connected_players()
    local chunks_to_remove = {}
    local processed = 0
    local unload_timeout_us = config.unload_timeout * 1000000

    local occupied_chunks = {}
    for _, player in ipairs(players) do
        local pos = player:get_pos()
        if utils.is_valid_vector(pos) then
            local key = utils.get_chunk_key(pos)
            if key then
                occupied_chunks[key] = true
            end
        end
    end

    for chunk_key, cache_data in pairs(chunk_manager.cache_state.cache) do
        if processed >= config.max_operations_per_tick then
            break
        end

        local age = current_time - cache_data.last_used
        if age > unload_timeout_us then
            local chunk_pos = utils.parse_chunk_key(chunk_key)
            if chunk_pos then
                local should_unload = true

                for _, player in ipairs(players) do
                    local player_pos = player:get_pos()
                    if utils.is_valid_vector(player_pos) then
                        local dist_sq = utils.distance_squared(player_pos, chunk_pos)
                        if dist_sq and dist_sq < UNLOAD_DISTANCE_SQ then
                            should_unload = false
                            break
                        end
                    end
                end

                if should_unload then
                    chunks_to_remove[#chunks_to_remove + 1] = chunk_key
                end
            end
        end
        processed = processed + 1
    end

    for _, chunk_key in ipairs(chunks_to_remove) do
        cache_module.remove(chunk_manager.cache_state, chunk_key)
    end
end


local function log_metrics()
    local current_time = get_cached_time(chunk_manager.cache_state.time_cache) / 1000000

    if current_time - chunk_manager.metrics.last_log_time < config.metrics_log_interval then
        return
    end

    chunk_manager.metrics.last_log_time = current_time

    local total_ops = chunk_manager.cache_state.metrics.cache_hits + chunk_manager.cache_state.metrics.cache_misses
    local hit_rate = total_ops > 0 and (chunk_manager.cache_state.metrics.cache_hits / total_ops * 100) or 0

    core.log("action", string.format(
        "[ChunkManager] cache=%d hit_rate=%.1f%% queue=%d+%d emergency=%s suspended=%s timeouts=%d",
        cache_module.size(chunk_manager.cache_state),
        hit_rate,
        #chunk_manager.prediction_queue,
        #chunk_manager.batch_queue,
        tostring(chunk_manager.emergency_mode),
        tostring(chunk_manager.suspended),
        chunk_manager.metrics.timeout_count
    ))
end


local function main_loop()
    if not chunk_manager.enabled or not chunk_manager.running then
        return
    end

    chunk_manager.metrics.operations_this_tick = 0

    if config.async_processing then
        local max_ops = config.max_operations_per_tick

        if chunk_manager.metrics.operations_this_tick < max_ops then
            check_system_load()
            chunk_manager.metrics.operations_this_tick = chunk_manager.metrics.operations_this_tick + 1
        end

        if chunk_manager.metrics.operations_this_tick < max_ops then
            local max_size = chunk_manager.emergency_mode and config.emergency_cache_size or config.max_cache_size
            cache_module.cleanup(chunk_manager.cache_state, max_size, config.max_operations_per_tick)
            chunk_manager.metrics.operations_this_tick = chunk_manager.metrics.operations_this_tick + 1
        end

        if chunk_manager.metrics.operations_this_tick < max_ops then
            unload_old_chunks()
            chunk_manager.metrics.operations_this_tick = chunk_manager.metrics.operations_this_tick + 1
        end
    else
        check_system_load()
        local max_size = chunk_manager.emergency_mode and config.emergency_cache_size or config.max_cache_size
        cache_module.cleanup(chunk_manager.cache_state, max_size, config.max_operations_per_tick)
        unload_old_chunks()
    end

    local players = core.get_connected_players()
    local view_distance = chunk_manager.emergency_mode and config.emergency_view_distance or config.view_distance
    local player_count = #players

    if player_count > 5 then
        view_distance = math.floor(view_distance * config.max_players_reduction)
    end

    local max_players_per_tick = chunk_manager.emergency_mode and 2 or 4
    local players_to_process = math.min(player_count, max_players_per_tick)

    for i = 1, players_to_process do
        local predictions = predict_player_movement(players[i], view_distance)
        local max_predictions = math.min(#predictions, config.max_operations_per_tick)

        for j = 1, max_predictions do
            queue_emergence(predictions[j].pos, predictions[j].priority)
        end
    end

    process_emergence_queue()
    log_metrics()
    collectgarbage("step", 100)

    local interval = chunk_manager.emergency_mode and config.emergency_prediction_interval or config.prediction_interval
    core.after(interval, main_loop)
end


core.register_on_leaveplayer(function(player)
    if not player then return end
    local name = player:get_player_name()
    if name then
        chunk_manager.player_data[name] = nil
    end
end)


core.register_on_mods_loaded(function()
    core.log("action", "[ChunkManager] Initialized with config: " .. 
        "view_distance=" .. config.view_distance .. 
        " cache_size=" .. config.max_cache_size)

    chunk_manager.running = true
    core.after(1, main_loop)
end)


core.register_globalstep(function(dtime)
    if #chunk_manager.batch_queue > 0 then
        process_batch_queue()
    end
end)


core.register_on_shutdown(function()
    chunk_manager.running = false
    chunk_manager.enabled = false
    core.log("action", "[ChunkManager] Shutdown complete. Final cache size: " .. 
        cache_module.size(chunk_manager.cache_state))
end)


chunk_manager.api = {
    get_metrics = function()
        local total_ops = chunk_manager.cache_state.metrics.cache_hits + chunk_manager.cache_state.metrics.cache_misses
        return {
            cache_size = cache_module.size(chunk_manager.cache_state),
            cache_hit_rate = total_ops > 0 and (chunk_manager.cache_state.metrics.cache_hits / total_ops) or 0,
            queue_sizes = {
                prediction = #chunk_manager.prediction_queue,
                batch = #chunk_manager.batch_queue
            },
            emergency_mode = chunk_manager.emergency_mode,
            suspended = chunk_manager.suspended,
            timeout_count = chunk_manager.metrics.timeout_count,
            emergency_triggers = chunk_manager.metrics.emergency_triggers
        }
    end,

    clear_cache = function()
        chunk_manager.cache_state.cache = {}
        chunk_manager.cache_state.heap = heap.new()
        core.log("action", "[ChunkManager] Cache cleared manually")
    end,

    get_config = function()
        return config
    end
}

return chunk_manager
