------------------------------------------------------------
-- HidManager DCS export bridge
--
-- TCP bridge between DCS and HidManager.
--
-- Install (recommended, coexists with DCS-BIOS / SRS / Tacview):
--   Copy this file to  Saved Games\DCS\Scripts\HidManagerExport.lua
--   Add this line to   Saved Games\DCS\Scripts\Export.lua
--     local lfs = require("lfs"); dofile(lfs.writedir() .. [[Scripts\HidManagerExport.lua]])
--
--   It can also be used directly as Export.lua. Any LuaExport*
--   callbacks defined before it are chained, not replaced.
--
-- Endpoint: 127.0.0.1:31090 (newline terminated text lines)
--
-- C# -> DCS
--   GROUP:CONTROL           default action (press+release, flip, step)
--   GROUP:CONTROL:VALUE     explicit value (see control types below)
--   SYS:SYNC                resend all outputs
--   SYS:PING[:token]        reply DCS:PONG:token
--   SYS:DEBUG:0|1           toggle file logging
--
-- DCS -> C#
--   DCS:NAME:VALUE          output changed
--   DCS:AIRCRAFT:NAME       current aircraft (NONE when not in cockpit)
--   DCS:PONG:token
--
-- Control types
--   button   AMPCD:OSB1        press, auto release after ButtonReleaseDelay
--            AMPCD:OSB1:1      press and hold
--            AMPCD:OSB1:0      release
--   toggle   X:Y               flip
--            X:Y:0 | X:Y:1     set position
--   switch   X:Y:2             set position by 0-based index
--            X:Y:INC | X:Y:DEC step one position
--            X:Y               step forward (wraps if Wrap = true)
--   rotary   X:Y               turn by Step (relative knob)
--            X:Y:-0.1          turn by given delta
--            X:Y:INC | X:Y:DEC turn by +Step / -Step
--   axis     X:Y:0.73          set absolute value (clamped to Min..Max)
------------------------------------------------------------


------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------

local Config = {
    IPAddress = "127.0.0.1",
    Port = 31090,

    ReconnectInterval = 2.0,
    ConnectPendingTimeout = 5.0,

    SocketPollInterval = 0.02,   -- 50 Hz
    OutputPollInterval = 0.05,   -- 20 Hz
    AircraftCheckInterval = 1.0,

    -- Time a momentary button is held before release.
    ButtonReleaseDelay = 0.05,

    MaxCommandsPerPoll = 16,
    MaxMessagesPerFlush = 32,
    MaxReceiveBuffer = 65536,
    MaxPendingSendBytes = 65536,

    -- Only accept commands in this aircraft. nil = any aircraft.
    Aircraft = "FA-18C_hornet",

    -- Accept commands when the aircraft cannot be identified
    -- (e.g. servers that disable own-aircraft export).
    AllowUnknownAircraft = true,

    Debug = false,
    LogFile = "Logs/HidManager_Export.log",
}


------------------------------------------------------------
-- DCS DEVICE IDS (F/A-18C, from devices.lua)
------------------------------------------------------------

local DEVICES = {
    HUD = 34,
    LEFT_DDI = 35,
    RIGHT_DDI = 36,
    AMPCD = 37,
}


------------------------------------------------------------
-- CONTROL DEFINITIONS
--
-- CONTROLS.<GROUP> = { Device = id, Controls = { <NAME> = def } }
--
-- def fields
--   Type          "button" | "toggle" | "switch" | "rotary" | "axis"
--   Command       clickable command id (clickabledata.lua)
--   Value         button: value sent on press      (default 1)
--   ReleaseValue  button: value sent on release    (default 0)
--   Positions     toggle/switch: clickable value for each position
--                 (toggle default {0, 1})
--   Argument      toggle/switch: cockpit argument used to read the
--                 current position (otherwise last sent is tracked)
--   Wrap          switch: wrap around when stepping past the end
--   Step          rotary: default delta (default 0.1)
--   Min, Max      axis: clamp range (default 0..1)
--
-- Command ids marked "verify" must be checked against
-- Mods/aircraft/FA-18C/Cockpit/Scripts/clickabledata.lua.
------------------------------------------------------------

local CONTROLS = {}

