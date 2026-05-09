-- EdgeField v4.0
-- Shortwave number station
-- CT-37c codec + per-digit FX + distance meta-control
-- Grid: digit pair display, param sliders, LFO control surface

engine.name = 'EdgeField'

-- defined early so norns can always call it even if init crashes
function cleanup()
  if tx_clock then
    clock.cancel(tx_clock)
    tx_clock = nil
  end
  if _grid then
    pcall(function()
      _grid:all(0)
      _grid:refresh()
    end)
  end
end

-- =========================================================
-- STATE
-- =========================================================

local text_input         = ""
local transmission_queue = {}

local is_transmitting    = false
local tx_clock           = nil
local tx_state           = "IDLE"

local cursor_timer       = 0
local spin_idx           = 1
local spinners           = {"|", "/", "-", "\\"}

local current_step       = 1

local terminal_lines     = {""}
local live_buffer        = ""

local voice_sets         = {}
local _grid              = nil
local _grid_last_refresh = 0  -- throttle grid:refresh() calls

-- last FX applied (internal tracking)
local last_fx            = 0

-- forward declarations — defined later in file
local grid_redraw
local process_digit

-- grid LFO depth slider positions (cols 1-16, 0-based)
local carrier_depth_col  = 8
local static_depth_col   = 4

-- grid LFO speed slider positions (cols 1-9, 0-based)
local carrier_speed_col  = 4
local static_speed_col   = 4

-- LFO phases (driven by animation metro)
local carrier_phase      = 0.0
local static_phase       = 0.0

-- LFO speed range (phase increment per 0.1s tick)
local LFO_SPEED_MIN      = 0.005
local LFO_SPEED_MAX      = 0.084

-- current LFO rates (set by speed slider)
local carrier_lfo_rate   = 0.03
local static_lfo_rate    = 0.07

-- max modulation depths
local CARRIER_FREQ_DEPTH = 400.0  -- Hz swing at full depth
local STATIC_DEPTH       = 0.50   -- fraction of static_level at full depth

-- =========================================================
-- 5x3 FONT
-- Each char is a table of 5 rows, each row is a 3-bit mask
-- bit 4 = left col, bit 2 = mid col, bit 1 = right col
-- =========================================================

local font5x3 = {
  [" "] = {0,0,0,0,0},
  ["A"] = {6,5,7,5,5},
  ["B"] = {6,5,6,5,6},
  ["C"] = {7,4,4,4,7},
  ["D"] = {6,5,5,5,6},
  ["E"] = {7,4,6,4,7},
  ["F"] = {7,4,6,4,4},
  ["G"] = {7,4,5,5,7},
  ["H"] = {5,5,7,5,5},
  ["I"] = {7,2,2,2,7},
  ["J"] = {7,1,1,5,6},
  ["K"] = {5,5,6,5,5},
  ["L"] = {4,4,4,4,7},
  ["M"] = {5,7,5,5,5},
  ["N"] = {5,7,7,5,5},
  ["O"] = {7,5,5,5,7},
  ["P"] = {6,5,6,4,4},
  ["Q"] = {6,5,5,6,1},
  ["R"] = {6,5,6,5,5},
  ["S"] = {7,4,6,1,7},
  ["T"] = {7,2,2,2,2},
  ["U"] = {5,5,5,5,7},
  ["V"] = {5,5,5,5,2},
  ["W"] = {5,5,5,7,5},
  ["X"] = {5,5,2,5,5},
  ["Y"] = {5,5,2,2,2},
  ["Z"] = {7,1,2,4,7},
  ["0"] = {7,5,5,5,7},
  ["1"] = {2,6,2,2,7},
  ["2"] = {6,1,2,4,7},
  ["3"] = {6,1,2,1,6},
  ["4"] = {5,5,7,1,1},
  ["5"] = {7,4,6,1,6},
  ["6"] = {3,4,6,5,6},
  ["7"] = {7,1,2,4,4},
  ["8"] = {6,5,6,5,6},
  ["9"] = {6,5,7,1,6},
}

-- =========================================================
-- GRID CHARACTER RENDERING
-- col_offset is 0-based; char occupies cols offset+1 to offset+3
-- =========================================================

