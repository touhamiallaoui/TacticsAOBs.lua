--=============================================================================
-- TacticsAOBs.lua v2.1 (FIXED FOR CONTINUOUS EXECUTION)
--=============================================================================

local m = {}
local version = "2.1 Fixed"

-- ===================== ROSTER =====================
-- Only include YOUR clubs here so your own tactics aren't overwritten. 
-- All opponents will now be affected by the script.
local my_clubs = {
    [100] = "Man Utd", [101] = "Arsenal", [102] = "Chelsea", [103] = "Liverpool",
    [173] = "Man City", [179] = "Tottenham", [112] = "Monaco", [113] = "Marseille",
    [114] = "PSG", [181] = "Lyon", [119] = "Inter", [120] = "Juventus",
    [121] = "AC Milan", [125] = "Roma", [327] = "Napoli", [116] = "Ajax",
    [118] = "PSV", [191] = "Benfica", [192] = "Porto", [193] = "Sporting",
    [108] = "Barcelona", [109] = "Real Madrid", [172] = "Atletico Madrid",
    [265] = "Sevilla", [127] = "Bayern Munich", [128] = "Bayer Leverkusen",
    [2353] = "BVB", [213] = "Lille", [122] = "Lazio", [117] = "Feyenoord", 
    [110] = "Valencia", [196] = "Real Sociedad", [267] = "Villareal",
}

-- Normalized defaults (1-10 scale)
local gen_dl = 5
local gen_c = 5
local gen_sr = 5

-- ===================== STRUCT OFFSETS =====================
local OFF_SR = 0x8C
local OFF_DL = 0x8E
local OFF_C  = 0x8F
local HOOK_AOB = "\x41\x88\x8B\x8E\x00\x00\x00"

-- ===================== FFI / MEMORY SETUP =====================
if ffi ~= nil then
    ffi.cdef[[
    typedef void* LPVOID;
    typedef uint64_t SIZE_T;
    typedef uint32_t DWORD;
    typedef uint8_t BYTE;
    BYTE* VirtualAlloc(LPVOID lpAddress, SIZE_T dwSize, DWORD flAllocationType, DWORD flProtect);
    ]]
end

local function ptr_to_num(p)
    return tonumber(ffi.cast("uint64_t", p))
end

local function le32(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF)
    )
end

local function bytes_to_u64(raw)
    local n = 0ULL
    for i = 8, 1, -1 do
        n = n * 256 + string.byte(raw, i)
    end
    return tonumber(n)
end

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

-- ===================== STATE =====================
local hook_addr_num = nil
local cave_addr_num = nil
local hook_active = false
local slot1_addr_num = nil 
local slot2_addr_num = nil
local home_id = 0
local away_id = 0
local is_home_generic = false
local is_away_generic = false
local last_tick = 0

-- ===================== CODECAVE ASSEMBLY =====================
local CAVE_CODE_LEN = 63
local CAVE_SLOT1_OFF = 63
local CAVE_SLOT2_OFF = 71
local CAVE_TOTAL_LEN = 79
local CAVE_ALLOC_SIZE = 128

local function build_cave_code()
    return table.concat({
        "\x41\x88\x8B\x8E\x00\x00\x00", 
        "\x50",                             
        "\x53",                             
        "\x9C",                             
        "\x48\x8B\x05" .. le32(46), 
        "\x48\x85\xC0",                     
        "\x75\x09",                         
        "\x4C\x89\x1D" .. le32(34), 
        "\xEB\x18",                         
        "\x49\x3B\xC3",                     
        "\x74\x13",                         
        "\x48\x8B\x1D" .. le32(28), 
        "\x48\x85\xDB",                     
        "\x75\x07",                         
        "\x4C\x89\x1D" .. le32(16), 
        "\x9D",                             
        "\x5B",                             
        "\x58",                             
        "\xE9\x00\x00\x00\x00",
        string.rep("\x00", 16),             
    })
end

-- ===================== EVENT HANDLERS =====================
function m.set_teams(ctx, home_team, away_team)
    home_id = home_team
    away_id = away_team
    is_home_generic = not my_clubs[home_team]
    is_away_generic = not my_clubs[away_team]

    if not hook_active then
        m.try_install()
    end

    if slot1_addr_num then memory.write(slot1_addr_num, string.rep("\x00", 8)) end
    if slot2_addr_num then memory.write(slot2_addr_num, string.rep("\x00", 8)) end
end

