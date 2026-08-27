--=============================================================================
-- ec26 GamePlay Mod V1.6 (Reviewed & Fixed)
-- Integrates: Real Referee assembly cave + Dynamic Match Tempo AOB +
-- Sprint Touch / Dribble Friction + Ball Weight / Ball StopForce / 
-- Shooting Power / Player Reaction Speed + Injury Mod.
--
-- FIXES IN V1.4:
-- 1. Idempotency guards on physics & injury address resolution (prevents
--    double-patching game code if init runs more than once).
-- 2. Fixed INI parser to ignore inline comments (#) and handle profile names
--    containing spaces in active-profile config.
-- 3. _ADV sections are now preserved on save instead of being silently dropped.
-- 4. Added math.randomseed so injury severity rolls are actually random.
-- 5. Unified ptr_to_num with ffi + pure-Lua fallback (removed redundant 
--    injury_ptr_to_num).
-- 6. Hardened integer-vs-float detection when writing INI (epsilon check).
-- 7. Added path-separator safety for sider_dir.
-- 8. Added min/max bounds to DOGSO parameter (0/1).
-- 9. Tempo denominator safety-clamp to prevent division by zero / negative.
-- 10. Reload (NUM 0) now re-applies active profile settings immediately.
-- 11. Consistent numeric addressing for DOGSO patch site.
--
-- FIXES IN V1.6:
-- 12. resolve_rel32 no longer writes back to the game's own instruction
--     bytes. It previously patched the original rel32 displacement in
--     place as an unnecessary side effect of address resolution -- this
--     permanently altered real game code (Ball StopForce, Ball Weight,
--     Shooting Power, Player Reaction AOB sites) every session at
--     m.init(), whether or not those fields were ever used afterward.
--     Now purely reads and computes; game code is left untouched. Return
--     value is unchanged (verified arithmetically equivalent to the old
--     write-then-return path).
--=============================================================================

local m = {}
m.version = "ec26 GamePlay v1.6 (Referee AOB + Tempo + Sprint/Dribble + Ball/Shot Physics + Injury)"

local profiles_file = ""
local config_file = ""

local profiles = {}
local profile_names = {}
local adv_profile_names = {}
local current_idx = 1
local selected_profile = "DEFAULT"
local saved_profile = "DEFAULT"
local infoText = "SYSTEM READY"
local last_key_time = 0
local edit_idx = 1

-- ============================================================
-- HELPERS
-- ============================================================
local function path_combine(dir, file)
    if not dir or dir == "" then return file end
    local last = dir:sub(-1)
    if last == "\\" or last == "/" then
        return dir .. file
    end
    return dir .. "\\" .. file
end

local function is_integer(val)
    if type(val) ~= "number" then return false end
    return math.abs(val - math.floor(val + 0.5)) < 0.0001
end

local function clamp(val, lo, hi)
    return math.max(lo, math.min(hi, math.floor(val or 0)))
end

-- Robust pointer-to-number: uses ffi when available, falls back to parsing
-- the string representation so injury mod works even without ffi.
local function ptr_to_num(p)
    if ffi then
        local val = tonumber(ffi.cast("uint64_t", p))
        if val and val ~= 0 then return val end
    end
    local s = tostring(p)
    local hex = s:match("0x(%x+)")
    if hex then return tonumber(hex, 16) end
    return tonumber(s)
end

-- ============================================================
-- PHYSICS FIELD ADDRESSES (Sprint/Dribble w/ fallback, Ball/Shot AOB-only)
-- ============================================================
local phys_addr = {
    ball_weight     = nil,
    ball_stopforce  = nil,
    shootingpower   = nil,
    player_reaction = nil,
}
local phys_source = {}

local physics_resolved = false

-- FIXED (21 Aug 2026): this function previously wrote the shifted rel32
-- displacement back into the game's own instruction bytes via memory.write.
-- That write was never needed -- resolving an absolute address only
-- requires READING the original displacement and adding extra_offset to
-- the final computed address, not mutating the instruction operand in
-- place. The old version permanently patched real game code as a side
-- effect of address resolution, unconditionally, once per session, at
-- every m.init(). See /areas/ec26-gameplay-engine.md for the review that
-- caught this (confirmed against Kimi K3's original flag on v1.4).
local function resolve_rel32(loc, extra_offset)
    local rel = memory.unpack("i32", memory.read(loc, 4))
    return loc + 4 + rel + extra_offset
end

local function resolve_physics_addresses()
    if physics_resolved then return end
    physics_resolved = true

    -- Ball StopForce
    local loc = memory.search_process("\x0f\x28\xc1\xf3\x0f\x58\xc1\xf3\x0f\x5c\xc6\xf3\x0f\x10\x38\x0f\x57\xed\xf3\x0f\x59\x3d")
    if loc then
        phys_addr.ball_stopforce = resolve_rel32(loc + 0x16, 0x0c)
        phys_source.ball_stopforce = "aob"
    else
        phys_source.ball_stopforce = "unresolved"
        log("EC26_Hybrid: Ball StopForce AOB not found, field will not be written this session")
    end

    -- Ball Weight
    loc = memory.search_process("\xf3\x44\x0f\x10\x5c\x24\x40\xf3\x0f\x10\x7c\x24\x44\xf3\x44\x0f\x10\x64\x24\x48\xf3\x41")
    if loc then
        phys_addr.ball_weight = resolve_rel32(loc - 4, 0x32)
        phys_source.ball_weight = "aob"
    else
        phys_source.ball_weight = "unresolved"
        log("EC26_Hybrid: Ball Weight AOB not found, field will not be written this session")
    end

    -- Shooting Power
    loc = memory.search_process("\xf3\x41\x0f\x59\xc5\xf3\x0f\x59\xca\xf3\x44\x0f\x58\xc0")
    if loc then
        phys_addr.shootingpower = resolve_rel32(loc + 0x2b, 8)
        phys_source.shootingpower = "aob"
    else
        phys_source.shootingpower = "unresolved"
        log("EC26_Hybrid: Shooting Power AOB not found, field will not be written this session")
    end

    -- Player Reaction Speed
    loc = memory.search_process("\x48\x8b\xfa\x0f\x29\x74\x24\x20\x48\x8b\xd9\xf3\x41\x0f\x10\x30\xf3\x0f\x59\x35")
    if loc then
        loc = loc + 0x14 + 8
        phys_addr.player_reaction = resolve_rel32(loc, 4)
        phys_source.player_reaction = "aob"
    else
        phys_source.player_reaction = "unresolved"
        log("EC26_Hybrid: Player Reaction Speed AOB not found, field will not be written this session")
    end

    for field, addr in pairs(phys_addr) do
        if addr then
            log(string.format("EC26_Hybrid: %s resolved to %s (%s)", field, memory.hex(addr), phys_source[field]))
        end
    end
end

-- ============================================================
-- TEMPO MEMORY POINTERS & HELPERS
-- ============================================================
local object_addr = nil
local game_speed_addr = nil

local function speed_value_from_game_speed(game_speed)
    local denom = 54 + (game_speed or 0) * 3
    if denom < 1 then denom = 1 end
    return 1000000 / denom
end

local function get_game_speed_addr()
    if not object_addr then return nil end
    local mpointer = memory.unpack("i64", memory.read(object_addr, 8))
    if mpointer == 0 or not mpointer then return nil end
    local loc = mpointer + 0x50
    local mpointer2 = memory.unpack("i64", memory.read(loc, 8))
    if mpointer2 == 0 or not mpointer2 then return nil end
    return mpointer2 + 0x38
end

local function apply_tempo(tempo_val)
    if not tempo_val then return end
    game_speed_addr = get_game_speed_addr()
    if game_speed_addr then
        local value = speed_value_from_game_speed(tempo_val)
        memory.write(game_speed_addr, memory.pack("d", value))
    end
end

-- ============================================================
-- FFI / MEMORY SETUP (REFEREE SYSTEM)
-- ============================================================
if ffi ~= nil then
    ffi.cdef[[
    typedef void* LPVOID;
    typedef uint64_t SIZE_T;
    typedef uint32_t DWORD;
    typedef uint8_t BYTE;
    BYTE* VirtualAlloc(LPVOID lpAddress, SIZE_T dwSize, DWORD flAllocationType, DWORD flProtect);
    ]]
end

local THUNK_101    = "\xE9\x7B\x04\x9F\x03"
local THUNK_107    = "\xE9\xEB\xE8\xA3\x03"
local DOGSO_AOB    = "\x83\xFF\x04\xB8\x03\x00\x00\x00\x0F\x44\xF8"
local DOGSO_CMOVZ_OFFSET = 8

local FN_AOB = {
    GetTeamRosterData   = "\x83\xFA\x02\x73\x12\x48\x63\xC2\x48\x05\xA3\x00\x00\x00",
    GetTeamData         = "\x83\xFA\x16\x73\x12\x48\x63\xC2\x48\x05\xF3\x00\x00\x00",
    GetAdjustedPosition = "\x48\x89\x5C\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xEC\x20\x48\x8B\xF9\x41\x8B\xD0",
    PenaltyAreaCheck    = "\x48\x83\xEC\x28\xF3\x0F\x10\x19\x0F\x57\xC0\x0F\x29\x74\x24\x10",
}

local thunk_addr_num  = nil
local cave_ptr        = nil
local dogso_match_ptr = nil
local dogso_match_num = nil
local FN_resolved     = {}
local gMC_addr_num    = nil
local aob_active      = false

-- ============================================================
-- INJURY MOD (v1.4)
-- ============================================================
local INJURY_FREQUENCY_AOB = '\x3B\xC7\x0F\x8D\xDA\x01\x00\x00'
local INJURY_SEVERITY_AOB  = '\xC7\x44\x24\x60\x0D\x00\x00\x00\x48\x8D\x95'
local INJURY_CAVE_AOB      = string.rep('\xCC', 32)

local injury_frequency_addr = nil
local injury_severity_addr  = nil
local injury_cave_addr      = nil
local injury_frequency_num  = nil
local injury_cave_num       = nil

local injury_enabled_frequency = false
local injury_enabled_severity  = false
local injury_last_written_freq = nil
local injury_initialized       = false

local INJURY_WEIGHTING_PRESETS = {
    { name = "Safe Space", desc = "Nearly no long term injuries",
      weights = { {0x17, 88}, {0x3C, 7}, {0x78, 3}, {0xB4, 1}, {0xF8, 1} } },
    { name = "Standard", desc = "slight chance of long term injuries",
      weights = { {0x17, 55}, {0x3C, 22}, {0x78, 13}, {0xB4, 6}, {0xF8, 4} } },
    { name = "Realistic", desc = "You will see long term injuries!",
      weights = { {0x17, 30}, {0x3C, 30}, {0x78, 22}, {0xB4, 11}, {0xF8, 7} } },
    { name = "Severe", desc = "60% of injuries are serious",
      weights = { {0x17, 18}, {0x3C, 28}, {0x78, 28}, {0xB4, 16}, {0xF8, 10} } },
    { name = "Brutal", desc = "Good luck!",
      weights = { {0x17, 8}, {0x3C, 20}, {0x78, 32}, {0xB4, 24}, {0xF8, 16} } },
}

local function injury_int_to_bytes(n)
    if type(n) ~= "number" or n ~= n then
        error("injury_int_to_bytes: invalid input (not a number): " .. tostring(n))
    end
    if n < -0x80000000 or n > 0xFFFFFFFF then
        error("injury_int_to_bytes: value out of 32-bit range: " .. tostring(n))
    end
    if n < 0 then n = n + 0x100000000 end
    local b1 = n % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = math.floor(n / 65536) % 256
    local b4 = math.floor(n / 16777216) % 256
    return string.char(b1, b2, b3, b4)
end

local function injury_write_frequency_cave(freq_modifier)
    if not injury_cave_addr or not injury_cave_num or not injury_frequency_num then
        return false
    end
    freq_modifier = clamp(freq_modifier, 1, 255)
    if freq_modifier < 1 or freq_modifier > 255 then
        log("EC26_Hybrid: ABORT injury_write_frequency_cave - out of range: " .. tostring(freq_modifier))
        return false
    end

    local return_addr = injury_frequency_num + 8
    local original_jnl_target = injury_frequency_num + 8 + 0x1DA
    local jnl_offset = original_jnl_target - (injury_cave_num + 11)
    local jmp_back = return_addr - (injury_cave_num + 16)

    local cave_code =
        string.char(0x83, 0xC7, freq_modifier) ..
        string.char(0x3B, 0xC7) ..
        string.char(0x0F, 0x8D) .. injury_int_to_bytes(jnl_offset) ..
        string.char(0xE9) .. injury_int_to_bytes(jmp_back)

    if #cave_code > 32 then
        log("EC26_Hybrid: ABORT injury_write_frequency_cave - cave_code exceeds 32-byte cave")
        return false
    end

    memory.write(injury_cave_addr, cave_code)
    injury_last_written_freq = freq_modifier
    return true
end

local function injury_get_weighted_range(weight_level)
    weight_level = clamp(weight_level, 1, #INJURY_WEIGHTING_PRESETS)
    local preset = INJURY_WEIGHTING_PRESETS[weight_level]
    local weights = preset.weights

    local roll = math.random(100)
    local cumulative = 0
    for _, w in ipairs(weights) do
        cumulative = cumulative + w[2]
        if roll <= cumulative then return w[1] end
    end
    return weights[#weights][1]
end

local function injury_write_weighted_severity(weight_level)
    if not injury_severity_addr then return false end
    local range_value = injury_get_weighted_range(weight_level)
    local severity_byte_addr = injury_severity_addr + 4
    memory.write(severity_byte_addr, string.char(range_value))
    return true
end

local function apply_injury_mod()
    local v = profiles[saved_profile]
    if not v then return end

    if injury_enabled_frequency and v.injury_freq ~= nil then
        local freq = clamp(v.injury_freq, 1, 255)
        if freq ~= injury_last_written_freq then
            injury_write_frequency_cave(freq)
        end
    end

    if injury_enabled_severity and v.injury_weight ~= nil then
        injury_write_weighted_severity(v.injury_weight)
    end
end

-- ============================================================
-- PARAMETER DATABASE
-- ============================================================
local param_list = {
    {name = "Sprint Touch",  key = "e18", step = 0.01},
    {name = "Dribble Frict", key = "e19", step = 0.01},
    {name = "Match Tempo",   key = "e30", step = 0.05},

    -- MEMORY/AOB REFEREE
    {name = "C1 Out(Foul)",  key = "c1o", step = 1},
    {name = "C1 In (Pen)",   key = "c1i", step = 1},
    {name = "C2 (Yellow)",   key = "c2",  step = 1},
    {name = "C3 (Red)",      key = "c3",  step = 1},
    {name = "DOGSO (0/1)",   key = "dogso", step = 1, min = 0, max = 1},

    -- BALL/SHOT PHYSICS
    {name = "Ball Weight",   key = "ball_weight",    step = 10},
    {name = "Ball StopForce",key = "ball_stopforce", step = 0.02},
    {name = "Shooting Power",key = "shootingpower",  step = 10},
    {name = "Player React",  key = "player_reaction",step = 0.002},

    -- INJURY MOD
    {name = "Injury Freq",   key = "injury_freq",   step = 1, min = 1, max = 255},
    {name = "Injury Weight", key = "injury_weight", step = 1, min = 1, max = 5},
}

-- ============================================================
-- MEMORY INJECTION LOGIC (AOB REFEREE)
-- ============================================================
local function alloc_near(target, size)
    local GRAN = 0x10000
    target = ptr_to_num(target)
    local base = target - (target % GRAN)
    for i = 1, 8192 do
        local lo = base - i * GRAN
        if lo > 0 then
            local p = ffi.C.VirtualAlloc(ffi.cast("void*", ffi.cast("uint64_t", lo)), size, 0x3000, 0x40)
            if p ~= nil and ptr_to_num(p) ~= 0 then return p end
        end
        local hi = base + i * GRAN
        local p = ffi.C.VirtualAlloc(ffi.cast("void*", ffi.cast("uint64_t", hi)), size, 0x3000, 0x40)
        if p ~= nil and ptr_to_num(p) ~= 0 then return p end
    end
    return nil
end

local function build_cave(gMC_addr, FN, C1_in, C1_out, C2, C3)
    local p64 = function(a) return memory.pack("u64", a) end
    local function abscall(addr) return "\x48\xB8" .. p64(addr) .. "\xFF\xD0" end
    local function load_gMC() return "\x48\xB8" .. p64(gMC_addr) .. "\x48\x8B\x08" end

    return table.concat({
        "\x48\x89\x5C\x24\x08\x48\x89\x6C\x24\x10\x48\x89\x74\x24\x20\x57\x41\x56\x41\x57\x48\x83\xEC\x30",
        "\x49\x89\xCE\x48\x89\xD7", load_gMC(), "\x44\x89\xC2\x44\x89\xCD\x44\x89\xC6\x4C\x8B\xB9\xA8\x2A\x00\x00",
        abscall(FN.GetTeamRosterData),
        "\x31\xD2\x85\xF6\x78\x0B\x83\xFE\x0B\x7C\x06\x83\xFE\x16\x0F\x9C\xC2",
        load_gMC(), abscall(FN.GetTeamData),
        "\x49\x8B\x96\xB8\x03\x00\x00\x48\x8D\x4C\x24\x20\x41\x89\xE9\x41\x89\xF0\x48\x8B\xD8\x48\x8B\x12",
        abscall(FN.GetAdjustedPosition),
        "\x0F\xB6\x83\x54\x02\x00\x00\x4C\x8D\x4C\x24\x60\xF3\x0F\x10\x54\x24\x28\x4C\x89\xF9\xF3\x0F\x10\x4C\x24\x20\x88\x44\x24\x60",
        abscall(FN.PenaltyAreaCheck),
        "\x0F\xBA\xE0\x0B\x73\x05\xC6\x07", string.char(C1_in),
        "\xEB\x03\xC6\x07", string.char(C1_out),
        "\xC6\x47\x01", string.char(C2),
        "\xC6\x47\x02", string.char(C3),
        "\x48\x8B\x5C\x24\x50\x48\x8B\x6C\x24\x58\x48\x8B\x74\x24\x68\x48\x83\xC4\x30\x41\x5F\x41\x5E\x5F\xC3"
    })
end

local function apply_active_aob()
    local v = profiles[saved_profile]
    if not v then return end

    if aob_active then
        local C1_out = clamp(v.c1o, 0, 254)
        local C1_in  = clamp(v.c1i, 0, 254)
        local C1_max = math.max(C1_out, C1_in)
        local C2     = clamp(v.c2, C1_max + 1, 254)
        local C3     = clamp(v.c3, C2 + 1, 255)
        local is_dogso = (v.dogso == 1)

        if cave_ptr and gMC_addr_num and FN_resolved.GetTeamRosterData then
            local code = build_cave(gMC_addr_num, FN_resolved, C1_in, C1_out, C2, C3)
            memory.write(cave_ptr, code)
        end

        if dogso_match_num then
            local byte3 = memory.read(dogso_match_num + DOGSO_CMOVZ_OFFSET, 3)
            local is_noped = (byte3 == "\x90\x90\x90")
            if is_dogso and not is_noped then
                memory.write(dogso_match_num + DOGSO_CMOVZ_OFFSET, "\x90\x90\x90")
            elseif not is_dogso and is_noped then
                memory.write(dogso_match_num + DOGSO_CMOVZ_OFFSET, "\x0F\x44\xF8")
            end
        end
    end
end

-- ============================================================
-- INI SAVING & LOADING
-- ============================================================
local function load_profiles()
    local t = {}
    local p_names = {}
    local adv_names = {}
    local f = io.open(profiles_file, "r")
    if not f then return {DEFAULT={}}, {"DEFAULT"}, {} end
    
    local current_section = nil
    for line in f:lines() do
        local section = string.match(line, "^%s*%[([^%]]+)%]")
        if section then
            current_section = section
            t[current_section] = {}
            if not string.match(current_section, "_ADV$") then
                table.insert(p_names, current_section)
            else
                table.insert(adv_names, current_section)
            end
        elseif current_section then
            local k, v_str = string.match(line, "^%s*([%w_]+)%s*=%s*([^%s#]+)")
            if k and v_str then
                local v = tonumber(v_str) or v_str
                t[current_section][k] = v
            end
        end
    end
    f:close()
    if #p_names == 0 then table.insert(p_names, "DEFAULT") t.DEFAULT = {} end

    local PHYS_DEFAULTS = {
        ball_weight = 3600, ball_stopforce = -0.5,
        shootingpower = 1000, player_reaction = 5,
    }
    for _, section in pairs(t) do
        for key, default_val in pairs(PHYS_DEFAULTS) do
            if section[key] == nil then
                section[key] = default_val
            end
        end
    end

    local INJURY_DEFAULTS = { injury_freq = 1, injury_weight = 3 }
    for _, section in pairs(t) do
        for key, default_val in pairs(INJURY_DEFAULTS) do
            if section[key] == nil then
                section[key] = default_val
            end
        end
    end

    return t, p_names, adv_names
end

local function save_all_profiles()
    local f = io.open(profiles_file, "w")
    if not f then return false end

    local function write_section(name)
        f:write(string.format("[%s]\n", name))
        local data = profiles[name] or {}
        
        for _, item in ipairs(param_list) do
            local val = data[item.key]
            if val ~= nil then
                if is_integer(val) then
                    f:write(string.format("%s = %d\n", item.key, val))
                else
                    f:write(string.format("%s = %s\n", item.key, val))
                end
            end
        end

        -- Preserve any extra keys (e.g. _ADV sections, future params)
        for k, v in pairs(data) do
            local known = false
            for _, item in ipairs(param_list) do
                if item.key == k then known = true; break end
            end
            if not known then
                if type(v) == "number" then
                    if is_integer(v) then
                        f:write(string.format("%s = %d\n", k, v))
                    else
                        f:write(string.format("%s = %s\n", k, v))
                    end
                else
                    f:write(string.format("%s = %s\n", k, tostring(v)))
                end
            end
        end
        f:write("\n")
    end

    for _, name in ipairs(profile_names) do write_section(name) end
    for _, name in ipairs(adv_profile_names) do write_section(name) end

    f:close()
    return true
end

local function load_config()
    local f = io.open(config_file, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content then
            local profile = string.match(content, "active_profile%s*=%s*([^%c]+)")
            if profile then
                profile = profile:match("^%s*(.-)%s*$")
                if profile and profile ~= "" then return profile end
            end
        end
    end
    return "DEFAULT"
end

local function save_config(profile_name)
    local f = io.open(config_file, "w")
    if f then 
        f:write("active_profile=" .. tostring(profile_name) .. "\n")
        f:close()
        return true 
    end
    return false
end

-- ============================================================
-- RUNTIME APPLICATION
-- ============================================================
function m.set_match_settings(ctx, settings)
    if not settings or ctx.is_simulated_match then return end
    
    local v = profiles[saved_profile]
    if not v then return end

    apply_active_aob()

    if v.e30 then apply_tempo(v.e30) end

    if v.e18 then memory.write(0x143D1A310, memory.pack("f", v.e18)) end
    if v.e19 then memory.write(0x1412F5C10, memory.pack("f", v.e19)) end

    if v.ball_weight and phys_addr.ball_weight then
        memory.write(phys_addr.ball_weight, memory.pack("f", v.ball_weight))
    end
    if v.ball_stopforce and phys_addr.ball_stopforce then
        memory.write(phys_addr.ball_stopforce, memory.pack("f", v.ball_stopforce))
    end
    if v.shootingpower and phys_addr.shootingpower then
        memory.write(phys_addr.shootingpower, memory.pack("f", v.shootingpower))
    end
    if v.player_reaction and phys_addr.player_reaction then
        memory.write(phys_addr.player_reaction, memory.pack("f", v.player_reaction))
    end

    apply_injury_mod()
end

function m.set_teams(ctx, home, away)
    local v = profiles[saved_profile]
    if v and v.e30 then
        apply_tempo(v.e30)
    end
end

-- ============================================================
-- UI OVERLAY
-- ============================================================
function m.overlay_on(ctx)
    local p = profiles[selected_profile] or {}
    local aob_str = aob_active and "ONLINE" or "OFFLINE (AOB Error)"
    
    local out = "========================================================================\n"
    out = out .. "  EC26 (By Cakir) - Referee AOB + Tempo + Sprint/Dribble + Ball/Shot  \n"
    out = out .. "========================================================================\n"
    out = out .. string.format(" ACTIVE IN MATCH: %-15s | RAM INJECT: %s\n", saved_profile, aob_str)
    out = out .. string.format(" VIEWING/EDITING: %-15s | STATUS: %s\n", selected_profile, infoText)
    out = out .. "------------------------------------------------------------------------\n"
    
    local half = math.ceil(#param_list / 2)
    for i = 1, half do
        local idx1 = i
        local item1 = param_list[idx1]
        local prefix1 = (idx1 == edit_idx) and " >>>" or "    "
        local val1 = p[item1.key] or 0
        local str1 = string.format("%s %-14s : %6.3f", prefix1, item1.name, val1)
        
        local str2 = ""
        local idx2 = i + half
        local item2 = param_list[idx2]
        if item2 then
            local prefix2 = (idx2 == edit_idx) and " >>>" or "    "
            local val2 = p[item2.key] or 0
            str2 = string.format("   ||%s %-14s : %6.3f", prefix2, item2.name, val2)
        end

        out = out .. str1 .. str2 .. "\n"
    end

    out = out .. "------------------------------------------------------------------------\n"
    out = out .. " [NUM 7] / [NUM 9] : PREV/NEXT LEAGUE   | [NUM 0]         : RELOAD INI \n"
    out = out .. " [NUM 8] / [NUM 5] : SELECT PARAMETER   | [NUM ENTER]/[+] : SAVE EDITED PARAMS\n"
    out = out .. " [NUM 4] / [NUM 6] : CHANGE VALUE       | \n"
    out = out .. "========================================================================"
    return out
end

function m.key_down(ctx, vkey)
    local now = os.clock()
    if now - last_key_time < 0.15 then return end
    last_key_time = now

    local p = profiles[selected_profile]
    if not p then return end

    if vkey == 0x67 and #profile_names > 0 then
        -- NUM 7 (PREV LEAGUE)
        current_idx = ((current_idx - 2 + #profile_names) % #profile_names) + 1
        selected_profile = profile_names[current_idx]
        saved_profile = selected_profile
        save_config(saved_profile)
        apply_active_aob()
        if p and p.e30 then apply_tempo(p.e30) end
        injury_last_written_freq = nil
        apply_injury_mod()
        infoText = "AUTO-APPLIED: " .. selected_profile
    elseif vkey == 0x69 and #profile_names > 0 then
        -- NUM 9 (NEXT LEAGUE)
        current_idx = (current_idx % #profile_names) + 1
        selected_profile = profile_names[current_idx]
        saved_profile = selected_profile
        save_config(saved_profile)
        apply_active_aob()
        if p and p.e30 then apply_tempo(p.e30) end
        injury_last_written_freq = nil
        apply_injury_mod()
        infoText = "AUTO-APPLIED: " .. selected_profile
    elseif vkey == 0x68 then
        edit_idx = edit_idx > 1 and edit_idx - 1 or #param_list
        infoText = "EDITING..."
    elseif vkey == 0x65 or vkey == 0x62 then
        edit_idx = edit_idx < #param_list and edit_idx + 1 or 1
        infoText = "EDITING..."
    elseif vkey == 0x64 then -- DECREASE
        local item = param_list[edit_idx]
        local newval = (p[item.key] or 0) - item.step
        if item.min then newval = math.max(item.min, newval) end
        if item.max then newval = math.min(item.max, newval) end
        p[item.key] = newval
        if item.key == "e30" then apply_tempo(p[item.key]) end
        if item.key == "injury_freq" or item.key == "injury_weight" then apply_injury_mod() end
        infoText = "ADJUSTED: " .. item.name .. " (UNSAVED)"
    elseif vkey == 0x66 then -- INCREASE
        local item = param_list[edit_idx]
        local newval = (p[item.key] or 0) + item.step
        if item.min then newval = math.max(item.min, newval) end
        if item.max then newval = math.min(item.max, newval) end
        p[item.key] = newval
        if item.key == "e30" then apply_tempo(p[item.key]) end
        if item.key == "injury_freq" or item.key == "injury_weight" then apply_injury_mod() end
        infoText = "ADJUSTED: " .. item.name .. " (UNSAVED)"
    elseif vkey == 0x0D or vkey == 0x6B then
        -- ENTER / NUM +
        saved_profile = selected_profile
        local prof_saved = save_all_profiles()
        local conf_saved = save_config(saved_profile)
        apply_active_aob()
        if p and p.e30 then apply_tempo(p.e30) end
        injury_last_written_freq = nil
        apply_injury_mod()
        if prof_saved and conf_saved then infoText = "SETTINGS SAVED & APPLIED!" end
    elseif vkey == 0x60 then
        profiles, profile_names, adv_profile_names = load_profiles()
        saved_profile = load_config()
        selected_profile = saved_profile
        current_idx = 1
        for i, name in ipairs(profile_names) do
            if name == saved_profile then current_idx = i break end
        end
        apply_active_aob()
        if profiles[saved_profile] and profiles[saved_profile].e30 then
            apply_tempo(profiles[saved_profile].e30)
        end
        injury_last_written_freq = nil
        apply_injury_mod()
        infoText = "DATABASE RELOADED"
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================
function m.init(ctx)
    math.randomseed(os.time())

    profiles_file = path_combine(ctx.sider_dir, "EC26_Hybrid_Profiles.ini")
    config_file   = path_combine(ctx.sider_dir, "EC26_Hybrid_Settings.ini")

    -- TEMPO MEMORY HOOKS
    local pattern1 = "\xf2\x0f\x5e\xce\x48\x8b\x01\xff\x50\x30"
    local loc1 = memory.search_process(pattern1)
    if loc1 then
        local signed_offset = memory.unpack("i32", memory.read(loc1 - 4, 4))
        object_addr = loc1 + signed_offset
    end

    local pattern2 = "\x41\x0f\x28\xc9\xf2\x0f\x5e\xc8\xf2\x0f\x11\x4e\x38"
    local loc2 = memory.search_process(pattern2)
    if loc2 then
        memory.write(loc2 + 8, "\x90\x90\x90\x90\x90")
    end

    resolve_physics_addresses()

    profiles, profile_names, adv_profile_names = load_profiles()
    saved_profile = load_config()
    selected_profile = saved_profile
    
    if #profile_names > 0 then
        for i, name in ipairs(profile_names) do
            if name == saved_profile then current_idx = i break end
        end
        if current_idx == 1 and profile_names[1] ~= saved_profile then
            saved_profile = profile_names[1]
            selected_profile = saved_profile
        end
    end

    -- INJURY MOD INIT (idempotent)
    if not injury_initialized then
        injury_initialized = true

        injury_frequency_addr = memory.search_process(INJURY_FREQUENCY_AOB)
        if injury_frequency_addr then
            injury_frequency_num = ptr_to_num(injury_frequency_addr)
        else
            log("EC26_Hybrid: Injury frequency code NOT FOUND")
        end

        injury_severity_addr = memory.search_process(INJURY_SEVERITY_AOB)
        if not injury_severity_addr then
            log("EC26_Hybrid: Injury severity code NOT FOUND")
        end

        if injury_frequency_addr then
            injury_cave_addr = memory.search_process(INJURY_CAVE_AOB)
            if not injury_cave_addr then
                local zero_cave_aob = string.rep('\x00', 32)
                injury_cave_addr = memory.search_process(zero_cave_aob)
            end
            if injury_cave_addr then
                injury_cave_num = ptr_to_num(injury_cave_addr)
            end
        end

        if injury_frequency_addr and injury_cave_addr and injury_frequency_num and injury_cave_num then
            local v = profiles[saved_profile]
            local init_freq = (v and v.injury_freq) or 1
            injury_write_frequency_cave(init_freq)

            local jmp_to_cave = injury_cave_num - (injury_frequency_num + 5)
            local patch = string.char(0xE9) .. injury_int_to_bytes(jmp_to_cave) .. string.char(0x90, 0x90, 0x90)
            memory.write(injury_frequency_addr, patch)
            injury_enabled_frequency = true
            log("EC26_Hybrid: Injury frequency ENABLED")
        end

        if injury_severity_addr then
            injury_enabled_severity = true
            log("EC26_Hybrid: Injury weighted severity ENABLED")
        end
    end

    -- Init Referee AOB System
    if ffi ~= nil then
        local dogso_match = memory.search_process(DOGSO_AOB)
        local thunk_addr = memory.search_process(THUNK_101) or memory.search_process(THUNK_107)
        local all_fns_ok = true

        for name, aob in pairs(FN_AOB) do
            local found = memory.search_process(aob)
            if found then FN_resolved[name] = ptr_to_num(found) else all_fns_ok = false end
        end

        if dogso_match and thunk_addr and all_fns_ok then
            dogso_match_ptr = dogso_match
            dogso_match_num = ptr_to_num(dogso_match)
            local lea_addr = dogso_match + 11
            if memory.read(lea_addr, 3) == "\x48\x8B\x05" then
                gMC_addr_num = ptr_to_num(lea_addr) + 7 + memory.unpack("i32", memory.read(lea_addr + 3, 4))
                thunk_addr_num = ptr_to_num(thunk_addr)
                
                cave_ptr = alloc_near(thunk_addr, 256)
                if cave_ptr then
                    local disp = ptr_to_num(cave_ptr) - thunk_addr_num - 5
                    memory.write(thunk_addr, "\xE9" .. memory.pack("i32", disp))
                    aob_active = true
                end
            end
        end
    end
    
    ctx.register("set_teams", m.set_teams)
    ctx.register("overlay_on", m.overlay_on)
    ctx.register("key_down", m.key_down)
    ctx.register("set_match_settings", m.set_match_settings)
end

return m