local function grid_draw_char(g, ch, col_offset, bright)
  local glyph = font5x3[ch] or font5x3[" "]
  for row = 1, 5 do
    local bits = glyph[row]
    if (bits & 4) > 0 then g:led(col_offset + 1, row, bright) end
    if (bits & 2) > 0 then g:led(col_offset + 2, row, bright) end
    if (bits & 1) > 0 then g:led(col_offset + 3, row, bright) end
  end
end

-- =========================================================
-- GRID STATE
-- 4 resolved chars + 1 live slot
-- =========================================================

local grid_chars = {" ", " ", " ", " "}
local grid_live  = ""

local function grid_push_char(c)
  table.remove(grid_chars, 1)
  table.insert(grid_chars, c)
end

-- =========================================================
-- CT-37c MAP
-- =========================================================

local ct37c_map = {
  ["1"]="I", ["2"]="A", ["3"]="T",
  ["4"]="O", ["5"]="N", ["6"]="E",

  ["70"]="B", ["71"]="C", ["72"]="D",
  ["73"]="F", ["74"]="G", ["75"]="H",
  ["76"]="J", ["77"]="K", ["78"]="L",
  ["79"]="M",

  ["80"]="P", ["81"]="Q", ["82"]="R",
  ["83"]="S", ["84"]="U", ["85"]="V",
  ["86"]="W", ["87"]="X", ["88"]="Y",
  ["89"]="Z",

  ["99"]=" "
}

local encode_map = {}
for k,v in pairs(ct37c_map) do
  encode_map[v] = k
end

-- =========================================================
-- FX SELECTION
-- =========================================================

local function pick_fx()

  local prob = params:get("fx_probability") / 100.0

  if math.random() > prob then
    return 0, 0.0
  end

  local mode = math.random(1, 4)

  local param = ({
    [1] = math.random() * 0.12 + 0.06,
    [2] = math.random() * 0.6  + 0.2,
    [3] = math.random() * 0.7  + 0.2,
    [4] = math.random() * 3.5  + 0.5,
  })[mode]

  return mode, param
end

-- =========================================================
-- VOICE SCAN
-- =========================================================

function scan_voice_sets()

  voice_sets = {}

  local base = _path.audio .. "edgefield/voices/"
  local p    = io.popen('find "' .. base .. '" -maxdepth 1 -type d')

  if p then
    for dir in p:lines() do
      if dir ~= base and dir ~= (base:gsub("/$","")) then
        local name = dir:match("([^/]+)$")
        if name then table.insert(voice_sets, name) end
      end
    end
    p:close()
  end

  table.sort(voice_sets)
end

-- =========================================================
-- INIT
-- =========================================================

