local modname = core.get_current_modname()
local S = core.get_translator(modname)

local chunk_manager = {
    enabled = true,
    emergency_mode = false,
    suspended = false,
    cache = {},
    prediction_queue = {},
    batch_queue = {},
    player_data = {},
    suspend_time = 0,
    compression_queue = {},
    operations_this_tick = 0,
    timeout_count = 0,
    cache_hits = 0,
    cache_misses = 0,
    emergence_times = {},
    last_tick_time = core.get_us_time(),
}

local function validate_config_value(value, min_val, max_val, default)
    local num = tonumber(value)

    if not num then
        return default
    end

    return math.max(min_val or 0, math.min(max_val or math.huge, num))
end

chunk_manager.config = {
    view_distance = validate_config_value(core.settings:get("view_distance"), 1, 20, 5),
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
}

local last_timestamp = core.get_us_time()

local function get_cached_time()
    local current_time = core.get_us_time()

    if current_time - last_timestamp > 1000 then
        last_timestamp = current_time
    end

    return last_timestamp
end

local cache_heap = {
    items = {},
    size = 0,
    deleted = {},
    priority_order = {CRITICAL = 4, HIGH = 3, MEDIUM = 2, LOW = 1, BACKGROUND = 0}
}

local function get_chunk_key(pos)
    local chunk_size = 16

    return string.format("%d,%d,%d",
        math.floor(pos.x / chunk_size),
        math.floor(pos.y / chunk_size),
        math.floor(pos.z / chunk_size))
end

local function heap_compare(a, b)
    local cache_a = chunk_manager.cache[a]
    local cache_b = chunk_manager.cache[b]

    if not cache_a or not cache_b then
        return cache_a == nil
    end

    local prio_a = cache_heap.priority_order[cache_a.priority] or 0
    local prio_b = cache_heap.priority_order[cache_b.priority] or 0

    if prio_a ~= prio_b then
        return prio_a < prio_b
    end

    return cache_a.last_used < cache_b.last_used
end

local function heap_heapify_up(heap, i)
    while i > 1 do
        local parent = math.floor(i / 2)

        if not heap_compare(heap.items[i], heap.items[parent]) then
            break
        end

        heap.items[i], heap.items[parent] = heap.items[parent], heap.items[i]
        i = parent
    end
end

local function heap_heapify_down(heap, i)
    local size = heap.size

    while true do
        local left = 2 * i
        local right = 2 * i + 1
        local smallest = i

        if left <= size and heap_compare(heap.items[left], heap.items[smallest]) then
            smallest = left
        end

        if right <= size and heap_compare(heap.items[right], heap.items[smallest]) then
            smallest = right
        end

        if smallest == i then
            break
        end

        heap.items[i], heap.items[smallest] = heap.items[smallest], heap.items[i]
        i = smallest
    end
end

local function heap_insert(heap, chunk_key)
    heap.size = heap.size + 1
    heap.items[heap.size] = chunk_key
    heap.deleted[chunk_key] = false
    heap_heapify_up(heap, heap.size)
end

local function heap_extract_min(heap)
    while heap.size > 0 do
        local min_key = heap.items[1]

        if not heap.deleted[min_key] and chunk_manager.cache[min_key] then
            heap.items[1] = heap.items[heap.size]
            heap.items[heap.size] = nil
            heap.size = heap.size - 1
            heap.deleted[min_key] = nil

            if heap.size > 0 then
                heap_heapify_down(heap, 1)
            end

            return min_key
        end

        heap.items[1] = heap.items[heap.size]
        heap.items[heap.size] = nil
        heap.size = heap.size - 1
        heap.deleted[min_key] = nil

        if heap.size > 0 then
            heap_heapify_down(heap, 1)
        end
    end
    return nil
end

local function compress_chunk_data(data)
    if #data > chunk_manager.config.compression_threshold then
        local compressed = core.compress(data, "deflate")
        return compressed, true
    end
    return data, false
end

local function decompress_chunk_data(data, is_compressed)
    if is_compressed and type(data) == "string" and data:sub(1, 1) == "\x78" then
        local success, result = pcall(core.decompress, data, "deflate")

        if success then
            return result
        end
    end
    return data
end

local function add_to_cache(chunk_key, data, priority)
    if not chunk_key or not data then
        return
    end

    local compressed_data, is_compressed = compress_chunk_data(data)
    local was_new = chunk_manager.cache[chunk_key] == nil

    chunk_manager.cache[chunk_key] = {
        data = compressed_data,
        is_compressed = is_compressed,
        priority = priority or "MEDIUM",
        last_used = get_cached_time(),
        access_count = 1,
    }

    if was_new then
        heap_insert(cache_heap, chunk_key)
    end
end

