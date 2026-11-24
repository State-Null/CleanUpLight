--[[
CleanUpLight - Fast, lightweight single-character inventory organizer for Windower 4.

Design principles:
- Strictly single-character: never sends commands or IPC to other clients.
  Orchestrate multi-box runs externally via `send` / `sendaga`.
- Bag-first plain-text layout (`data/bags.txt`): organized by [BAG] headers,
  `@chunk` blocks, and `[KIT:name -> bag]` sets with optional `hoard:` / `dump:`
  per-character directives evaluated locally at runtime.
- Safe kit toggle (`//cul kit <name>`): if ANY unequipped kit item is in
  Inventory, stows it back to the kit's home bag; if NONE are in Inventory, pulls
  the full kit out into Inventory.
- O(1) runtime lookup: pre-indexes `res.items` (and expands any wildcards) ONCE
  at load/reload instead of scanning 23,500+ items per command.
- Non-blocking FIFO queue: rapid `send` commands execute sequentially on fresh
  bag state with gentle packet pacing only when items actually move.
- Official Windower APIs only (`windower.ffxi.move_item`, `windower.ffxi.stack_items`).
]]

_addon.name = 'CleanUpLight'
_addon.author = 'State-Null'
_addon.version = '1.2.1'
_addon.commands = {'cleanuplight', 'cul', 'cleanup'}

local res = require('resources')

local INVENTORY_BAG = 0
local TEMPORARY_BAG = 3
local RECYCLE_BAG = 17

-- Storage bags searched by default on `//cleanup get` / `dump:` (excludes Inventory, Temp, Recycle, Wardrobes)
local DEFAULT_GET_BAGS = {5, 6, 7, 1, 9, 2, 4} -- satchel, sack, case, safe, safe2, storage, locker

-- Static indexes built once at load
local bag_name_to_id = {}
local bag_id_to_name = {}
local bag_is_wardrobe = {}
local name_to_ids = {}

-- Active settings & parsed layout from data/bags.txt
local settings = {
    move_delay = 0.05,
    stack_delay = 0.15,
    job_settle_delay = 0.25,
    quiet_empty = true,
}

-- Compiled layout structures:
--   chunks[name] = {
--       name = string,
--       bag = bag_id | nil,
--       is_kit = bool,
--       hoard = { names = {[lower]=true}, all = bool },
--       dump  = { names = {[lower]=true}, all = bool, others = bool },
--       id_set = {[item_id]=true},
--       ordered_ids = {item_id, ...},
--   }
--   auto_map[item_id] = bag_id          (all non-kit [BAG] sections)
--   all_map[item_id] = bag_id           (normal + all [KIT:name -> bag])
--   bag_maps[bag_id][item_id] = bag_id  (per-bag normal items)
local chunks = {}
local chunk_order = {}
local kits = {}
local auto_map = {}
local all_map = {}
local bag_maps = {}
local active_overlay = nil

-- FIFO command queue (prevents races when multiple `send` commands arrive back-to-back)
local job_queue = {}
local worker_running = false

local function msg_info(text)
    windower.add_to_chat(207, '[CleanUpLight] ' .. text)
end

local function msg_warn(text)
    windower.add_to_chat(167, '[CleanUpLight] ' .. text)
end

local function msg_err(text)
    windower.add_to_chat(123, '[CleanUpLight] ' .. text)
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function wildcard_to_lua_pattern(wc)
    local escaped = wc:lower():gsub('([%^%$%(%)%%%.%[%]%+%-])', '%%%1')
    escaped = escaped:gsub('%*', '.*'):gsub('%?', '.')
    return '^' .. escaped .. '$'
end

local function get_current_player_lower()
    local p = windower.ffxi.get_player()
    if p and p.name and p.name ~= '' then
        return p.name:lower()
    end
    return nil
end

