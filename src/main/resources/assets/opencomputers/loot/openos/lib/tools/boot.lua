-- called from /init.lua
local raw_loadfile = ...

_G._OSVERSION = "OpenOS 1.6"

local component = component
local computer = computer
local unicode = unicode

-- Runlevel information.
local runlevel, shutdown = "S", computer.shutdown
computer.runlevel = function() return runlevel end
computer.shutdown = function(reboot)
  runlevel = reboot and 6 or 0
  if os.sleep then
    computer.pushSignal("shutdown")
    os.sleep(0.1) -- Allow shutdown processing.
  end
  shutdown(reboot)
end

local screen = component.list('screen', true)()
for address in component.list('screen', true) do
  if #component.invoke(address, 'getKeyboards') > 0 then
    screen = address
    break
  end
end

_G.boot_screen = screen

-- Report boot progress if possible.
local gpu = component.list("gpu", true)()
local w, h
if gpu and screen then
  component.invoke(gpu, "bind", screen)
  w, h = component.invoke(gpu, "maxResolution")
  component.invoke(gpu, "setResolution", w, h)
  component.invoke(gpu, "setBackground", 0x000000)
  component.invoke(gpu, "setForeground", 0xFFFFFF)
  component.invoke(gpu, "fill", 1, 1, w, h, " ")
end
local y = 1
local function status(msg)
  if gpu and screen then
    component.invoke(gpu, "set", 1, y, msg)
    if y == h then
      component.invoke(gpu, "copy", 1, 2, w, h - 1, 0, -1)
      component.invoke(gpu, "fill", 1, h, w, 1, " ")
    else
      y = y + 1
    end
  end
end

status("Booting " .. _OSVERSION .. "...")

-- Custom low-level dofile implementation reading from our ROM.
local loadfile = function(file)
  status("> " .. file)
  return raw_loadfile(file)
end

local function dofile(file)
  local program, reason = loadfile(file)
  if program then
    local result = table.pack(pcall(program))
    if result[1] then
      return table.unpack(result, 2, result.n)
    else
      error(result[2])
    end
  else
    error(reason)
  end
end

status("Initializing package management...")

-- Load file system related libraries we need to load other stuff moree
-- comfortably. This is basically wrapper stuff for the file streams
-- provided by the filesystem components.
local package = dofile("/lib/package.lua")

do
  -- Unclutter global namespace now that we have the package module.
  _G.component = nil
  _G.computer = nil
  _G.process = nil
  _G.unicode = nil

  -- Initialize the package module with some of our own APIs.
  package.loaded.component = component
  package.loaded.computer = computer
  package.loaded.unicode = unicode
  package.preload["buffer"] = loadfile("/lib/buffer.lua")
  package.preload["filesystem"] = loadfile("/lib/filesystem.lua")

  -- Inject the package and io modules into the global namespace, as in Lua.
  _G.package = package
  _G.io = loadfile("/lib/io.lua")()

  --mark modules for delay loaded api
  package.delayed["text"] = true
  package.delayed["sh"] = true
  package.delayed["transforms"] = true
  package.delayed["term"] = true
end

status("Initializing file system...")

-- Mount the ROM and temporary file systems to allow working on the file
-- system module from this point on.
require("filesystem").mount(computer.getBootAddress(), "/")
package.preload={}

status("Running boot scripts...")

-- Run library startup scripts. These mostly initialize event handlers.
local function rom_invoke(method, ...)
  return component.invoke(computer.getBootAddress(), method, ...)
end

local scripts = {}
for _, file in ipairs(rom_invoke("list", "boot")) do
  local path = "boot/" .. file
  if not rom_invoke("isDirectory", path) then
    table.insert(scripts, path)
  end
end
table.sort(scripts)
for i = 1, #scripts do
  dofile(scripts[i])
end

status("Initializing components...")

for c, t in component.list() do
  computer.pushSignal("component_added", c, t)
end

status("Initializing system...")

computer.pushSignal("init") -- so libs know components are initialized.
require("event").pull(1, "init") -- Allow init processing.
_G.runlevel = 1