function init()

  util.make_dir(_path.data .. "edgefield/messages/")

  scan_voice_sets()

  -- -------------------------------------------------------
  -- PARAMS
  -- -------------------------------------------------------

  params:add_separator("STATION")

  params:add_text("op_id", "Operator ID", "302")

  local default_voice = 1
  for i,v in ipairs(voice_sets) do
    if v == "H" then default_voice = i; break end
  end

  if #voice_sets == 0 then
    voice_sets = {"none"}
  end

  params:add_option("voice_set", "Voice Set", voice_sets, default_voice)

  params:add_file("message_file", "Message File")

  params:add_number("digits_per_group", "Digits/Group", 3, 5, 5)

  params:add_control(
    "digit_delay", "Digit Delay",
    controlspec.new(0.2, 2.0, 'lin', 0, 0.8)
  )

  params:add_control(
    "group_delay", "Group Delay",
    controlspec.new(0.5, 5.0, 'lin', 0, 1.5)
  )

  params:add_separator("SIGNAL")

  params:add_control(
    "bandwidth", "Bandwidth",
    controlspec.new(400, 6000, 'exp', 0, 2400)
  )

  params:add_control(
    "carrier_freq", "Carrier Freq",
    controlspec.new(1000, 9000, 'exp', 0, 4800)
  )

  params:add_control(
    "static_level", "Static Level",
    controlspec.new(0.0, 1.0, 'lin', 0, 0.3)
  )

  params:add_separator("VOICE FX")

  params:add_control(
    "voice_drift", "Drift",
    controlspec.new(0.0, 0.5, 'lin', 0, 0.05)
  )

  params:add_control(
    "master_crush", "Crush",
    controlspec.new(0.0, 0.08, 'lin', 0, 0.0)
  )

  params:add_number(
    "fx_probability", "FX Probability",
    0, 100, 40
  )

  params:add_separator("DISTANCE")

  params:add_control(
    "distance", "Distance",
    controlspec.new(0.0, 1.0, 'lin', 0, 0.3)
  )

  -- -------------------------------------------------------
  -- DEFAULT FILE
  -- -------------------------------------------------------

  local default_file = _path.data .. "edgefield/messages/coos.txt"
  if util.file_exists(default_file) then
    params:set("message_file", default_file)
  end

  -- wire param changes to engine
  params:set_action("bandwidth",    function(x) engine.master_bandwidth(x) end)
  params:set_action("carrier_freq", function(x) engine.carrier_freq(x) end)
  params:set_action("static_level", function(x) engine.noise_vol(x) end)
  params:set_action("master_crush", function(x) engine.master_crush(x) end)
  params:set_action("distance",     function(x) engine.distance(x) end)

  -- push all param values to engine on boot
  params:bang()

  -- -------------------------------------------------------
  -- GRID
  -- -------------------------------------------------------

  _grid = grid.connect()
  _grid.key = grid_key

  -- -------------------------------------------------------
  -- TIMERS
  -- -------------------------------------------------------

  metro.init(function() redraw() end, 1/15):start()

  metro.init(function()

    cursor_timer  = (cursor_timer + 1) % 10
    spin_idx      = (spin_idx % 4) + 1

    -- advance LFO phases using current speed settings
    carrier_phase = (carrier_phase + carrier_lfo_rate) % 1.0
    static_phase  = (static_phase  + static_lfo_rate)  % 1.0

    -- carrier freq LFO: oscillate around base param
    local carrier_depth = (carrier_depth_col / 15.0) * CARRIER_FREQ_DEPTH
    local carrier_sine  = math.sin(carrier_phase * math.pi * 2)
    local carrier_val   = params:get("carrier_freq") + (carrier_sine * carrier_depth)
    engine.carrier_freq(math.max(100, carrier_val))

    -- static level LFO: oscillate around base param
    local static_depth = (static_depth_col / 15.0) * STATIC_DEPTH
    local static_sine  = math.sin(static_phase * math.pi * 2)
                       + math.sin(static_phase * math.pi * 5.7) * 0.3
    static_sine        = static_sine / 1.3
    local static_base  = params:get("static_level")
    local static_val   = static_base + (static_sine * static_depth * static_base)
    engine.noise_vol(math.max(0, static_val))

    grid_redraw()

  end, 1/25):start()

  -- -------------------------------------------------------
  -- KEYBOARD
  -- -------------------------------------------------------

  keyboard.char = function(c)
    if not is_transmitting then
      text_input = text_input .. string.upper(c)
    end
  end

  keyboard.code = function(code, value)
    if value ~= 1 and value ~= 2 then return end
    if code == "ENTER" then
      trigger_transmit()
    elseif code == "BACKSPACE" then
      text_input = text_input:sub(1,-2)
    end
  end

end

-- =========================================================
-- FILE LOAD
-- =========================================================

function load_message_file()

  local path = params:string("message_file")

  if path == nil or path == "" then return false end

  if not string.match(path, "^/") then
    path = _path.data .. "edgefield/messages/" .. path
  end

  local file, err = io.open(path, "r")
  if not file then
    print("[EdgeField] open error:", err)
    return false
  end

  local data = file:read("*a")
  file:close()

  if not data then return false end

  text_input = data:gsub("%s+", " "):upper()
  return #text_input > 0
end

-- =========================================================
-- TRANSMIT ENTRY
-- =========================================================

function trigger_transmit()

  if is_transmitting then return end

  if text_input ~= "" then
    prepare_transmission()
    return
  end

  if not load_message_file() then
    print("[EdgeField] nothing to transmit")
    return
  end

  prepare_transmission()
end

-- =========================================================
-- BUILD TRANSMISSION
-- =========================================================