local function AddOSBs(controls, firstCommand)
    for i = 1, 20 do
        controls["OSB" .. i] = {
            Type = "button",
            Command = firstCommand + i - 1,
        }
    end
end


-- AMPCD ---------------------------------------------------

CONTROLS.AMPCD = { Device = DEVICES.AMPCD, Controls = {} }

do
    local c = CONTROLS.AMPCD.Controls

    AddOSBs(c, 3011)  -- OSB 1-20: 3011-3030

    c.DAY           = { Type = "button", Command = 3002 }
    c.NIGHT         = { Type = "button", Command = 3003 }
    c.SYM_UP        = { Type = "button", Command = 3004 }
    c.SYM_DOWN      = { Type = "button", Command = 3005 }
    c.CONTRAST_UP   = { Type = "button", Command = 3006 }
    c.CONTRAST_DOWN = { Type = "button", Command = 3007 }
    c.GAIN_UP       = { Type = "button", Command = 3008 }
    c.GAIN_DOWN     = { Type = "button", Command = 3009 }

    -- Brightness knob (relative). AMPCD:BRIGHTNESS:-0.1 also works.
    c.BRIGHTNESS           = { Type = "rotary", Command = 3001, Step = 0.25 }
    c.BRIGHTNESS_UP        = { Type = "rotary", Command = 3001, Step = 0.25 }
    c.BRIGHTNESS_DOWN      = { Type = "rotary", Command = 3001, Step = -0.25 }
    c.BRIGHTNESS_UP_FAST   = { Type = "rotary", Command = 3001, Step = 1 }
    c.BRIGHTNESS_DOWN_FAST = { Type = "rotary", Command = 3001, Step = -1 }
end


-- LEFT / RIGHT DDI ---------------------------------------

CONTROLS.LEFT_DDI = { Device = DEVICES.LEFT_DDI, Controls = {} }
CONTROLS.RIGHT_DDI = { Device = DEVICES.RIGHT_DDI, Controls = {} }

AddOSBs(CONTROLS.LEFT_DDI.Controls, 3011)   -- verify
AddOSBs(CONTROLS.RIGHT_DDI.Controls, 3011)  -- verify


-- HUD -----------------------------------------------------

CONTROLS.HUD = {
    Device = DEVICES.HUD,
    Controls = {
        -- Absolute knob: HUD:SYM_BRT:0.5
        SYM_BRT = { Type = "axis", Command = 3002 },  -- verify
    },
}


-- Examples of the other types (fill in real ids):
--
-- MASTER_ARM = { Type = "toggle", Command = 3001, Argument = 49 },
-- SELECTOR   = { Type = "switch", Command = 3001,
--                Positions = { 0, 0.1, 0.2, 0.3 }, Argument = 400 },
-- ROCKER_UP  = { Type = "button", Command = 3001, Value = 1 },
-- ROCKER_DN  = { Type = "button", Command = 3001, Value = -1 },


------------------------------------------------------------
-- OUTPUT DEFINITIONS
--
-- Each output is sent as DCS:<NAME>:<VALUE>, only when it changes.
--
--   Argument      cockpit argument number (device 0)
--   Read          function(ctx) returning a number, instead of
--                 Argument. ctx provides:
--                   ctx.Argument(n)       cockpit argument value
--                   ctx.Indication(id)    { field = text } of a display
--                   ctx.Engine()          LoGetEngineInfo() table
--                   ctx.Now               current time (seconds)
--   Type          "boolean"  -> 0 / 1
--                 "number"   -> formatted with Precision decimals
--                 "position" -> 0-based index of nearest Positions value
--   Precision     number: decimals (default 3)
--   Round         number: round to a multiple of this before sending
--                 (limits traffic for slowly drifting values)
--   DrawFallback  use LoGetAircraftDrawArgumentValue when the
--                 cockpit argument cannot be read
--
-- Values marked "verify" should be checked in the cockpit with
-- SYS:DEBUG:1 or against DCS-BIOS FA-18C_hornet.lua.
------------------------------------------------------------

local KG_TO_LBS = 2.20462
local IFEI_INDICATOR = 5  -- list_indication id of the IFEI (verify)

-- Fuel quantities from DCS engine data, in lbs.
local function FuelLbs(ctx, field)
    local engine = ctx.Engine()

    if not engine or type(engine[field]) ~= "number" then
        return nil
    end

    return engine[field] * KG_TO_LBS