local function parse_role_targets(raw_value, allow_others)
    local spec = { names = {}, all = false, others = false, list = {} }
    if not raw_value then
        return spec
    end
    for token in raw_value:gmatch('[^,%s]+') do
        local low = token:lower()
        if low == 'all' or low == '*' then
            spec.all = true
            spec.list[#spec.list + 1] = 'all'
        elseif allow_others and (low == 'others' or low == 'other') then
            spec.others = true
            spec.list[#spec.list + 1] = 'others'
        else
            if not spec.names[low] then
                spec.names[low] = true
                spec.list[#spec.list + 1] = token
            end
        end
    end
    return spec
end

local function has_role(spec)
    return spec and (spec.all or spec.others or next(spec.names) ~= nil)
end

local function player_matches_hoard(kit, player_low)
    if not player_low or not kit.hoard then
        return false
    end
    return kit.hoard.all or kit.hoard.names[player_low] == true
end

local function player_matches_dump(kit, player_low)
    if not player_low or not kit.dump then
        return false
    end
    -- Hoard always takes precedence over dump: others
    if player_matches_hoard(kit, player_low) then
        return false
    end
    if kit.dump.all or kit.dump.names[player_low] == true then
        return true
    end
    if kit.dump.others then
        return true
    end
    return false
end

local function build_static_indexes()
    bag_name_to_id = {}
    bag_id_to_name = {}
    bag_is_wardrobe = {}

    for id, bag in pairs(res.bags) do
        if id ~= TEMPORARY_BAG and id ~= RECYCLE_BAG then
            bag_id_to_name[id] = bag.en or bag.api or ('Bag ' .. tostring(id))
            if bag.equippable and id ~= INVENTORY_BAG then
                bag_is_wardrobe[id] = true
            end
            if bag.api then
                bag_name_to_id[bag.api:lower()] = id
            end
            if bag.command then
                bag_name_to_id[bag.command:lower()] = id
            end
            if bag.en then
                bag_name_to_id[bag.en:lower()] = id
                bag_name_to_id[bag.en:lower():gsub('%s+', '')] = id
            end
        end
    end
    if bag_name_to_id['wardrobe'] then
        bag_name_to_id['wardrobe1'] = bag_name_to_id['wardrobe']
    end

    name_to_ids = {}
    for id, item in pairs(res.items) do
        if item.en then
            local k = item.en:lower()
            local list = name_to_ids[k]
            if not list then
                list = {}
                name_to_ids[k] = list
            end
            list[#list + 1] = id
        end
        if item.enl then
            local k = item.enl:lower()
            local list = name_to_ids[k]
            if not list then
                list = {}
                name_to_ids[k] = list
            end
            local exists = false
            for i = 1, #list do
                if list[i] == id then
                    exists = true
                    break
                end
            end
            if not exists then
                list[#list + 1] = id
            end
        end
    end
end

local function resolve_bag(name)
    if not name then
        return nil
    end
    local key = trim(name):lower():gsub('%s+', '')
    return bag_name_to_id[key] or bag_name_to_id[trim(name):lower()]
end

local function resolve_item_ids(raw_name)
    local has_wc = raw_name:find('[%*%?]') ~= nil
    if not has_wc then
        return name_to_ids[raw_name:lower()] or {}
    end

    local pat = wildcard_to_lua_pattern(raw_name)
    local seen = {}
    local ids = {}
    for id, item in pairs(res.items) do
        local matched = false
        if item.en and item.en:lower():match(pat) then
            matched = true
        elseif item.enl and item.enl:lower():match(pat) then
            matched = true
        end
        if matched and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

local function register_chunk(store, order_list, kit_list, dup_warnings, raw_name, bag_id, is_kit, line_no, file_label, is_overlay)
    local key = raw_name:lower()
    if store[key] then
        local existing = store[key]
        if is_overlay then
            if bag_id then
                existing.bag = bag_id
            end
        else
            dup_warnings[#dup_warnings + 1] = ('%s line %d: duplicate chunk/kit name "%s" (rename one to avoid merging)'):format(file_label, line_no, raw_name)
        end
        return existing
    end
    local c = {
        name = raw_name,
        bag = bag_id,
        is_kit = is_kit,
        hoard = { names = {}, all = false, others = false, list = {} },
        dump = { names = {}, all = false, others = false, list = {} },
        id_set = {},
        ordered_ids = {},
    }
    store[key] = c
    order_list[#order_list + 1] = key
    if is_kit then
        kit_list[#kit_list + 1] = c
    end
    return c
end

local function bootstrap_bags_file(path)
    local example_path = windower.addon_path .. 'data/bags.example.txt'
    local src = io.open(example_path, 'r')
    if not src then
        return false
    end
    local content = src:read('*a')
    src:close()

    local dst = io.open(path, 'w')
    if not dst then
        return false
    end
    dst:write(content)
    dst:close()
    msg_info('Created starter data/bags.txt from data/bags.example.txt — edit it and run //cul reload.')
    return true
end

local function parse_layout_file(f, file_label, is_overlay, state)
    local new_settings = state.settings
    local new_chunks = state.chunks
    local new_order = state.order
    local new_kits = state.kits
    local new_auto_map = state.auto_map
    local new_all_map = state.all_map
    local new_bag_maps = state.bag_maps
    local unknown_items = state.unknown_items
    local warnings = state.warnings

    local mode = nil        -- 'settings' | 'bag' | 'kit'
    local cur_bag_id = nil
    local cur_chunk = nil
    local line_no = 0

    local function assign_bag_item(item_id, bag_id)
        local prev_bag = new_auto_map[item_id]
        if prev_bag and prev_bag ~= bag_id and new_bag_maps[prev_bag] then
            new_bag_maps[prev_bag][item_id] = nil
        end
        new_auto_map[item_id] = bag_id
        new_all_map[item_id] = bag_id
        new_bag_maps[bag_id][item_id] = bag_id
    end

    for raw_line in f:lines() do
        line_no = line_no + 1
        if line_no == 1 and raw_line:sub(1, 3) == '\239\187\191' then
            raw_line = raw_line:sub(4)
        end

        local line = trim(raw_line)
        if line ~= '' and line:sub(1, 1) ~= '#' and line:sub(1, 2) ~= '//' then
            -- Strip inline `//` comments (never strip `#` inline because items like `Dial Key #Ab` use `#`)
            local comment_pos = line:find('%s+//')
            if comment_pos then
                line = trim(line:sub(1, comment_pos - 1))
            end

            if line == '' then
                -- empty after comment
            elseif line:sub(1, 1) == '[' and line:sub(-1) == ']' then
                local header = trim(line:sub(2, -2))
                local hlow = header:lower()

                if hlow == 'settings' then
                    mode = 'settings'
                    cur_bag_id = nil
                    cur_chunk = nil

                elseif hlow:sub(1, 4) == 'kit:' or hlow:sub(1, 6) == 'extra:' then
                    mode = 'kit'
                    local rest = header:gsub('^%a+:', '')
                    local kit_name, arrow_bag = rest:match('^%s*(.-)%s*%->%s*(.-)%s*$')
                    if not kit_name then
                        kit_name = trim(rest)
                    end

                    local dst_bag = nil
                    if arrow_bag and arrow_bag ~= '' then
                        dst_bag = resolve_bag(arrow_bag)
                        if not dst_bag or dst_bag == INVENTORY_BAG then
                            warnings[#warnings + 1] = ('%s line %d: invalid kit bag "%s"'):format(file_label, line_no, arrow_bag)
                            dst_bag = nil
                        end
                    end

                    cur_bag_id = dst_bag
                    if kit_name ~= '' then
                        cur_chunk = register_chunk(new_chunks, new_order, new_kits, warnings, kit_name, dst_bag, true, line_no, file_label, is_overlay)
                    else
                        warnings[#warnings + 1] = ('%s line %d: empty kit name'):format(file_label, line_no)
                        cur_chunk = nil
                    end

                else
                    local bag_id = resolve_bag(header)
                    if bag_id and bag_id ~= INVENTORY_BAG then
                        mode = 'bag'
                        cur_bag_id = bag_id
                        cur_chunk = nil
                        if not new_bag_maps[bag_id] then
                            new_bag_maps[bag_id] = {}
                        end
                    else
                        warnings[#warnings + 1] = ('%s line %d: unknown section "[%s]"'):format(file_label, line_no, header)
                        mode = nil
                        cur_bag_id = nil
                        cur_chunk = nil
                    end
                end

            elseif mode == 'settings' then
                local k, v = line:match('^([%w_]+)%s*=%s*(.-)$')
                if k and v then
                    k = k:lower()
                    v = trim(v):lower()
                    if k == 'quiet_empty' then
                        new_settings.quiet_empty = (v == 'true' or v == '1' or v == 'yes')
                    elseif k == 'move_delay' or k == 'stack_delay' or k == 'job_settle_delay' then
                        local num = tonumber(v)
                        if num and num >= 0 then
                            new_settings[k] = num
                        end
                    end
                end

            elseif line:sub(1, 1) == '@' then
                if mode == 'bag' and cur_bag_id then
                    local cname = trim(line:sub(2))
                    if cname ~= '' then
                        cur_chunk = register_chunk(new_chunks, new_order, new_kits, warnings, cname, cur_bag_id, false, line_no, file_label, is_overlay)
                    end
                else
                    warnings[#warnings + 1] = ('%s line %d: "%s" must be inside a [BAG] section'):format(file_label, line_no, line)
                end

            elseif mode == 'kit' and cur_chunk and line:match('^[%a_]+%s*:') then
                local directive, val = line:match('^([%a_]+)%s*:%s*(.-)$')
                local dlow = directive and directive:lower()
                if dlow == 'hoard' or dlow == 'horde' then
                    cur_chunk.hoard = parse_role_targets(val, false)
                elseif dlow == 'dump' or dlow == 'trade' or dlow == 'pull' or dlow == 'give' then
                    cur_chunk.dump = parse_role_targets(val, true)
                else
                    -- Could be an item name with a colon (e.g. `A. Voucher: Weapon`) — fall through to item lookup!
                    local ids = resolve_item_ids(line)
                    if #ids == 0 then
                        unknown_items[#unknown_items + 1] = line
                    else
                        for i = 1, #ids do
                            local item_id = ids[i]
                            if not cur_chunk.id_set[item_id] then
                                cur_chunk.id_set[item_id] = true
                                cur_chunk.ordered_ids[#cur_chunk.ordered_ids + 1] = item_id
                            end
                            if cur_bag_id and (is_overlay or not new_all_map[item_id]) then
                                new_all_map[item_id] = cur_bag_id
                            end
                        end
                    end
                end

            elseif mode == 'bag' or mode == 'kit' then
                if mode == 'bag' and not cur_chunk and cur_bag_id then
                    local default_name = (res.bags[cur_bag_id] and res.bags[cur_bag_id].api) or ('bag' .. tostring(cur_bag_id))
                    cur_chunk = new_chunks[default_name:lower()]
                        or register_chunk(new_chunks, new_order, new_kits, warnings, default_name, cur_bag_id, false, line_no, file_label, is_overlay)
                end

                if cur_chunk then
                    local ids = resolve_item_ids(line)
                    if #ids == 0 then
                        unknown_items[#unknown_items + 1] = line
                    else
                        for i = 1, #ids do
                            local item_id = ids[i]
                            if not cur_chunk.id_set[item_id] then
                                cur_chunk.id_set[item_id] = true
                                cur_chunk.ordered_ids[#cur_chunk.ordered_ids + 1] = item_id
                            end

                            if mode == 'bag' and cur_bag_id then
                                assign_bag_item(item_id, cur_bag_id)
                            elseif mode == 'kit' and cur_bag_id then
                                if is_overlay or not new_all_map[item_id] then
                                    new_all_map[item_id] = cur_bag_id
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function find_character_overlay()
    local p = windower.ffxi.get_player()
    if not p or not p.name or p.name == '' then
        return nil, nil
    end
    local candidates = {
        'data/' .. p.name .. '.txt',
        'data/' .. p.name .. '_bags.txt',
    }
    for _, rel in ipairs(candidates) do
        local f = io.open(windower.addon_path .. rel, 'r')
        if f then
            return f, rel
        end
    end
    return nil, nil
end

local function load_layout()
    local path = windower.addon_path .. 'data/bags.txt'
    local f, err = io.open(path, 'r')
    if not f then
        if bootstrap_bags_file(path) then
            f, err = io.open(path, 'r')
        end
    end
    if not f then
        msg_err('Failed to open data/bags.txt: ' .. tostring(err))
        return false
    end

    local state = {
        settings = {
            move_delay = 0.05,
            stack_delay = 0.15,
            job_settle_delay = 0.25,
            quiet_empty = true,
        },
        chunks = {},
        order = {},
        kits = {},
        auto_map = {},
        all_map = {},
        bag_maps = {},
        unknown_items = {},
        warnings = {},
    }

    parse_layout_file(f, 'data/bags.txt', false, state)
    f:close()

    -- Optional per-character overlay (`data/<CharName>.txt` or `data/<CharName>_bags.txt`)
    local overlay_f, overlay_rel = find_character_overlay()
    if overlay_f then
        parse_layout_file(overlay_f, overlay_rel, true, state)
        overlay_f:close()
    end

    settings = state.settings
    chunks = state.chunks
    chunk_order = state.order
    kits = state.kits
    auto_map = state.auto_map
    all_map = state.all_map
    bag_maps = state.bag_maps
    active_overlay = overlay_rel

    for _, w in ipairs(state.warnings) do
        msg_warn(w)
    end
    if #state.unknown_items > 0 then
        msg_warn('Unknown item(s): ' .. table.concat(state.unknown_items, ', '))
    end

    return true
end

local function is_bag_enabled(bag_id)
    local info = windower.ffxi.get_bag_info(bag_id)
    return info and info.enabled == true
end

local function get_bag_free_slots(bag_id)
    local info = windower.ffxi.get_bag_info(bag_id)
    if not info or not info.enabled then
        return 0, false
    end
    local free = (info.max or 0) - (info.count or 0)
    return free > 0 and free or 0, true
end

-- Execute a single move pass (mode = 'put' | 'get') inside the worker coroutine
local function run_pass(mode, item_map_or_set, source_bag, label, dry)
    local moves = {}
    local skipped_equipped = {}
    local skipped_non_equip = {}
    local disabled_bags = {}

    if mode == 'put' then
        local inv = windower.ffxi.get_items(INVENTORY_BAG)
        if not inv then
            return 0
        end

        local max_slots = inv.max or #inv
        for i = 1, max_slots do
            local item = inv[i]
            if item and item.id and item.id ~= 0 then
                local dst = item_map_or_set[item.id]
                if dst and dst ~= INVENTORY_BAG then
                    local r = res.items[item.id]
                    local iname = r and r.en or ('Item #' .. tostring(item.id))

                    if not is_bag_enabled(dst) then
                        disabled_bags[dst] = true
                    elseif bag_is_wardrobe[dst] and (not r or not r.slots) then
                        skipped_non_equip[#skipped_non_equip + 1] = iname
                    elseif (item.status or 0) ~= 0 then
                        skipped_equipped[#skipped_equipped + 1] = iname
                    else
                        moves[#moves + 1] = {
                            src_bag = INVENTORY_BAG,
                            dst_bag = dst,
                            slot = item.slot or i,
                            count = item.count or 1,
                            id = item.id,
                        }
                    end
                end
            end
        end

    elseif mode == 'get' then
        local source_bags = source_bag and {source_bag} or DEFAULT_GET_BAGS
        for _, src_bag in ipairs(source_bags) do
            if src_bag ~= INVENTORY_BAG and is_bag_enabled(src_bag) then
                local bag_items = windower.ffxi.get_items(src_bag)
                if bag_items then
                    local max_slots = bag_items.max or #bag_items
                    for i = 1, max_slots do
                        local item = bag_items[i]
                        if item and item.id and item.id ~= 0 and item_map_or_set[item.id] then
                            if (item.status or 0) ~= 0 then
                                local r = res.items[item.id]
                                skipped_equipped[#skipped_equipped + 1] = r and r.en or ('Item #' .. tostring(item.id))
                            else
                                moves[#moves + 1] = {
                                    src_bag = src_bag,
                                    dst_bag = INVENTORY_BAG,
                                    slot = item.slot or i,
                                    count = item.count or 1,
                                    id = item.id,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    if dry then
        if #moves == 0 then
            msg_info(('Dry run (%s): nothing to move.'):format(label))
        else
            msg_info(('Dry run (%s): would move %d slot(s):'):format(label, #moves))
            for _, mv in ipairs(moves) do
                local r = res.items[mv.id]
                local iname = r and r.en or ('Item #' .. tostring(mv.id))
                local qty_str = mv.count > 1 and (' x' .. tostring(mv.count)) or ''
                msg_info(('  %s%s: %s -> %s'):format(
                    iname,
                    qty_str,
                    bag_id_to_name[mv.src_bag] or tostring(mv.src_bag),
                    bag_id_to_name[mv.dst_bag] or tostring(mv.dst_bag)
                ))
            end
        end
        if #skipped_equipped > 0 then
            msg_warn('Would skip equipped/locked: ' .. table.concat(skipped_equipped, ', '))
        end
        if #skipped_non_equip > 0 then
            msg_warn('Would skip non-equippable (wardrobe target): ' .. table.concat(skipped_non_equip, ', '))
        end
        return 0
    end

    local move_delay = settings.move_delay or 0.05
    local stack_delay = settings.stack_delay or 0.15

    local free_slots = {}
    local stack_bags = {}
    local moved_per_bag = {}
    local full_skipped = {}
    local moved_slots = 0

    for _, mv in ipairs(moves) do
        local dst = mv.dst_bag
        if free_slots[dst] == nil then
            free_slots[dst] = get_bag_free_slots(dst)
        end

        if free_slots[dst] <= 0 and stack_bags[dst] then
            windower.ffxi.stack_items(dst)
            stack_bags[dst] = nil
            coroutine.sleep(0.35)
            free_slots[dst] = get_bag_free_slots(dst)
        end

        if free_slots[dst] <= 0 then
            full_skipped[dst] = (full_skipped[dst] or 0) + 1
        else
            if moved_slots > 0 and move_delay > 0 then
                coroutine.sleep(move_delay)
            end

            windower.ffxi.move_item(mv.src_bag, dst, mv.slot, mv.count)
            moved_slots = moved_slots + 1
            free_slots[dst] = free_slots[dst] - 1
            moved_per_bag[dst] = (moved_per_bag[dst] or 0) + 1

            local r = res.items[mv.id]
            if r and r.stack and r.stack > 1 then
                stack_bags[dst] = true
            end
        end
    end

    if next(stack_bags) ~= nil then
        if stack_delay > 0 then
            coroutine.sleep(stack_delay)
        end
        for bag_id in pairs(stack_bags) do
            windower.ffxi.stack_items(bag_id)
        end
    end

    if moved_slots > 0 then
        local parts = {}
        for bag_id, cnt in pairs(moved_per_bag) do
            parts[#parts + 1] = ('%d -> %s'):format(cnt, bag_id_to_name[bag_id] or tostring(bag_id))
        end
        table.sort(parts)
        msg_info(('%s: moved %d slot(s) (%s).'):format(label, moved_slots, table.concat(parts, ', ')))
    elseif not settings.quiet_empty then
        msg_info(('%s: nothing to move.'):format(label))
    end

    if #skipped_equipped > 0 then
        msg_warn('Skipped equipped/locked: ' .. table.concat(skipped_equipped, ', '))
    end
    if #skipped_non_equip > 0 then
        msg_warn('Skipped non-equippable (wardrobe target): ' .. table.concat(skipped_non_equip, ', '))
    end
    for bag_id, cnt in pairs(full_skipped) do
        msg_warn(('%s is full — skipped %d slot(s).'):format(bag_id_to_name[bag_id] or tostring(bag_id), cnt))
    end
    for bag_id in pairs(disabled_bags) do
        msg_warn(('%s is not currently accessible.'):format(bag_id_to_name[bag_id] or tostring(bag_id)))
    end

    return moved_slots
end

local function make_chunk_put_map(chunk, override_bag_id)
    local dst = override_bag_id or chunk.bag
    if not dst or dst == INVENTORY_BAG then
        return nil, nil
    end
    local m = {}
    for _, id in ipairs(chunk.ordered_ids) do
        m[id] = dst
    end
    return m, dst
end

-- Execute a queued job inside the worker coroutine
local function execute_job(job)
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in then
        return 0
    end

    if job.mode == 'go' then
        local player_low = get_current_player_lower()
        local stow_map = {}
        for item_id, bag_id in pairs(auto_map) do
            stow_map[item_id] = bag_id
        end

        local dump_set = {}
        local has_dump = false

        for _, kit in ipairs(kits) do
            if kit.bag and player_matches_hoard(kit, player_low) then
                for _, id in ipairs(kit.ordered_ids) do
                    stow_map[id] = kit.bag
                end
            elseif player_matches_dump(kit, player_low) then
                for _, id in ipairs(kit.ordered_ids) do
                    -- Never stow an item that this character is configured to dump
                    stow_map[id] = nil
                    dump_set[id] = true
                    has_dump = true
                end
            end
        end

        -- Phase 1: Stow normal bags + this character's `hoard:` kits (frees Inventory slots first)
        local moved1 = run_pass('put', stow_map, nil, 'go (stow)', job.dry)

        -- Phase 2: Pull this character's `dump:` kits into Inventory
        local moved2 = 0
        if has_dump then
            if moved1 > 0 and not job.dry then
                local settle = settings.job_settle_delay or 0.25
                if settle > 0 then
                    coroutine.sleep(settle)
                end
            end
            moved2 = run_pass('get', dump_set, nil, 'go (dump)', job.dry)
        end

        return moved1 + moved2

    elseif job.mode == 'kit_toggle' then
        local kit = job.kit
        local inv = windower.ffxi.get_items(INVENTORY_BAG)
        local inv_unequipped = 0
        if inv then
            local max_slots = inv.max or #inv
            for i = 1, max_slots do
                local item = inv[i]
                if item and item.id and item.id ~= 0 and kit.id_set[item.id] and (item.status or 0) == 0 then
                    inv_unequipped = inv_unequipped + 1
                end
            end
        end

        -- Safe toggle rule:
        --   Any unequipped kit item in Inventory -> stow back to home bag
        --   None in Inventory -> pull full kit out from home bag (or storage bags)
        if inv_unequipped > 0 then
            local map, dst = make_chunk_put_map(kit, nil)
            if not map then
                msg_err(('No home bag configured for kit "%s". Use //cul put %s <bag>.'):format(kit.name, kit.name))
                return 0
            end
            return run_pass('put', map, nil, ('kit %s -> %s'):format(kit.name, bag_id_to_name[dst] or tostring(dst)), job.dry)
        else
            local src = kit.bag
            local lbl = src
                and ('kit %s <- %s'):format(kit.name, bag_id_to_name[src] or tostring(src))
                or ('kit %s -> Inventory'):format(kit.name)
            return run_pass('get', kit.id_set, src, lbl, job.dry)
        end

    else
        return run_pass(job.mode, job.item_map_or_set, job.source_bag, job.label, job.dry)
    end
end

local function process_queue()
    worker_running = true
    local settle_delay = settings.job_settle_delay or 0.25

    while #job_queue > 0 do
        local job = table.remove(job_queue, 1)
        local ok, moved = pcall(execute_job, job)
        if not ok then
            msg_err('Error during ' .. tostring(job.label) .. ': ' .. tostring(moved))
        elseif moved and moved > 0 and #job_queue > 0 and settle_delay > 0 then
            coroutine.sleep(settle_delay)
        end
    end

    worker_running = false
end

local function enqueue_job(job)
    job_queue[#job_queue + 1] = job
    if not worker_running then
        coroutine.schedule(process_queue, 0)
    end
end

local function parse_and_enqueue(args, dry)
    local cmd = args[1] and args[1]:lower() or 'go'

    if cmd == 'go' or cmd == 'shared' or cmd == 'run' then
        enqueue_job({
            mode = 'go',
            label = 'go',
            dry = dry,
        })
        return
    end

    if cmd == 'all' then
        enqueue_job({
            mode = 'put',
            item_map_or_set = all_map,
            label = 'all',
            dry = dry,
        })
        return
    end

    if cmd == 'kit' then
        local target = args[2] and args[2]:lower()
        local kit = target and chunks[target]
        if not kit or not kit.is_kit then
            msg_err('Unknown kit: "' .. tostring(args[2] or '(none)') .. '". Use //cul list to view kits.')
            return
        end
        enqueue_job({
            mode = 'kit_toggle',
            kit = kit,
            label = 'kit ' .. kit.name,
            dry = dry,
        })
        return
    end

    if cmd == 'put' then
        local target = args[2] and args[2]:lower()
        local chunk = target and chunks[target]
        if not chunk then
            msg_err('Unknown chunk/kit for put: ' .. tostring(args[2] or '(none)'))
            return
        end

        local override_bag = nil
        if args[3] then
            override_bag = resolve_bag(args[3])
            if not override_bag or override_bag == INVENTORY_BAG then
                msg_err('Invalid destination bag: ' .. tostring(args[3]))
                return
            end
        end

        local map, dst = make_chunk_put_map(chunk, override_bag)
        if not map then
            msg_err(('No destination bag set for "%s". Specify one: //cul put %s <bag>'):format(chunk.name, chunk.name))
            return
        end

        enqueue_job({
            mode = 'put',
            item_map_or_set = map,
            label = ('put %s -> %s'):format(chunk.name, bag_id_to_name[dst] or tostring(dst)),
            dry = dry,
        })
        return
    end

    if cmd == 'get' then
        local target = args[2] and args[2]:lower()
        local chunk = target and chunks[target]
        if not chunk then
            msg_err('Unknown chunk/kit for get: ' .. tostring(args[2] or '(none)'))
            return
        end

        local source_bag = nil
        if args[3] then
            source_bag = resolve_bag(args[3])
            if not source_bag or source_bag == INVENTORY_BAG then
                msg_err('Invalid source bag: ' .. tostring(args[3]))
                return
            end
        end

        enqueue_job({
            mode = 'get',
            item_map_or_set = chunk.id_set,
            source_bag = source_bag,
            label = source_bag
                and ('get %s <- %s'):format(chunk.name, bag_id_to_name[source_bag] or tostring(source_bag))
                or ('get ' .. chunk.name),
            dry = dry,
        })
        return
    end

    -- Configured [BAG] shortcut (e.g., `//cleanup satchel`, `//cleanup case`)
    local bag_id = resolve_bag(cmd)
    if bag_id and bag_maps[bag_id] then
        enqueue_job({
            mode = 'put',
            item_map_or_set = bag_maps[bag_id],
            label = bag_id_to_name[bag_id] or cmd,
            dry = dry,
        })
        return
    end

    -- Chunk/kit shortcut: `//cleanup <chunk>` stows that chunk to its home bag
    local chunk = chunks[cmd]
    if chunk then
        local map, dst = make_chunk_put_map(chunk, nil)
        if not map then
            msg_err(('No destination bag set for "%s". Use //cul put %s <bag>.'):format(chunk.name, chunk.name))
            return
        end
        enqueue_job({
            mode = 'put',
            item_map_or_set = map,
            label = ('%s -> %s'):format(chunk.name, bag_id_to_name[dst] or tostring(dst)),
            dry = dry,
        })
        return
    end

    msg_err('Unknown command, bag, or chunk: "' .. tostring(args[1]) .. '". Use //cul help.')
end

local function show_help()
    local lines = {
        'Usage (aliases: //cleanuplight, //cul, //cleanup — orchestrate multi-box via send / sendaga):',
        '  //cul go                   - Normal sweep ([BAG] sections + your hoard/dump kits)',
        '  //cul all                  - Full pack-up (stows ALL [BAG] + [KIT] sections)',
        '  //cul kit <name>           - Toggle kit (any in Inventory -> stow; none -> pull out)',
        '  //cul <bag|chunk>          - Stow one bag (satchel/case) or chunk (utility/abby)',
        '  //cul put <chunk> [bag]    - Stow chunk from Inventory to [bag] (default: home bag)',
        '  //cul get <chunk> [bag]    - Pull chunk to Inventory from [bag] (default: storage bags)',
        '  //cul dry <go|all|kit ...> - Preview moves without touching items',
        '  //cul list                 - List bags, chunks, kits, and active hoard/dump role',
        '  //cul verbose              - Toggle printing "nothing to move" messages',
        '  //cul reload               - Reload data/bags.txt live',
    }
    for _, line in ipairs(lines) do
        msg_info(line)
    end
end

local function show_list()
    local player_low = get_current_player_lower()
    local normal_parts = {}
    local kit_parts = {}

    for _, key in ipairs(chunk_order) do
        local c = chunks[key]
        local bname = c.bag and bag_id_to_name[c.bag] or 'none'
        if c.is_kit then
            local role = ''
            if player_matches_hoard(c, player_low) then
                role = ', YOU:hoard'
            elseif player_matches_dump(c, player_low) then
                role = ', YOU:dump'
            elseif has_role(c.hoard) or has_role(c.dump) then
                role = ', YOU:skip'
            end
            kit_parts[#kit_parts + 1] = ('%s (%d -> %s%s)'):format(c.name, #c.ordered_ids, bname, role)
        else
            normal_parts[#normal_parts + 1] = ('%s (%d -> %s)'):format(c.name, #c.ordered_ids, bname)
        end
    end

    if #normal_parts > 0 then
        msg_info('Normal (go): ' .. table.concat(normal_parts, ' | '))
    end
    if #kit_parts > 0 then
        msg_info('Kits (kit/all): ' .. table.concat(kit_parts, ' | '))
    end
    if active_overlay then
        msg_info('Active character overlay: ' .. active_overlay)
    end
end

windower.register_event('load', function()
    build_static_indexes()
    load_layout()
end)

windower.register_event('login', function()
    load_layout()
end)

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args[1] and args[1]:lower() or nil

    if not cmd or cmd == 'help' or cmd == 'h' then
        show_help()
        return
    elseif cmd == 'reload' or cmd == 'r' then
        if load_layout() then
            if active_overlay then
                msg_info('Reloaded data/bags.txt + ' .. active_overlay .. ' cleanly.')
            else
                msg_info('Reloaded data/bags.txt cleanly.')
            end
        end
        return
    elseif cmd == 'list' or cmd == 'groups' then
        show_list()
        return
    elseif cmd == 'verbose' or cmd == 'quiet' then
        settings.quiet_empty = not settings.quiet_empty
        msg_info('quiet_empty = ' .. tostring(settings.quiet_empty))
        return
    elseif cmd == 'dry' or cmd == 'preview' then
        local sub = {}
        for i = 2, #args do
            sub[#sub + 1] = args[i]
        end
        parse_and_enqueue(sub, true)
        return
    end

    parse_and_enqueue(args, false)
end)