function prepare_transmission()

  clock.run(function()

  tx_state = "ENCODING"
  redraw()

  transmission_queue = {}

  local encoded = ""

  for c in text_input:gmatch(".") do
    local code = encode_map[c]
    if code then encoded = encoded .. code end
  end

  local gsize = params:get("digits_per_group")

  while (#encoded % gsize ~= 0) do
    encoded = encoded .. "9"
  end

  local id = params:string("op_id")

  for i = 1, 3 do
    table.insert(transmission_queue, { type="id", val=id })
  end

  for i = 1, #encoded, gsize do
    table.insert(transmission_queue, {
      type = "group",
      val  = encoded:sub(i, i+gsize-1)
    })
  end

  text_input = ""
  start_broadcast()

  end)  -- end clock.run
end

-- =========================================================
-- DECODE DISPLAY
-- Updates both terminal_lines (OLED) and grid state
-- =========================================================

process_digit = function(d)

  live_buffer = live_buffer .. d
  grid_live   = live_buffer

  terminal_lines[#terminal_lines] =
    terminal_lines[#terminal_lines] .. d
  redraw()

  clock.sleep(0.08)

  -- single-digit codes: 1-6
  if #live_buffer == 1 then

    local n = tonumber(live_buffer)

    if n and n >= 1 and n <= 6 then

      local decoded = ct37c_map[live_buffer]

      terminal_lines[#terminal_lines] =
        terminal_lines[#terminal_lines]:sub(1,-2)
      redraw()
      clock.sleep(0.04)

      terminal_lines[#terminal_lines] =
        terminal_lines[#terminal_lines] .. decoded

      grid_push_char(decoded)
      clock.run(function()
        clock.sleep(0.4)
        grid_live = ""
      end)
      live_buffer = ""
    end

  -- two-digit codes: 70-89, 99
  elseif #live_buffer == 2 then

    local decoded = ct37c_map[live_buffer]

    if decoded then
      terminal_lines[#terminal_lines] =
        terminal_lines[#terminal_lines]:sub(1,-3)
      redraw()
      clock.sleep(0.05)
      terminal_lines[#terminal_lines] =
        terminal_lines[#terminal_lines] .. decoded

      grid_push_char(decoded)
    end

    clock.run(function()
      clock.sleep(0.4)
      grid_live = ""
    end)
    live_buffer = ""
  end

  -- OLED line wrap
  if live_buffer == "" then
    if #terminal_lines[#terminal_lines] >= 24 then
      table.insert(terminal_lines, "")
      if #terminal_lines > 3 then
        table.remove(terminal_lines, 1)
      end
    end
  end
end

-- =========================================================
-- TRANSMISSION LOOP
-- =========================================================

function start_broadcast()

  is_transmitting = true
  tx_state        = "TRANSMITTING"
  current_step    = 1
  terminal_lines  = {""}
  live_buffer     = ""
  grid_chars      = {" ", " ", " ", " "}
  grid_live       = ""
  last_fx         = 0

  if tx_clock then clock.cancel(tx_clock) end

  tx_clock = clock.run(function()

    while current_step <= #transmission_queue do

      local item      = transmission_queue[current_step]
      local voice_set = params:string("voice_set")
      local drift     = params:get("voice_drift")

      for i = 1, #item.val do

        local d    = item.val:sub(i,i)
        local path = _path.audio ..
          "edgefield/voices/" .. voice_set .. "/" .. d .. ".wav"

        local fx_mode, fx_param = pick_fx()
        last_fx = fx_mode

        if not util.file_exists(path) then
          print("[EdgeField] missing:", path)
        else
          engine.play_voice(path, drift, fx_mode * 1.0, fx_param)
        end

        if item.type ~= "id" then
          process_digit(d)
        end

        clock.sleep(params:get("digit_delay"))
      end

      current_step = current_step + 1
      clock.sleep(params:get("group_delay"))
    end

    -- -------------------------------------------------------
    -- FORMAL OUTRO: operator ID x3 then silence
    -- -------------------------------------------------------

    tx_state = "OUTRO"
    redraw()

    local voice_set = params:string("voice_set")
    local id        = params:string("op_id")

    clock.sleep(params:get("group_delay"))

    for rep = 1, 3 do
      for i = 1, #id do
        local d    = id:sub(i,i)
        local path = _path.audio ..
          "edgefield/voices/" .. voice_set .. "/" .. d .. ".wav"
        if util.file_exists(path) then
          engine.play_voice(path, 0.0, 0.0, 0.0)
        end
        clock.sleep(params:get("digit_delay"))
      end
      clock.sleep(params:get("group_delay"))
    end

    -- clear trail echo on clean end
    engine.trail_clear(0.0)

    is_transmitting = false
    tx_state        = "IDLE"
    grid_live       = ""
    last_fx         = 0

  end)
end

-- =========================================================
-- GRID KEY HANDLER
-- Row 1, cols 1-9: drift slider
-- Row 2, cols 1-9: crush slider
-- Row 3, cols 1-9: fx probability slider
-- Row 4, cols 1-9: carrier LFO speed
-- Row 5, cols 1-9: static LFO speed
-- Row 6: carrier depth
-- Row 7: static depth
-- Row 8: distance
-- =========================================================

function grid_key(x, y, z)

  if z ~= 1 then return end

  local t = (x - 1) / 8.0  -- 0.0-1.0 across cols 1-9

  if y == 1 and x <= 9 then
    -- drift: 0.0-0.5
    params:set("voice_drift", t * 0.5)

  elseif y == 2 and x <= 9 then
    -- crush: 0.0-0.08
    params:set("master_crush", t * 0.08)

  elseif y == 3 and x <= 9 then
    -- fx probability: 0-100
    params:set("fx_probability", math.floor(t * 100))

  elseif y == 4 and x <= 9 then
    carrier_speed_col = x - 1
    carrier_lfo_rate  = LFO_SPEED_MIN +
      (t * (LFO_SPEED_MAX - LFO_SPEED_MIN))

  elseif y == 5 and x <= 9 then
    static_speed_col = x - 1
    static_lfo_rate  = LFO_SPEED_MIN +
      (t * (LFO_SPEED_MAX - LFO_SPEED_MIN))

  elseif y == 6 then
    carrier_depth_col = x - 1

  elseif y == 7 then
    static_depth_col = x - 1

  elseif y == 8 then
    params:set("distance", (x - 1) / 15.0)
  end
end

-- =========================================================
-- GRID REDRAW
-- =========================================================

grid_redraw = function()

  if not _grid then return end

  -- throttle to ~10fps max to avoid flooding USB
  local now = util.time()
  if (now - _grid_last_refresh) < 0.05 then return end

  local ok, err = pcall(function()

  _grid:all(0)

  -- ---------------------------------------------------
  -- ROW 1 cols 1-9: drift slider
  -- ROW 2 cols 1-9: crush slider
  -- ROW 3 cols 1-9: fx probability slider
  -- Gray (5) left of set point, dark to the right
  -- ---------------------------------------------------

  local drift_col = math.floor(
    (params:get("voice_drift") / 0.5) * 8) + 1
  local crush_col = math.floor(
    (params:get("master_crush") / 0.08) * 8) + 1
  local fx_col    = math.floor(
    (params:get("fx_probability") / 100) * 8) + 1

  for x = 1, 9 do
    if x <= drift_col then _grid:led(x, 1, 5) end
    if x <= crush_col then _grid:led(x, 2, 5) end
    if x <= fx_col    then _grid:led(x, 3, 5) end
  end

  -- ---------------------------------------------------
  -- ROW 4 cols 1-9: carrier LFO speed — bouncing pixel
  -- ROW 5 cols 1-9: static LFO speed  — bouncing pixel
  -- Pixel position driven by LFO sine, brightness 8
  -- ---------------------------------------------------

  local carrier_bounce = math.floor(
    (math.sin(carrier_phase * math.pi * 2) + 1.0) / 2.0 * 8)
  local static_bounce  = math.floor(
    (math.sin(static_phase  * math.pi * 2) + 1.0) / 2.0 * 8)

  _grid:led(carrier_bounce + 1, 4, 8)
  _grid:led(static_bounce  + 1, 5, 8)

  -- ---------------------------------------------------
  -- COLS 10-12 ROWS 1-5: first live digit
  -- COL 13 ROWS 1-5: blank
  -- COLS 14-16 ROWS 1-5: second live digit
  -- ---------------------------------------------------

  if #grid_live >= 1 then
    local glyph = font5x3[grid_live:sub(1,1)] or font5x3[" "]
    for row = 1, 5 do
      local bits = glyph[row]
      if (bits & 4) > 0 then _grid:led(10, row, 4) end
      if (bits & 2) > 0 then _grid:led(11, row, 4) end
      if (bits & 1) > 0 then _grid:led(12, row, 4) end
    end
  end

  if #grid_live >= 2 then
    local glyph = font5x3[grid_live:sub(2,2)] or font5x3[" "]
    for row = 1, 5 do
      local bits = glyph[row]
      if (bits & 4) > 0 then _grid:led(14, row, 4) end
      if (bits & 2) > 0 then _grid:led(15, row, 4) end
      if (bits & 1) > 0 then _grid:led(16, row, 4) end
    end
  end

  -- ---------------------------------------------------
  -- ROW 6: carrier depth — sine trace + bright pixel
  -- ---------------------------------------------------

  for x = 1, 16 do
    local phase  = carrier_phase + (x - 1) / 16.0
    local sine   = math.sin(phase * math.pi * 2)
    local bright = math.floor((sine + 1.0) * 1.5) + 1
    _grid:led(x, 6, bright)
  end
  _grid:led(carrier_depth_col + 1, 6, 15)

  -- ---------------------------------------------------
  -- ROW 7: static depth — irregular trace + bright pixel
  -- ---------------------------------------------------

  for x = 1, 16 do
    local phase  = static_phase * 2.3 + (x - 1) / 16.0
    local sine   = math.sin(phase * math.pi * 2)
               + math.sin(phase * math.pi * 5.7) * 0.3
    local bright = math.floor((sine + 1.3) * 1.0) + 1
    bright = util.clamp(bright, 1, 4)
    _grid:led(x, 7, bright)
  end
  _grid:led(static_depth_col + 1, 7, 15)

  -- ---------------------------------------------------
  -- ROW 8: distance bar
  -- ---------------------------------------------------

  local dist     = params:get("distance")
  local dist_col = math.floor(dist * 15) + 1

  for x = 1, 16 do
    if x <= dist_col then
      local b = math.floor(2 + (x / dist_col) * 5)
      _grid:led(x, 8, util.clamp(b, 2, 7))
    end
  end
  _grid:led(dist_col, 8, 15)

  _grid:refresh()
  _grid_last_refresh = util.time()

  end)  -- end pcall

  if not ok then
    print("[EdgeField] grid_redraw error:", err)
  end
end

-- =========================================================
-- INPUT
-- =========================================================

function key(n, z)
  if z == 0 then return end

  if n == 2 then
    -- K2: kill transmission with echo trail
    if is_transmitting then
      if tx_clock then
        clock.cancel(tx_clock)
        tx_clock = nil
      end
      engine.kill_trail(3.0)  -- 3 second decay trail
      is_transmitting = false
      tx_state        = "IDLE"
      grid_live       = ""
      last_fx         = 0
    end

  elseif n == 3 then
    trigger_transmit()
  end
end

function enc(n, d)
  if n == 2 then
    local v = params:get("distance") + (d * 0.02)
    params:set("distance", util.clamp(v, 0.0, 1.0))
  elseif n == 3 then
    if not is_transmitting then
      local v = params:get("fx_probability") + d
      params:set("fx_probability", util.clamp(v, 0, 100))
    end
  end
end

-- =========================================================
-- OLED REDRAW
-- =========================================================

function redraw()

  screen.clear()

  -- header
  screen.level(3)
  screen.move(0, 7)

  if tx_state == "IDLE" then
    screen.text("EDGEFIELD [" .. params:string("voice_set") .. "]")
  elseif tx_state == "ENCODING" then
    screen.text("ENCODING")
  elseif tx_state == "TRANSMITTING" then
    screen.text("TX [" .. params:string("voice_set") .. "]")
  elseif tx_state == "OUTRO" then
    screen.text("SIGNING OFF")
  end

  if tx_state ~= "IDLE" then
    screen.level(3)
    screen.move(120, 7)
    screen.text(spinners[spin_idx])
  end

  -- distance bar
  local dist = params:get("distance")
  screen.level(2)
  screen.rect(0, 59, math.floor(dist * 128), 5)
  screen.fill()

  screen.level(15)

  if not is_transmitting then

    local cursor = (cursor_timer > 5) and "_" or ""
    screen.move(0, 25)
    screen.text("> " .. text_input .. cursor)

    screen.level(3)
    screen.move(0, 48)
    screen.text(
      "FX:" .. params:get("fx_probability") .. "%  " ..
      "DIST:" .. string.format("%.2f", dist)
    )

  else

    screen.move(0, 20)
    screen.text(terminal_lines[1] or "")

    screen.move(0, 32)
    screen.text(terminal_lines[2] or "")

    screen.move(0, 44)
    screen.text(terminal_lines[3] or "")

  end

  screen.update()
end