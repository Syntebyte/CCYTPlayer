-- BEGIN DATA SECTION --
local RAW_SM = [[
local function volume()
    local red = redstone.getAnalogOutput("left")
    return red / 15 * 3.0
end

local function get_speakers(name)
    if name then
        local speaker = peripheral.wrap(name)
        if speaker == nil then
            error(("Speaker %q does not exist"):format(name), 0)
            return
        elseif not peripheral.hasType(name, "speaker") then
            error(("%q is not a speaker"):format(name), 0)
        end

        return { speaker }
    else
        local speakers = { peripheral.find("speaker") }
        if #speakers == 0 then
            error("No speakers attached", 0)
        end
        return speakers
    end
end

local function pcm_decoder(chunk)
    local buffer = {}
    for i = 1, #chunk do
        buffer[i] = chunk:byte(i) - 128
    end
    return buffer
end

local function report_invalid_format(format)
    printError(("speaker cannot play %s files."):format(format))
    local pp = require "cc.pretty"
    pp.print("Run '" .. pp.text("help speaker", colours.lightGrey) .. "' for information on supported formats.")
end


local cmd = ...
if cmd == "stop" then
    local _, name = ...
    for _, speaker in pairs(get_speakers(name)) do speaker.stop() end
elseif cmd == "play" then
    local _, file, name = ...
    local speaker = get_speakers(name)[1]

    local handle, err
    if http and file:match("^https?://") then
        print("Downloading...")
        handle, err = http.get{ url = file, binary = true }
    else
        handle, err = fs.open(file, "rb")
    end

    if not handle then
        printError("Could not play audio:")
        error(err, 0)
    end

    local start = handle.read(4)
    local pcm = false
    local size = 16 * 1024 - 4
    if start == "RIFF" then
        handle.read(4)
        if handle.read(8) ~= "WAVEfmt " then
            handle.close()
            error("Could not play audio: Unsupported WAV file", 0)
        end

        local fmtsize = ("<I4"):unpack(handle.read(4))
        local fmt = handle.read(fmtsize)
        local format, channels, rate, _, _, bits = ("<I2I2I4I4I2I2"):unpack(fmt)
        if not ((format == 1 and bits == 8) or (format == 0xFFFE and bits == 1)) then
            handle.close()
            error("Could not play audio: Unsupported WAV file", 0)
        end
        if channels ~= 1 or rate ~= 48000 then
            print("Warning: Only 48 kHz mono WAV files are supported. This file may not play correctly.")
        end
        if format == 0xFFFE then
            local guid = fmt:sub(25)
            if guid ~= "\x3A\xC1\xFA\x38\x81\x1D\x43\x61\xA4\x0D\xCE\x53\xCA\x60\x7C\xD1" then -- DFPWM format GUID
                handle.close()
                error("Could not play audio: Unsupported WAV file", 0)
            end
            size = size + 4
        else
            pcm = true
            size = 16 * 1024 * 8
        end

        repeat
            local chunk = handle.read(4)
            if chunk == nil then
                handle.close()
                error("Could not play audio: Invalid WAV file", 0)
            elseif chunk ~= "data" then -- Ignore extra chunks
                local size = ("<I4"):unpack(handle.read(4))
                handle.read(size)
            end
        until chunk == "data"

        handle.read(4)
        start = nil
    -- Detect several other common audio files.
    elseif start == "OggS" then return report_invalid_format("Ogg")
    elseif start == "fLaC" then return report_invalid_format("FLAC")
    elseif start:sub(1, 3) == "ID3" then return report_invalid_format("MP3")
    elseif start == "<!DO" --\[\[<!DOCTYPE\]\] then return report_invalid_format("HTML")
    end

    print("Playing " .. file)

    local decoder = pcm and pcm_decoder or require "cc.audio.dfpwm".make_decoder()
    while true do
        local chunk = handle.read(size)
        if not chunk then break end
        if start then
            chunk, start = start .. chunk, nil
            size = size + 4
        end

        local buffer = decoder(chunk)
        while not speaker.playAudio(buffer, volume()) do
            if not redstone.getOutput("top") then
                return
            end
            os.pullEvent("speaker_audio_empty")
        end
    end

    handle.close()
else
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usage:")
    print(programName .. " play <file or url> [speaker]")
    print(programName .. " stop [speaker]")
end
]]
RAW_SM = RAW_SM:gsub("\\%[", "[")
RAW_SM = RAW_SM:gsub("\\%]", "]")