local function get_from_cache(chunk_key)
    local cached = chunk_manager.cache[chunk_key]

    if cached then
        cached.access_count = cached.access_count + 1
        cached.last_used = get_cached_time()
        chunk_manager.cache_hits = chunk_manager.cache_hits + 1
        return decompress_chunk_data(cached.data, cached.is_compressed)
    end

    chunk_manager.cache_misses = chunk_manager.cache_misses + 1

    return nil
end

local function remove_from_cache(chunk_key)
    if chunk_manager.cache[chunk_key] then
        cache_heap.deleted[chunk_key] = true
        chunk_manager.cache[chunk_key] = nil
    end
end

local function cleanup_cache()
    local max_size = chunk_manager.emergency_mode and chunk_manager.config.emergency_cache_size or chunk_manager.config.max_cache_size
    local current_size = 0

    for _ in pairs(chunk_manager.cache) do
        current_size = current_size + 1
    end

    local max_operations = chunk_manager.config.max_operations_per_tick
    local operations = 0

    while current_size > max_size and operations < max_operations do
        local chunk_key = heap_extract_min(cache_heap)

        if not chunk_key then
            break
        end

        if chunk_manager.cache[chunk_key] then
            remove_from_cache(chunk_key)
            current_size = current_size - 1
        end

        operations = operations + 1
    end
end

local function check_system_load()
    local current_time = get_cached_time()

    chunk_manager.last_tick_time = current_time

    local queue_size = #chunk_manager.prediction_queue + #chunk_manager.batch_queue
    local total_cache_ops = chunk_manager.cache_hits + chunk_manager.cache_misses
    local cache_miss_ratio = total_cache_ops > 0 and (chunk_manager.cache_misses / total_cache_ops) or 0
    local avg_emergence_time = 0
    local emergence_count = #chunk_manager.emergence_times

    if emergence_count > 0 then
        local sum = 0

        for _, time in ipairs(chunk_manager.emergence_times) do
            sum = sum + time
        end

        avg_emergence_time = sum / emergence_count / 1000000
    end

    chunk_manager.emergency_mode = queue_size > chunk_manager.config.queue_size_threshold or
                                  cache_miss_ratio > chunk_manager.config.cache_miss_threshold or
                                  avg_emergence_time > chunk_manager.config.emergence_time_threshold


    if chunk_manager.timeout_count > chunk_manager.config.max_timeouts then
        chunk_manager.suspended = true
        chunk_manager.suspend_time = current_time + (chunk_manager.config.suspend_duration * 1000000)
    end

    if chunk_manager.suspended and current_time > chunk_manager.suspend_time then
        chunk_manager.suspended = false
        chunk_manager.timeout_count = 0
    end

end

local function predict_player_movement(player)
    local name = player:get_player_name()
    local pos = player:get_pos()
    local look_dir = player:get_look_dir()
    local velocity = player:get_velocity()
    local player_data = chunk_manager.player_data[name]

    if not player_data then
        player_data = {
            last_pos = pos,
            last_time = get_cached_time(),
            speed = 0,
            direction = look_dir
        }
        chunk_manager.player_data[name] = player_data
    end

    local current_time = get_cached_time()
    local dt = (current_time - player_data.last_time) / 1000000

    if dt > 0 then
        local dist_sq = vector.distance(pos, player_data.last_pos)^2

        player_data.speed = dist_sq > 0 and math.sqrt(dist_sq) / dt or 0
        player_data.last_pos = pos
        player_data.last_time = current_time
        player_data.direction = look_dir
    end

    local predictions = {}
    local view_distance = chunk_manager.emergency_mode and chunk_manager.config.emergency_view_distance or chunk_manager.config.view_distance
    local player_count = #core.get_connected_players()

    if player_count > 5 then
        view_distance = math.floor(view_distance * chunk_manager.config.max_players_reduction)
    end

    local current_chunk = get_chunk_key(pos)
    predictions[1] = {pos = pos, priority = "CRITICAL", chunk = current_chunk}

    for i = 1, view_distance do
        local predicted_pos = vector.add(pos, vector.multiply(look_dir, i * 16))
        local chunk_key = get_chunk_key(predicted_pos)
        predictions[i + 1] = {pos = predicted_pos, priority = "HIGH", chunk = chunk_key}
    end

    if player_data.speed > 0 then
        local movement_prediction = vector.add(pos, vector.multiply(velocity, 2.0))
        local chunk_key = get_chunk_key(movement_prediction)

        table.insert(predictions, {pos = movement_prediction, priority = "MEDIUM", chunk = chunk_key})

        local lateral_offsets = {
            {x = 16, y = 0, z = 0},
            {x = -16, y = 0, z = 0},
            {x = 0, y = 0, z = 16},
            {x = 0, y = 0, z = -16}
        }

        for _, offset in ipairs(lateral_offsets) do
            local lateral_pos = vector.add(movement_prediction, offset)
            local lateral_chunk_key = get_chunk_key(lateral_pos)
            table.insert(predictions, {pos = lateral_pos, priority = "LOW", chunk = lateral_chunk_key})
        end

    end
    return predictions