end

local function TotalFuelLbs(ctx)
    local internal = FuelLbs(ctx, "fuel_internal")

    if internal == nil then
        return nil
    end

    return internal + (FuelLbs(ctx, "fuel_external") or 0)
end

-- Bingo setting as shown on the IFEI (lbs). There is no cockpit
-- argument for it. nil while the IFEI is blank.
local function BingoLbs(ctx)
    local ifei = ctx.Indication(IFEI_INDICATOR)
    local text = ifei and ifei.txt_BINGO

    if not text then
        return nil
    end

    return tonumber((text:gsub("%s", "")))
end

-- Targeting pod laser firing.
--
-- DCS has no export value for "laser firing". The pod page on a
-- DDI / AMPCD flashes an "L" while lasing, so the display text is
-- searched for it. Only works while a pod page is displayed.
--
-- Calibrate in game: show the pod page, fire the laser and send
-- SYS:DUMP:<id> (or SYS:DUMP for all displays). Then find the
-- field in Logs/HidManager_Export.log and adjust Patterns.
local LASER_FIRING = {
    Indicators = { 2, 3, 4 },  -- left DDI, right DDI, AMPCD (verify)

    -- Lua patterns matched against each "field=value" of the
    -- display text. Default: a field whose text is just "L".
    Patterns = { "^[^=]+=%s*L%s*$" },  -- verify

    -- Keep reporting 1 this long after the last match, so the
    -- flashing symbol does not toggle the output.
    HoldTime = 1.0,

    -- Cockpit argument of the LTD/R switch. Firing is reported
    -- only while it is in ARM. nil to disable the check.
    ArmArgument = 441,  -- verify
}

local LaserLastSeen = nil

local function LaserFiring(ctx)

    if LASER_FIRING.ArmArgument then
        local arm = ctx.Argument(LASER_FIRING.ArmArgument)

        if arm ~= nil and arm < 0.5 then
            LaserLastSeen = nil
            return 0
        end
    end

    for _, id in ipairs(LASER_FIRING.Indicators) do
        local fields = ctx.Indication(id)

        if fields then
            for name, value in pairs(fields) do
                local entry = name .. "=" .. value

                for _, pattern in ipairs(LASER_FIRING.Patterns) do
                    if entry:find(pattern) then
                        LaserLastSeen = ctx.Now
                        return 1
                    end
                end
            end
        end
    end

    if LaserLastSeen and ctx.Now - LaserLastSeen < LASER_FIRING.HoldTime then
        return 1
    end

    LaserLastSeen = nil
    return 0
end

local OUTPUTS = {
    -- Warning / mode lights
    MASTER_CAUTION = { Argument = 13,  Type = "boolean" },
    MASTER_MODE_AA = { Argument = 47,  Type = "boolean" },
    MASTER_MODE_AG = { Argument = 48,  Type = "boolean" },

    -- Landing gear lights (green = down and locked)       verify
    GEAR_LEFT_LT   = { Argument = 165, Type = "boolean" },
    GEAR_NOSE_LT   = { Argument = 166, Type = "boolean" },
    GEAR_RIGHT_LT  = { Argument = 167, Type = "boolean" },
    -- Red light in the gear handle (gear in transit / unsafe)
    GEAR_HANDLE_LT = { Argument = 227, Type = "boolean" },  -- verify

    -- Laser: LTD/R switch ARM (1) / SAFE (0)              verify
    LASER_ARMED    = { Argument = 441, Type = "boolean" },
    -- Targeting pod laser firing (see LASER_FIRING above)
    LASER_FIRING   = { Type = "boolean", Read = LaserFiring },

    -- Fuel (lbs)
    FUEL_INTERNAL  = { Type = "number", Precision = 0, Round = 10,
                       Read = function(ctx)
                           return FuelLbs(ctx, "fuel_internal")
                       end },
    FUEL_TOTAL     = { Type = "number", Precision = 0, Round = 10,
                       Read = TotalFuelLbs },
    BINGO          = { Type = "number", Precision = 0,
                       Read = BingoLbs },
    -- 1 when total fuel is at or below the bingo setting
    BINGO_REACHED  = { Type = "boolean",
                       Read = function(ctx)
                           local fuel = TotalFuelLbs(ctx)
                           local bingo = BingoLbs(ctx)

                           if fuel == nil or bingo == nil then
                               return nil
                           end

                           return fuel <= bingo and 1 or 0
                       end },

    -- Display
    HUD_SYM_BRT    = { Argument = 141, Type = "number", Precision = 3,
                       DrawFallback = true },
}