local RAW_CS = [[
local args = {...}

local mod = peripheral.find("modem")
if mod == nil then
    print("Network not found: Please install modem")
    return
end

if args[1] ~= "debug" then 
    term.setBackgroundColor(16384)
end

term.clear()
print("YouTube audio player for ComputerCraft")
print("CCYTP in-game server")
print("- hikkanya hikkan -")
print()

local _cur = shell.getRunningProgram()
local _dir = fs.getDir(_cur)
local _mod = "/" .. _dir .. "/.speaker.mod.lua"
local _dat = "/" .. _dir .. "/.serverdata"
local port = nil
local ip = nil

if args[1] == "reset" then 
    fs.delete(_dat)
end

if fs.exists(_dat) then
    print("Loading saved IP. Use 'ccytp-server reset' to change")
    local ff = fs.open(_dat, "r")
    local l = 0
    while l < 2 do
        if l == 0 then ip = ff.readLine()
        else port = tonumber(ff.readLine()) end
        l = l + 1
    end
    ff.close()
else
    print("Party number (0-65535): ")
    port = tonumber(read())

    io.write("HTTP server IP: ")
    io.flush()
    ip = read()

    local ff = fs.open(_dat, "w")
    ff.write(ip.."\n"..tostring(port))
    ff.close()
end

mod.open(port)   -- receive
mod.open(port+1) -- reply

local function reply(msg)
    print()
    print(msg)
    mod.transmit(port+1, port, msg)
end

reply("In-game server listening at port "..tostring(port))

-- states
local idle = false
local playing = true
local pending = 1
local state = idle

local request = nil

local function stop()
    state = idle
    redstone.setOutput("top", state)        
end

local function track()
    reply("Searching \""..request.."\"...")
    state = pending
end

local function volume(vol)
    vol = math.max(0, vol)
    vol = math.min(15, vol)
    redstone.setAnalogOutput("left", vol)
    reply("Volume changed to "..tostring(vol).." of 15")    
end

volume(8)

local function request_handler()
    while true do
        local e,a,b,c,d = os.pullEvent("modem_message")
        request = d
        local n = tonumber(d, 10)
        
        if n ~= nil then
            volume(n)
            
        elseif request == "stop" then
            stop()
            reply("Track stopped")
            
        elseif request ~= "" then
            stop()
            track()
        end       
    end        
end 

local function speaker_mod()
    while true do
        if state == pending then
            text = request:gsub("%s+", "_")
            state = playing
            redstone.setOutput("top", state)
            reply("Playing \""..request.."\"")
            os.run({}, _mod, "play", "http://"..ip..":25558/?v="..text)
            state = idle
            redstone.setOutput("top", state)
            reply("Track ended.")            
        else
            os.sleep(0.5)
        end
    end
end

parallel.waitForAny(request_handler, speaker_mod)
]]

RAW_CL = [[
local args = {...}
local restr = term.getBackgroundColor()

local mod = peripheral.find("modem")
if mod == nil then
    print("Network not found: Please install modem")
    return
end

if args[1] ~= "debug" then 
    term.setBackgroundColor(16384)
end

term.clear()
print("YouTube audio player")
print("for ComputerCraft")
print("CCYTP in-game client")
print("- hikkanya hikkan -")
print()

local _cur = shell.getRunningProgram()
local _dir = fs.getDir(_cur)
local _dat = "/" .. _dir .. "/.clientdata"
local port = nil

if args[1] == "reset" then 
    fs.delete(_dat)
end

if fs.exists(_dat) then
    print("Loading saved Party.\nUse 'ccytp reset' to change")
    local ff = fs.open(_dat, "r")
    port = tonumber(ff.readAll())
    ff.close()
else
    print("Party number (0-65535): ")
    port = tonumber(read())
    local ff = fs.open(_dat, "w")
    ff.write(tostring(port))
    ff.close()
end

mod.open(port)
mod.open(port+1) --reply

print()
print("Commands: <Search> - Play,")
print("0-15 - volume, stop, exit")
print("If trouble or no play:")
print("try another search")
print()

while true do
    local request = read()
    if request == "exit" then
        term.setBackgroundColor(restr)
        term.clear()
        return
    end
    mod.transmit(port, port+1, request)
    local a,b,c,d,e = os.pullEvent("modem_message")
    print()
    print(e)
    print()
end
]]
-- END DATA SECTION --

-- BEGIN FUNCTIONS SECTION --
local function writefile(file, contents)
    local f = fs.open(file, "w")
    f.write(contents)
    f.close()
end
-- END FUNCTIONS SECTION --

-- BEGIN LOGIC SECTION --
local restr = term.getBackgroundColor()
term.setBackgroundColor(16384)
term.clear()
print("Welcome to CCYTP setup!")
print("Choose variant: ")
print("1) CCYTP in-game Server")
print("  for stationary computers")
print("2) CCYTP in-game Client")
print("  for all computers")
print()

io.write("Your choice: ")
io.flush()
local choice = read()
term.clear()

local dir = ""
local com = ""

if choice == "1" then
    local def = "/ccytp"
    com = "ccytp-server"

    print("Specify dir to install CCYTP in-game Server")
    print("Leave empty for default "..def)

    io.write("> ")
    io.flush()

    dir = read()
    if dir == "" then
        dir = def
    end

    local speaker_mod = dir.."/.speaker.mod.lua"
    local server = dir.."/ccytp-server.lua"

    fs.makeDir(dir)
    writefile(speaker_mod, RAW_SM)
    writefile(server, RAW_CS)
else
    local def = "/ccytp"
    com = "ccytp"

    print("Specify dir to install\nCCYTP in-game Client")
    print("Leave empty for default "..def)

    io.write("> ")
    io.flush()

    dir = read()
    if dir == "" then
        dir = def
    end

    local cclient = dir.."/ccytp.lua"

    fs.makeDir(dir)
    writefile(cclient, RAW_CL)
end

startup = fs.open("/startup.lua", "a")
startup.write("\nshell.setPath(shell.path()..\":"..dir.."\")")
startup.close()
shell.setPath(shell.path()..":"..dir)

print("Installation completed. Use '"..com.."'")
print("Press any key to continue...")
read()
term.setBackgroundColor(restr)
term.clear()
-- END LOGIC SECTION --