function m.key_down(ctx, vkey)
    if vkey == 0x55 then if gen_dl < 10 then gen_dl = gen_dl + 1 end     -- U
    elseif vkey == 0x49 then if gen_dl > 1 then gen_dl = gen_dl - 1 end  -- I
    elseif vkey == 0x4C then if gen_c < 10 then gen_c = gen_c + 1 end    -- L
    elseif vkey == 0x4D then if gen_c > 1 then gen_c = gen_c - 1 end     -- M
    elseif vkey == 0x42 then if gen_sr < 10 then gen_sr = gen_sr + 1 end -- B
    elseif vkey == 0x4E then if gen_sr > 1 then gen_sr = gen_sr - 1 end  -- N
    end
end

local function read_slot(addr_num)
    local raw = memory.read(addr_num, 8)
    local val = bytes_to_u64(raw)
    if val == 0 then return nil end
    return val
end

-- CONTINUOUS MATCH LOOP (Applies tactics every 1 second)
function m.live_tactics(ctx)
    local now = os.clock()
    if now - last_tick < 1.0 then return end
    last_tick = now

    local team_a_ptr = slot1_addr_num and read_slot(slot1_addr_num) or nil
    local team_b_ptr = slot2_addr_num and read_slot(slot2_addr_num) or nil

    if team_a_ptr and is_home_generic then
        memory.write(team_a_ptr + OFF_DL, string.char(gen_dl))
        memory.write(team_a_ptr + OFF_C,  string.char(gen_c))
        memory.write(team_a_ptr + OFF_SR, string.char(gen_sr))
    end
    if team_b_ptr and is_away_generic then
        memory.write(team_b_ptr + OFF_DL, string.char(gen_dl))
        memory.write(team_b_ptr + OFF_C,  string.char(gen_c))
        memory.write(team_b_ptr + OFF_SR, string.char(gen_sr))
    end
end

function m.overlay_on(ctx)
    local team_a_ptr = slot1_addr_num and read_slot(slot1_addr_num) or nil
    local team_b_ptr = slot2_addr_num and read_slot(slot2_addr_num) or nil

    return string.format(
        "TacticsAOBs v2.1: Dynamic CPU Hijack\n" ..
        "----------------------------------------\n" ..
        "Hook: %s\n" ..
        "Home Team ID: %d (%s) ptr=%s\n" ..
        "Away Team ID: %d (%s) ptr=%s\n\n" ..
        "Opponent Tactical Overrides (Live):\n" ..
        "Defensive Line (DL): %d  [U/I]\n" ..
        "Compactness (C):     %d  [L/M]\n" ..
        "Support Range (SR):  %d  [B/N]\n",
        hook_active and "ACTIVE" or "INACTIVE (AOB not found)",
        home_id, is_home_generic and "Targeted" or "Protected", team_a_ptr and string.format("0x%X", team_a_ptr) or "nil",
        away_id, is_away_generic and "Targeted" or "Protected", team_b_ptr and string.format("0x%X", team_b_ptr) or "nil",
        gen_dl, gen_c, gen_sr
    )
end

-- ===================== INIT =====================
function m.try_install()
    if hook_active then return end
    if not ffi then return end

    local hook_addr = memory.search_process(HOOK_AOB)
    if not hook_addr then return end
    hook_addr_num = ptr_to_num(hook_addr)

    local cave = alloc_near(hook_addr, CAVE_ALLOC_SIZE)
    if not cave then return end
    
    cave_addr_num = ptr_to_num(cave)
    slot1_addr_num = cave_addr_num + CAVE_SLOT1_OFF
    slot2_addr_num = cave_addr_num + CAVE_SLOT2_OFF

    local code = build_cave_code()
    local back_jmp_from = cave_addr_num + 63 
    local back_jmp_disp = (hook_addr_num + 7) - back_jmp_from
    code = code:sub(1, 58) .. "\xE9" .. le32(back_jmp_disp) .. code:sub(64)
    memory.write(cave_addr_num, code)

    local hook_jmp_disp = cave_addr_num - (hook_addr_num + 5)
    local hook_patch = "\xE9" .. le32(hook_jmp_disp) .. "\x90\x90"
    memory.write(hook_addr_num, hook_patch)

    hook_active = true
end

function m.init(ctx)
    ctx.register("set_teams", m.set_teams)
    ctx.register("key_down", m.key_down)
    ctx.register("overlay_on", m.overlay_on)
    ctx.register("livecpk_make_key", m.live_tactics) 

    m.try_install()
end

return m