------------------------------------------------------------
-- INTERNAL STATE
------------------------------------------------------------

local socket = nil
local MySocket = nil
local ConnectingSocket = nil

local LastConnectAttempt = 0
local ConnectStartedAt = 0
local LastSocketPoll = 0
local LastOutputPoll = 0
local LastAircraftCheck = 0

local ReceiveBuffer = ""
local SendQueue = {}
local SendQueueHead = 1
local PendingSendOffset = 1
local PendingSendBytes = 0

local LastOutputState = {}
local FailedOutputs = {}

local AircraftName = nil
local AircraftAllowed = false

local PendingReleases = {}   -- { Device, Command, Value, At, Key }
local HeldButtons = {}       -- key -> { Device, Command, Value }
local SwitchState = {}       -- key -> 1-based position index


------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function WriteLog(message)
    if not lfs then
        return
    end

    local file = io.open(lfs.writedir() .. Config.LogFile, "a")

    if file then
        file:write(os.date("%H:%M:%S ") .. message .. "\n")
        file:close()
    end
end

local function Log(message)
    if Config.Debug then
        WriteLog(message)
    end
end

local function LogError(message)
    WriteLog("ERROR " .. message)
end


------------------------------------------------------------
-- SEND QUEUE
------------------------------------------------------------

local function QueueOutput(message)

    if not MySocket then
        return false
    end

    if PendingSendBytes + #message > Config.MaxPendingSendBytes then
        return false
    end

    SendQueue[#SendQueue + 1] = message
    PendingSendBytes = PendingSendBytes + #message

    return true
end

local function SendOutput(name, value)
    return QueueOutput("DCS:" .. name .. ":" .. tostring(value) .. "\n")
end

local function ResetBuffers()
    ReceiveBuffer = ""
    SendQueue = {}
    SendQueueHead = 1
    PendingSendOffset = 1
    PendingSendBytes = 0
end


------------------------------------------------------------
-- DCS ACTIONS
------------------------------------------------------------

local function Click(deviceId, command, value)

    local ok, device = pcall(GetDevice, deviceId)

    if not ok or not device then
        return false
    end

    local clicked, err = pcall(
        device.performClickableAction, device, command, value
    )

    if not clicked then
        LogError(string.format(
            "performClickableAction(%s, %s, %s): %s",
            tostring(deviceId), tostring(command),
            tostring(value), tostring(err)
        ))
        return false
    end

    Log(string.format(
        "click device=%s command=%s value=%s",
        tostring(deviceId), tostring(command), tostring(value)
    ))

    return true
end

local function ReadCockpitArgument(argument)

    local ok, device = pcall(GetDevice, 0)

    if not ok or not device then
        return nil
    end

    local readOK, value = pcall(device.get_argument_value, device, argument)

    if readOK and type(value) == "number" then
        return value
    end

    return nil
end


------------------------------------------------------------
-- BUTTON RELEASE HANDLING
------------------------------------------------------------

local function CancelRelease(key)
    for i = #PendingReleases, 1, -1 do
        if PendingReleases[i].Key == key then
            table.remove(PendingReleases, i)
        end
    end
end

local function ScheduleRelease(key, deviceId, command, value, now)
    PendingReleases[#PendingReleases + 1] = {
        Key = key,
        Device = deviceId,
        Command = command,
        Value = value,
        At = now + Config.ButtonReleaseDelay,
    }
end

local function ProcessReleases(now)
    local i = 1

    while i <= #PendingReleases do
        local release = PendingReleases[i]

        if now >= release.At then
            Click(release.Device, release.Command, release.Value)
            table.remove(PendingReleases, i)
        else
            i = i + 1
        end
    end
end

-- Release everything, so no button stays pressed after a
-- disconnect or export stop.
local function ReleaseAllButtons()

    for _, release in ipairs(PendingReleases) do
        Click(release.Device, release.Command, release.Value)
    end

    PendingReleases = {}

    for _, held in pairs(HeldButtons) do
        Click(held.Device, held.Command, held.Value)
    end

    HeldButtons = {}
end


------------------------------------------------------------
-- CONTROL HANDLERS
--
-- handler(deviceId, def, arg, key, now) -> boolean
------------------------------------------------------------

local function NearestIndex(positions, value)
    local best, bestDistance = 1, math.huge

    for i, position in ipairs(positions) do
        local distance = math.abs(position - value)

        if distance < bestDistance then
            best, bestDistance = i, distance
        end
    end

    return best
end

local function CurrentSwitchIndex(def, positions, key)

    if def.Argument then
        local value = ReadCockpitArgument(def.Argument)

        if value ~= nil then
            return NearestIndex(positions, value)
        end
    end

    return SwitchState[key] or 1
end

local Handlers = {}

Handlers.button = function(deviceId, def, arg, key, now)

    local pressValue = def.Value or 1
    local releaseValue = def.ReleaseValue or 0

    -- Momentary press with automatic release.
    if arg == "" then
        CancelRelease(key)

        if not Click(deviceId, def.Command, pressValue) then
            return false
        end

        ScheduleRelease(key, deviceId, def.Command, releaseValue, now)
        return true
    end

    local state = tonumber(arg)

    if state == nil then
        return false
    end

    CancelRelease(key)

    if state ~= 0 then
        HeldButtons[key] = {
            Device = deviceId,
            Command = def.Command,
            Value = releaseValue,
        }
        return Click(deviceId, def.Command, pressValue)
    end

    HeldButtons[key] = nil
    return Click(deviceId, def.Command, releaseValue)
end

Handlers.switch = function(deviceId, def, arg, key, now)

    local positions = def.Positions or { 0, 1 }
    local count = #positions
    local current = CurrentSwitchIndex(def, positions, key)
    local target

    if arg == "" then
        if count == 2 then
            target = (current == 1) and 2 or 1
        else
            target = current + 1
        end
    elseif arg == "INC" then
        target = current + 1
    elseif arg == "DEC" then
        target = current - 1
    else
        local index = tonumber(arg)

        if index == nil then
            return false
        end

        target = math.floor(index) + 1
    end

    if def.Wrap then
        target = ((target - 1) % count) + 1
    elseif target < 1 or target > count then
        return false
    end

    if not Click(deviceId, def.Command, positions[target]) then
        return false
    end

    SwitchState[key] = target
    return true
end

Handlers.toggle = Handlers.switch

Handlers.rotary = function(deviceId, def, arg, key, now)

    local step = def.Step or 0.1
    local delta

    if arg == "" then
        delta = step
    elseif arg == "INC" then
        delta = math.abs(step)
    elseif arg == "DEC" then
        delta = -math.abs(step)
    else
        delta = tonumber(arg)
    end

    if delta == nil then
        return false
    end

    return Click(deviceId, def.Command, delta)
end

Handlers.axis = function(deviceId, def, arg, key, now)

    local value = tonumber(arg)

    if value == nil then
        return false
    end

    local minimum = def.Min or 0
    local maximum = def.Max or 1

    if value < minimum then value = minimum end
    if value > maximum then value = maximum end

    return Click(deviceId, def.Command, value)
end


------------------------------------------------------------
-- AIRCRAFT DETECTION
------------------------------------------------------------

local function UpdateAircraft(now, force)

    if not force
        and now - LastAircraftCheck < Config.AircraftCheckInterval then
        return
    end

    LastAircraftCheck = now

    local name = nil

    if type(LoGetSelfData) == "function" then
        local ok, data = pcall(LoGetSelfData)

        if ok and type(data) == "table" then
            name = data.Name
        end
    end

    if name ~= AircraftName then
        Log("aircraft: " .. tostring(name))

        -- New aircraft: drop tracked switch positions.
        SwitchState = {}
    end

    AircraftName = name

    if Config.Aircraft == nil then
        AircraftAllowed = true
    elseif name == nil then
        AircraftAllowed = Config.AllowUnknownAircraft
    else
        AircraftAllowed = (name == Config.Aircraft)
    end

    local reported = name or "NONE"

    if LastOutputState.AIRCRAFT ~= reported then
        if SendOutput("AIRCRAFT", reported) then
            LastOutputState.AIRCRAFT = reported
        end
    end
end


------------------------------------------------------------
-- COMMAND PROCESSING
------------------------------------------------------------

local function ProcessSystemCommand(name, arg)

    if name == "SYNC" then
        LastOutputState = {}
        LastOutputPoll = 0
        return true
    end

    if name == "PING" then
        return SendOutput("PONG", arg ~= "" and arg or "1")
    end

    if name == "DEBUG" then
        Config.Debug = (arg == "1")
        return true
    end

    -- Write display text to the log, for finding indication fields.
    -- SYS:DUMP:<id> dumps one display, SYS:DUMP dumps 0-20.
    if name == "DUMP" then
        if type(list_indication) ~= "function" then
            WriteLog("DUMP: list_indication not available")
            return false
        end

        local first, last = 0, 20
        local id = tonumber(arg)

        if id then
            first, last = id, id
        end

        for i = first, last do
            local ok, text = pcall(list_indication, i)

            if ok and type(text) == "string" and text ~= "" then
                WriteLog("DUMP indication " .. i .. ":\n" .. text)
            end
        end

        return true
    end

    return false
end

local function ProcessCommand(line, now)

    line = line:gsub("^%s+", ""):gsub("%s+$", "")

    local groupName, controlName, arg =
        line:match("^([%w_]+):([%w_]+):?(.*)$")

    if not groupName then
        return false
    end

    if groupName == "SYS" then
        return ProcessSystemCommand(controlName, arg)
    end

    arg = arg:upper()

    if not AircraftAllowed then
        Log("ignored (aircraft " .. tostring(AircraftName) .. "): " .. line)
        return false
    end

    local group = CONTROLS[groupName]
    local def = group and group.Controls[controlName]

    if not def then
        Log("unknown control: " .. line)
        return false
    end

    local handler = Handlers[def.Type]

    if not handler then
        LogError("unknown control type '" .. tostring(def.Type)
            .. "' for " .. groupName .. ":" .. controlName)
        return false
    end

    local key = groupName .. ":" .. controlName

    return handler(group.Device, def, arg, key, now)
end


------------------------------------------------------------
-- OUTPUTS
------------------------------------------------------------

-- Parse list_indication() text into { field = value }.
local function ParseIndication(id)

    if type(list_indication) ~= "function" then
        return nil
    end

    local ok, text = pcall(list_indication, id)

    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end

    local fields = {}

    for name, value in text:gmatch(
        "%-%-%-%-%-+\n([^\n]+)\n([^\n]*)\n"
    ) do
        fields[name] = value
    end

    return fields
end

-- Per-poll read context with lazy caching, passed to Read functions.
local function NewReadContext()

    local indications = {}
    local engine = false

    local ctx = {}

    ctx.Now = socket.gettime()
    ctx.Argument = ReadCockpitArgument

    ctx.Indication = function(id)
        if indications[id] == nil then
            indications[id] = ParseIndication(id) or false
        end

        return indications[id] or nil
    end

    ctx.Engine = function()
        if engine == false then
            engine = nil

            if type(LoGetEngineInfo) == "function" then
                local ok, info = pcall(LoGetEngineInfo)

                if ok and type(info) == "table" then
                    engine = info
                end
            end
        end

        return engine
    end

    return ctx
end

local function ReadOutput(def, ctx)

    if def.Read then
        local value = def.Read(ctx)
        return type(value) == "number" and value or nil
    end

    local value = ReadCockpitArgument(def.Argument)

    if value == nil
        and def.DrawFallback
        and type(LoGetAircraftDrawArgumentValue) == "function" then

        local ok, drawValue =
            pcall(LoGetAircraftDrawArgumentValue, def.Argument)

        if ok and type(drawValue) == "number" then
            value = drawValue
        end
    end

    return value
end

local function FormatOutput(def, value)

    if def.Type == "boolean" then
        return value >= 0.5 and "1" or "0"
    end

    if def.Type == "position" then
        return tostring(NearestIndex(def.Positions, value) - 1)
    end

    if def.Round then
        value = math.floor(value / def.Round + 0.5) * def.Round
    end

    return string.format("%." .. (def.Precision or 3) .. "f", value)
end

local function UpdateOutputs()

    local ctx = NewReadContext()

    for name, def in pairs(OUTPUTS) do

        local ok, value = pcall(ReadOutput, def, ctx)

        if not ok then
            -- Log each failing output once, not 20 times a second.
            if not FailedOutputs[name] then
                FailedOutputs[name] = true
                LogError("output " .. name .. ": " .. tostring(value))
            end

            value = nil
        end

        if value ~= nil then
            local formatted = FormatOutput(def, value)

            if LastOutputState[name] ~= formatted then
                if SendOutput(name, formatted) then
                    LastOutputState[name] = formatted
                end
            end
        end
    end
end


------------------------------------------------------------
-- CONNECTION
------------------------------------------------------------

local function DisconnectSocket()

    if MySocket then
        pcall(function() MySocket:close() end)
    end

    if ConnectingSocket then
        pcall(function() ConnectingSocket:close() end)
    end

    MySocket = nil
    ConnectingSocket = nil

    ReleaseAllButtons()
    ResetBuffers()
end

local function ConfigureConnectedSocket(client)

    client:settimeout(0)

    pcall(function() client:setoption("tcp-nodelay", true) end)

    MySocket = client
    ConnectingSocket = nil

    ResetBuffers()

    -- Resend everything after connecting.
    LastOutputState = {}
    LastSocketPoll = 0
    LastOutputPoll = 0

    UpdateAircraft(socket.gettime(), true)

    Log("connected " .. Config.IPAddress .. ":" .. tostring(Config.Port))
end

local function TryConnect()

    if MySocket then
        return true
    end

    local now = socket.gettime()

    -- Complete a pending non-blocking connection.
    if ConnectingSocket then

        if now - ConnectStartedAt >= Config.ConnectPendingTimeout then
            pcall(function() ConnectingSocket:close() end)
            ConnectingSocket = nil
            LastConnectAttempt = now
            return false
        end

        local _, writable = socket.select({}, { ConnectingSocket }, 0)

        if not writable or #writable == 0 then
            return false
        end

        -- Writable means success or failure; getpeername tells which.
        local ok, address = pcall(function()
            return ConnectingSocket:getpeername()
        end)

        if ok and address then
            ConfigureConnectedSocket(ConnectingSocket)
            return true
        end

        pcall(function() ConnectingSocket:close() end)
        ConnectingSocket = nil
        LastConnectAttempt = now
        return false
    end

    if now - LastConnectAttempt < Config.ReconnectInterval then
        return false
    end

    LastConnectAttempt = now

    local client = socket.tcp()

    if not client then
        return false
    end

    client:settimeout(0)

    local result, connectError = client:connect(Config.IPAddress, Config.Port)

    if result then
        ConfigureConnectedSocket(client)
        return true
    end

    if connectError == "timeout"
        or connectError == "Operation already in progress" then
        ConnectingSocket = client
        ConnectStartedAt = now
        return false
    end

    pcall(function() client:close() end)
    return false
end


------------------------------------------------------------
-- RECEIVE (keeps incomplete lines between polls)
------------------------------------------------------------

local function ReceiveCommands(now)

    local processed = 0

    while MySocket and processed < Config.MaxCommandsPerPoll do

        local data, err, partial = MySocket:receive(4096)
        local chunk = data or partial

        if chunk and #chunk > 0 then
            ReceiveBuffer = ReceiveBuffer .. chunk

            if #ReceiveBuffer > Config.MaxReceiveBuffer then
                LogError("receive buffer exceeded limit")
                DisconnectSocket()
                return
            end
        end

        while MySocket and processed < Config.MaxCommandsPerPoll do

            local newline = ReceiveBuffer:find("\n", 1, true)

            if not newline then
                break
            end

            local line = ReceiveBuffer:sub(1, newline - 1)
            ReceiveBuffer = ReceiveBuffer:sub(newline + 1)

            local ok, err2 = pcall(ProcessCommand, line, now)

            if not ok then
                LogError("command '" .. line .. "': " .. tostring(err2))
            end

            processed = processed + 1
        end

        if not MySocket then
            return
        end

        if err == "timeout" then
            break
        end

        if err then
            Log("connection lost: " .. tostring(err))
            DisconnectSocket()
            return
        end

        if not data or #data < 4096 then
            break
        end
    end
end


------------------------------------------------------------
-- SEND (resumes partial sends on subsequent polls)
------------------------------------------------------------

local function CompleteMessage()
    SendQueue[SendQueueHead] = false
    SendQueueHead = SendQueueHead + 1
    PendingSendOffset = 1
end

local function FlushSendQueue()

    local messagesSent = 0

    while MySocket
        and SendQueueHead <= #SendQueue
        and messagesSent < Config.MaxMessagesPerFlush do

        local message = SendQueue[SendQueueHead]
        local sent, err, last = MySocket:send(message, PendingSendOffset)

        if sent then
            PendingSendBytes = PendingSendBytes - (sent - PendingSendOffset + 1)

            if sent >= #message then
                CompleteMessage()
                messagesSent = messagesSent + 1
            else
                PendingSendOffset = sent + 1
                break
            end

        elseif err == "timeout" then

            if last and last >= PendingSendOffset then
                PendingSendBytes = PendingSendBytes - (last - PendingSendOffset + 1)
                PendingSendOffset = last + 1

                if PendingSendOffset > #message then
                    CompleteMessage()
                end
            end

            break

        else
            Log("send failed: " .. tostring(err))
            DisconnectSocket()
            return
        end
    end

    -- Compact the queue occasionally.
    if SendQueueHead > 64 and SendQueueHead > #SendQueue / 2 then
        local compacted = {}

        for i = SendQueueHead, #SendQueue do
            if SendQueue[i] then
                compacted[#compacted + 1] = SendQueue[i]
            end
        end

        SendQueue = compacted
        SendQueueHead = 1
    end
end


------------------------------------------------------------
-- DCS EXPORT CALLBACKS (chained with existing exports)
------------------------------------------------------------

local Previous = {
    Start = LuaExportStart,
    BeforeNextFrame = LuaExportBeforeNextFrame,
    AfterNextFrame = LuaExportAfterNextFrame,
    Stop = LuaExportStop,
}

local function CallPrevious(name)
    local fn = Previous[name]

    if fn then
        local ok, err = pcall(fn)

        if not ok then
            LogError("previous LuaExport" .. name .. ": " .. tostring(err))
        end
    end
end

local function Guard(name, fn)
    local ok, err = pcall(fn)

    if not ok then
        LogError(name .. ": " .. tostring(err))
    end
end


function LuaExportStart()

    CallPrevious("Start")

    Guard("Start", function()
        package.path = package.path
            .. ";" .. lfs.currentdir() .. "/LuaSocket/?.lua"
        package.cpath = package.cpath
            .. ";" .. lfs.currentdir() .. "/LuaSocket/?.dll"

        socket = require("socket")

        DisconnectSocket()

        LastConnectAttempt = 0
        LastSocketPoll = 0
        LastOutputPoll = 0
        LastAircraftCheck = 0
        LastOutputState = {}
        SwitchState = {}

        WriteLog("HidManager export bridge started")

        TryConnect()
    end)
end


function LuaExportBeforeNextFrame()

    CallPrevious("BeforeNextFrame")

    if socket and not MySocket then
        Guard("TryConnect", TryConnect)
    end
end


function LuaExportAfterNextFrame()

    CallPrevious("AfterNextFrame")

    if not socket then
        return
    end

    Guard("AfterNextFrame", function()

        local now = socket.gettime()

        -- Releases run even while disconnected.
        ProcessReleases(now)

        if not MySocket then
            return
        end

        if now - LastSocketPoll >= Config.SocketPollInterval then
            LastSocketPoll = now

            UpdateAircraft(now)
            ReceiveCommands(now)

            if MySocket then
                FlushSendQueue()
            end
        end

        if MySocket and now - LastOutputPoll >= Config.OutputPollInterval then
            LastOutputPoll = now
            UpdateOutputs()
        end
    end)
end


function LuaExportStop()

    Guard("Stop", function()
        if MySocket then
            QueueOutput("exit\n")
            FlushSendQueue()
        end

        DisconnectSocket()

        WriteLog("HidManager export bridge stopped")
    end)

    CallPrevious("Stop")
end