end

local function queue_emergence(pos, priority)
    if chunk_manager.suspended then
        return
    end

    local chunk_key = get_chunk_key(pos)

    if get_from_cache(chunk_key) then
        return
    end

    local queue_item = {
        pos = pos,
        priority = priority,
        chunk = chunk_key,
        timestamp = get_cached_time()
    }

    if priority == "CRITICAL" or priority == "HIGH" then
        table.insert(chunk_manager.prediction_queue, 1, queue_item)
    elseif #chunk_manager.batch_queue < chunk_manager.config.max_batch_queue_size then
        table.insert(chunk_manager.batch_queue, queue_item)
    end

end

local function create_emergence_callback(item)
    return function(blockpos, action, calls_remaining, param)

        local end_time = get_cached_time()
        local emergence_time = end_time - item.timestamp
        local times = chunk_manager.emergence_times

        times[#times + 1] = emergence_time

        if #times > 100 then
            table.remove(times, 1)
        end

        if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
            chunk_manager.timeout_count = chunk_manager.timeout_count + 1
        else
            add_to_cache(item.chunk, "loaded", item.priority)
        end

    end
end

local function process_emergence_queue()
    if #chunk_manager.prediction_queue == 0 then
        return
    end

    local item = table.remove(chunk_manager.prediction_queue, 1)

    item.timestamp = get_cached_time()

    local success, err = pcall(core.emerge_area, item.pos, item.pos, create_emergence_callback(item), item)

    if not success then
        chunk_manager.timeout_count = chunk_manager.timeout_count + 1
    end
end

local function process_batch_queue()
    if #chunk_manager.batch_queue == 0 then
        return
    end

    local batch_size = math.min(chunk_manager.config.batch_size, #chunk_manager.batch_queue)

    for i = 1, batch_size do
        local item = table.remove(chunk_manager.batch_queue, 1)

        if item then
            item.timestamp = get_cached_time()
            local success, err = pcall(core.emerge_area, item.pos, item.pos, create_emergence_callback(item), item)
            if not success then
                chunk_manager.timeout_count = chunk_manager.timeout_count + 1
            end
        end

    end
end

local function unload_old_chunks()
    local current_time = get_cached_time()
    local players = core.get_connected_players()
    local chunks_to_remove = {}
    local processed = 0
    local unload_timeout_us = chunk_manager.config.unload_timeout * 1000000

    for chunk_key, cache_data in pairs(chunk_manager.cache) do
        if processed >= chunk_manager.config.max_operations_per_tick then
            break
        end

        local age = current_time - cache_data.last_used

        if age > unload_timeout_us then
            local cx, cy, cz = chunk_key:match("([^,]+),([^,]+),([^,]+)")

            if cx and cy and cz then

                local chunk_pos = {
                    x = tonumber(cx) * 16,
                    y = tonumber(cy) * 16,
                    z = tonumber(cz) * 16
                }

                local should_unload = true

                for _, player in ipairs(players) do
                    local player_pos = player:get_pos()
                    local dist_sq = vector.distance(player_pos, chunk_pos)^2

                    if dist_sq < 40000 then -- 200^2
                        should_unload = false
                        break
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
        remove_from_cache(chunk_key)
    end
end

local function main_loop()
    if not chunk_manager.enabled then
        return
    end

    chunk_manager.operations_this_tick = 0

    if chunk_manager.config.async_processing then
        local max_ops = chunk_manager.config.max_operations_per_tick

        if chunk_manager.operations_this_tick < max_ops then
            check_system_load()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end

        if chunk_manager.operations_this_tick < max_ops then
            cleanup_cache()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end

        if chunk_manager.operations_this_tick < max_ops then
            unload_old_chunks()
            chunk_manager.operations_this_tick = chunk_manager.operations_this_tick + 1
        end
    else
        check_system_load()
        cleanup_cache()
        unload_old_chunks()
    end

    local players = core.get_connected_players()
    local interval = chunk_manager.emergency_mode and chunk_manager.config.emergency_prediction_interval or chunk_manager.config.prediction_interval
    local max_players_per_tick = chunk_manager.emergency_mode and 2 or 4
    local player_count = math.min(#players, max_players_per_tick)

    for i = 1, player_count do
        local predictions = predict_player_movement(players[i])
        local max_predictions = math.min(#predictions, chunk_manager.config.max_operations_per_tick)

        for j = 1, max_predictions do
            queue_emergence(predictions[j].pos, predictions[j].priority)
        end

    end

    process_emergence_queue()
    collectgarbage("step", 100)

    core.after(interval, main_loop)
end


core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    chunk_manager.player_data[name] = nil
end)

core.register_on_mods_loaded(function()
    core.after(1, main_loop)
end)

core.register_globalstep(function(dtime)
    if #chunk_manager.batch_queue > 0 then
        process_batch_queue()
    end
end)
