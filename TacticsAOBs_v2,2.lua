--=============================================================================
-- TacticsAOBs.lua v2.2 (PATCHED: skip allocate_codecave, use near VirtualAlloc)
--=============================================================================

local m = {}
local version = "2.2 Fixed-Patched"

-- ===================== ROSTER =====================
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

-- ===================== CODECAVE LAYOUT =====================
local LAYOUT = {
    SLOT1       = 0,   -- 8 bytes
    SLOT2       = 8,   -- 8 bytes
    CODE_START  = 16,  -- executable code begins here
}

local CAVE_SIZE = 128

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

-- Assemble the cave code. All RIP-relative displacements are computed
-- live from the actual cave base so the layout is bulletproof.
local function build_cave_code(hook_return_addr, cave_base)
    local code_base = cave_base + LAYOUT.CODE_START
    local c = {}
    local pos = 0

    local function emit(bytes)
        table.insert(c, bytes)
        pos = pos + #bytes
    end

    -- 1) Execute the original instruction being hooked (7 bytes)
    emit("\x41\x88\x8B\x8E\x00\x00\x00")  -- mov [r11+8Eh], ecx

    -- 2) Preserve scratch regs + flags
    emit("\x50")                             -- push rax
    emit("\x53")                             -- push rbx
    emit("\x9C")                             -- pushfq

    -- 3) Load slot1 into RAX
    local disp1 = (cave_base + LAYOUT.SLOT1) - (code_base + pos + 7)
    emit("\x48\x8B\x05" .. le32(disp1))    -- mov rax, [rip+disp1]

    emit("\x48\x85\xC0")                     -- test rax, rax
    emit("\x75\x09")                         -- jne +9  -> check_match

    -- 4) Slot1 is empty → store current r11
    local disp2 = (cave_base + LAYOUT.SLOT1) - (code_base + pos + 7)
    emit("\x4C\x89\x1D" .. le32(disp2))    -- mov [rip+disp2], r11
    emit("\xEB\x18")                         -- jmp +24 -> epilogue

    -- 5) check_match: is this the same pointer we already captured?
    emit("\x49\x3B\xC3")                     -- cmp rax, r11
    emit("\x74\x13")                         -- je +19  -> epilogue

    -- 6) Different pointer → try slot2
    local disp3 = (cave_base + LAYOUT.SLOT2) - (code_base + pos + 7)
    emit("\x48\x8B\x1D" .. le32(disp3))    -- mov rbx, [rip+disp3]

    emit("\x48\x85\xDB")                     -- test rbx, rbx
    emit("\x75\x07")                         -- jne +7  -> epilogue

    -- 7) Slot2 is empty → store current r11
    local disp4 = (cave_base + LAYOUT.SLOT2) - (code_base + pos + 7)
    emit("\x4C\x89\x1D" .. le32(disp4))    -- mov [rip+disp4], r11

    -- 8) Epilogue: restore regs/flags
    emit("\x9D")                             -- popfq
    emit("\x5B")                             -- pop rbx
    emit("\x58")                             -- pop rax

    -- 9) Jump back to the instruction after the hooked one
    local back_disp = hook_return_addr - (code_base + pos + 5)
    emit("\xE9" .. le32(back_disp))         -- jmp hook_addr+7

    return table.concat(c)
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
    if not raw then return nil end
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
        "TacticsAOBs v%s: Dynamic CPU Hijack\n" ..
        "----------------------------------------\n" ..
        "Hook: %s\n" ..
        "Home Team ID: %d (%s) ptr=%s\n" ..
        "Away Team ID: %d (%s) ptr=%s\n\n" ..
        "Opponent Tactical Overrides (Live):\n" ..
        "Defensive Line (DL): %d  [U/I]\n" ..
        "Compactness (C):     %d  [L/M]\n" ..
        "Support Range (SR):  %d  [B/N]\n",
        version,
        hook_active and "ACTIVE" or "INACTIVE (AOB not found)",
        home_id, is_home_generic and "Targeted" or "Protected", team_a_ptr and string.format("0x%X", team_a_ptr) or "nil",
        away_id, is_away_generic and "Targeted" or "Protected", team_b_ptr and string.format("0x%X", team_b_ptr) or "nil",
        gen_dl, gen_c, gen_sr
    )
end

-- ===================== INIT =====================
function m.try_install()
    if hook_active then return end
    if not ffi then
        log("TacticsAOBs: FFI unavailable, cannot allocate cave")
        return
    end

    local hook_addr = memory.search_process(HOOK_AOB)
    if not hook_addr then
        log("TacticsAOBs: AOB not found, hook inactive")
        return
    end
    hook_addr_num = tonumber(ffi.cast("uint64_t", hook_addr))

    -- Use VirtualAlloc near-search (same as v2.1) instead of allocate_codecave
    local function alloc_near(target, size)
        local GRAN = 0x10000
        local target_num = tonumber(ffi.cast("uint64_t", target))
        local base = target_num - (target_num % GRAN)
        for i = 1, 8192 do
            local lo = base - i * GRAN
            if lo > 0 then
                local p = ffi.C.VirtualAlloc(ffi.cast("void*", ffi.cast("uint64_t", lo)), size, 0x3000, 0x40)
                if p ~= nil and tonumber(ffi.cast("uint64_t", p)) ~= 0 then return p end
            end
            local hi = base + i * GRAN
            local p = ffi.C.VirtualAlloc(ffi.cast("void*", ffi.cast("uint64_t", hi)), size, 0x3000, 0x40)
            if p ~= nil and tonumber(ffi.cast("uint64_t", p)) ~= 0 then return p end
        end
        return nil
    end

    local cave = alloc_near(hook_addr, CAVE_SIZE)
    if not cave then
        log("TacticsAOBs: VirtualAlloc near-allocator failed")
        return
    end

    cave_addr_num = tonumber(ffi.cast("uint64_t", cave))
    slot1_addr_num = cave_addr_num + LAYOUT.SLOT1
    slot2_addr_num = cave_addr_num + LAYOUT.SLOT2

    -- Zero the entire cave so slots start empty
    memory.write(cave_addr_num, string.rep("\x00", CAVE_SIZE))

    local hook_return = hook_addr_num + 7
    local code = build_cave_code(hook_return, cave_addr_num)
    memory.write(cave_addr_num + LAYOUT.CODE_START, code)

    -- 5-byte relative JMP + 2 NOPs to fill the original 7-byte instruction
    local hook_disp = (cave_addr_num + LAYOUT.CODE_START) - (hook_addr_num + 5)
    memory.write(hook_addr_num, "\xE9" .. le32(hook_disp) .. "\x90\x90")

    hook_active = true
    log(string.format("TacticsAOBs: hook installed at 0x%X, cave at 0x%X", hook_addr_num, cave_addr_num))
end

function m.init(ctx)
    ctx.register("set_teams", m.set_teams)
    ctx.register("key_down", m.key_down)
    ctx.register("overlay_on", m.overlay_on)
    ctx.register("livecpk_make_key", m.live_tactics) 

    m.try_install()
end

return m