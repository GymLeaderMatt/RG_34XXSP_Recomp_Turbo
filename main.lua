-- G1R TurboHotkeys Mod
--
-- Adds four rebindable actions to the game's own CONTROLS screen:
--   TURBO A / TURBO B  -- hold to mash, up to one press per fixed step (60/s)
--   SAVE / LOAD        -- the F1 / F2 quicksave and quickload, on a button
--
-- It also swaps the pad's A and B, which is a default-level swap rather than a
-- map-level one: it steps aside the moment either row carries a user pad
-- binding, so the CONTROLS screen can never disagree with the hardware.
--
-- Three engine facts shape this file:
--
--   1. Input:applyBindings never validates an action id against the eight GB
--      buttons -- it just does keyBindings[key] = actionId.  So "turbo_a" and
--      friends become first-class actions readable with input:isDown, riding
--      the engine's multi-source bookkeeping (pad, keyboard, hat, focus-loss
--      recovery) for free.  Nothing else in the engine reads them, and
--      softResetHeld only tests a/b/start/select, so they are inert.
--
--   2. Game:gamepadpressed answers the shoulders and triggers with GAME SPEED
--      and returns BEFORE Input or the BindingsMenu capture ever see them, so
--      L1/R1/L2/R2 are unbindable in stock.  claimShoulder below reimplements
--      the rest of that function for those four buttons, minus the speed
--      branch, which is what makes L1 and R1 bindable at all.
--
--   3. mod.input:tap is a press immediately followed by its release, so
--      Input:step promotes a wasPressed edge and leaves the held state alone
--      (the sources == {} rule).  That is exactly turbo, and it can never
--      clear a hold the pad or keyboard still owns.
--
-- Every module-table patch uses the marker-beside-the-patch plus
-- claimed-slot shape from SANDBOX_MIGRATION_MASTER.md section 3: the marker
-- installs the wrapper exactly once so an F5 reload cannot stack copies, and
-- the slot lets the newest load answer instead of freezing the first one's
-- closure in place forever.

local function req(name)
  local ok, m = pcall(require, name)
  if ok then return m end
  return nil
end

local Input = req("src.core.Input")
local SaveData = req("src.core.SaveData")
local GamepadMap = req("src.core.GamepadMap")
local BindingsMenu = req("src.ui.BindingsMenu")

-- One row per added action.  A default in BOTH slots is mandatory, not
-- cosmetic: BindingsMenu:storeBinding's swap-never-steal pass assumes every
-- row has a `prev` to hand to whichever row it displaces, and confirmReset
-- renders every row through boundRight(nil, def).  A nil here crashes both.
--
-- A row may carry `action`, the id actually written into the binding maps
-- when it differs from the row's own id.  ALT SEL uses it to become a second
-- genuine source for the GB select button rather than a mod-forwarded press:
-- that way it holds properly for Select+direction and the display chords,
-- and releasing it cannot cancel the real Select button held alongside it.
local ROWS = {
  { id = "turbo_a", label = "TURBO A", key = "c", pad = "x" },
  { id = "turbo_b", label = "TURBO B", key = "v", pad = "leftshoulder" },
  { id = "state_save", label = "SAVE", key = "f1", pad = "leftstick" },
  { id = "state_load", label = "LOAD", key = "f2", pad = "rightshoulder" },
  { id = "alt_select", label = "ALT SEL", key = "n", pad = "y", action = "select" },
}

local SPEED_BUTTONS = {
  leftshoulder = true, rightshoulder = true,
  lefttrigger = true, righttrigger = true,
}

-- Mirrors BindingsMenu's own KEY_SHORT / PAD_SHORT so an added row's right
-- column reads the same as a stock one.  Those tables are locals in that
-- file and cannot be borrowed.
local KEY_SHORT = {
  escape = "ESC", backspace = "BKSP", ["return"] = "ENTER",
  kpenter = "ENTER", space = "SPACE",
}
local PAD_SHORT = {
  dpup = "D-UP", dpdown = "D-DN", dpleft = "D-LT", dpright = "D-RT",
  leftshoulder = "LB", rightshoulder = "RB",
  leftstick = "LS", rightstick = "RS", guide = "GUIDE",
}

local RATE_CHOICES = {
  { "60/S", 1 },
  { "30/S", 2 },
  { "20/S", 3 },
  { "15/S", 4 },
  { "12/S", 5 },
  { "10/S", 6 },
}

local HOLD_TO_LOAD_SECONDS = 0.6
local TOAST_SECONDS = 1.4

local function shortName(name, shorts)
  if type(name) ~= "string" or name == "" then return "-" end
  local s = shorts[name]
  if s then return s end
  s = name:upper()
  return #s > 5 and s:sub(1, 5) or s
end

local function boundKey(overlay, def)
  local b = overlay and overlay[def.id]
  if type(b) == "table" then return b.key or def.key end
  if type(b) == "string" then return b end
  return def.key
end

local function boundPad(overlay, def)
  local b = overlay and overlay[def.id]
  if type(b) == "table" and b.pad then return b.pad end
  return def.pad
end

local function rightColumn(overlay, def)
  local key = shortName(boundKey(overlay, def), KEY_SHORT)
  local pad = boundPad(overlay, def)
  if pad then return key .. "/" .. shortName(pad, PAD_SHORT) end
  return key
end

local function optBool(mod, key, fallback)
  local v = mod.options:get(key)
  if type(v) ~= "boolean" then return fallback end
  return v
end

local function ratePeriod(mod)
  local v = mod.options:get("turbo_rate")
  if type(v) ~= "number" then v = 1 end
  v = math.floor(v + 0.5)
  if v < 1 then v = 1 end
  if v > 6 then v = 6 end
  return v
end

local function bindingsOf(game)
  local opts = game and game.save and game.save.options
  return opts and opts.bindings
end

return function(mod)
  mod.options:define({
    { key = "turbo_enabled", type = "toggle", label = "TURBO", default = true },
    {
      key = "turbo_rate",
      type = "choice",
      label = "TURBO RATE",
      default = 1,
      choices = RATE_CHOICES,
    },
    {
      key = "free_shoulders",
      type = "toggle",
      label = "FREE SHOULDERS",
      default = true,
    },
    { key = "swap_ab", type = "toggle", label = "SWAP A/B", default = true },
    { key = "state_keys", type = "toggle", label = "SAVE/LOAD KEYS", default = true },
    { key = "hold_to_load", type = "toggle", label = "HOLD TO LOAD", default = false },
    { key = "show_toast", type = "toggle", label = "SHOW MESSAGE", default = true },
  })

  local toastText, toastLeft = nil, 0

  local function toast(text)
    if not optBool(mod, "show_toast", true) then return end
    toastText, toastLeft = text, TOAST_SECONDS
  end

  ----------------------------------------------------------------------
  -- 1. Defaults into the live binding map.
  --
  -- applyBindings rebuilds keyBindings / padBindings from scratch on every
  -- call, so a default this mod wants has to be re-added after each rebuild
  -- rather than written once.  Claiming only unoccupied slots means a
  -- default can never shadow a real GB button, and an overlay entry for the
  -- same action always wins because the original already applied it.
  ----------------------------------------------------------------------
  -- The A/B swap deliberately applies to the DEFAULT pad bindings only.  If
  -- the CONTROLS screen holds a user pad binding for either A or B, the swap
  -- steps aside entirely -- otherwise the screen would say one thing and the
  -- pad would do the other, and a rebind would appear to set the opposite
  -- button.  Whatever is set by hand wins, for both rows.
  local function userPadBound(overlay, id)
    local b = overlay and overlay[id]
    return type(b) == "table" and b.pad ~= nil
  end

  local function swapActive(overlay)
    if not optBool(mod, "swap_ab", true) then return false end
    if userPadBound(overlay, "a") or userPadBound(overlay, "b") then return false end
    return true
  end

  -- Pad only: the keyboard rows are unlabelled and swapping them would just
  -- be confusing.  Values are exchanged in a second pass rather than during
  -- the traversal, since only reassignment of existing keys is well-defined
  -- while a pairs() loop is live.
  local function swapPadAB(input, overlay)
    if not (input and input.padBindings) then return end
    if not swapActive(overlay) then return end
    local flips = nil
    for pad, action in pairs(input.padBindings) do
      if action == "a" then
        flips = flips or {}
        flips[pad] = "b"
      elseif action == "b" then
        flips = flips or {}
        flips[pad] = "a"
      end
    end
    if not flips then return end
    for pad, action in pairs(flips) do input.padBindings[pad] = action end
  end

  local function applyDefaults(input, overlay)
    if not (input and input.keyBindings and input.padBindings) then return end
    overlay = overlay or {}
    for _, def in ipairs(ROWS) do
      local action = def.action or def.id
      local b = overlay[def.id]

      -- A rebound row was already written by the original applyBindings, but
      -- under the row's own id -- so an `action` row needs retargeting there.
      -- An unbound row falls back to its default and claims that slot only if
      -- nothing else holds it, which is what stops a default shadowing a real
      -- GB button.
      local key = (type(b) == "table" and b.key) or (type(b) == "string" and b) or nil
      if key == nil and def.key and input.keyBindings[def.key] == nil then
        key = def.key
      end

      local pad = (type(b) == "table" and b.pad) or nil
      if pad == nil and def.pad and input.padBindings[def.pad] == nil then
        pad = def.pad
      end

      if key then input.keyBindings[key] = action end
      if pad then input.padBindings[pad] = action end
    end

    -- Last, so it sees the finished map.  None of the added rows write "a" or
    -- "b" as their action -- turbo uses turbo_a / turbo_b -- so nothing above
    -- is caught by this, and turbo keeps mashing the action it is named for.
    swapPadAB(input, overlay)
  end

  if Input and Input.applyBindings then
    local slot = Input.__turboHotkeysBindings
    if not slot then
      slot = {}
      Input.__turboHotkeysBindings = slot
      local orig = Input.applyBindings
      Input.applyBindings = function(self, overlay, ...)
        local result = orig(self, overlay, ...)
        if slot.applyDefaults then pcall(slot.applyDefaults, self, overlay) end
        return result
      end
    end
    slot.applyDefaults = applyDefaults
  end

  ----------------------------------------------------------------------
  -- 2. Free the shoulders and triggers.
  --
  -- A faithful copy of the tail of Game:gamepadpressed with the GAME SPEED
  -- branch removed, so those four buttons reach the top state's capture hook
  -- (making them bindable on the CONTROLS screen) and then Input, exactly
  -- like a face button.  Select+L still resolves to the "7" display chord.
  ----------------------------------------------------------------------
  local function claimShoulder(game, joystick, button)
    if not SPEED_BUTTONS[button] then return false end
    if not optBool(mod, "free_shoulders", true) then return false end

    local TouchControls = req("src.core.TouchControls")
    if TouchControls and TouchControls.noteGamepad then
      pcall(function() TouchControls:noteGamepad() end)
    end

    local selectHeld = Input and Input:isDown("select") or false
    if not selectHeld and joystick and joystick.isGamepadDown then
      local ok, down = pcall(function() return joystick:isGamepadDown("back") end)
      selectHeld = ok and down == true
    end

    local top = game and game.stack and game.stack:top()
    if top and top.onGamepadPressed then
      top:onGamepadPressed(button)
      return true
    end

    if selectHeld and GamepadMap and GamepadMap.displayChordDigit then
      local digit = GamepadMap.displayChordDigit(button)
      if digit then
        game:keypressed(digit)
        return true
      end
    end

    if Input then Input:gamepadpressed(joystick, button) end
    return true
  end

  local GameModule = req("src.core.Game")
  if GameModule and GameModule.gamepadpressed then
    local slot = GameModule.__turboHotkeysPad
    if not slot then
      slot = {}
      GameModule.__turboHotkeysPad = slot
      local orig = GameModule.gamepadpressed
      GameModule.gamepadpressed = function(self, joystick, button, ...)
        if slot.claim then
          local ok, claimed = pcall(slot.claim, self, joystick, button)
          if ok and claimed then return end
        end
        return orig(self, joystick, button, ...)
      end
    end
    slot.claim = claimShoulder
  end

  ----------------------------------------------------------------------
  -- 3. The extra CONTROLS rows.
  --
  -- BindingsMenu has no Runtime hook and its BUTTONS table is a local, so
  -- the rows are appended to self.items after ListMenu.new has built them.
  -- Everything downstream is index-agnostic: onChoose arms the capture,
  -- SELECT clears, START's reset-all and storeBinding's swap both iterate
  -- self.items, and the list scrolls past its six visible rows.
  ----------------------------------------------------------------------
  local function decorate(menu, game)
    if not (menu and menu.items) then return end
    local overlay = bindingsOf(game)
    for _, def in ipairs(ROWS) do
      menu.items[#menu.items + 1] = {
        label = def.label,
        right = rightColumn(overlay, def),
        button = def,
      }
    end

    -- With the swap on, the stock A and B rows would otherwise advertise the
    -- pre-swap pad button.  Exchanging the two right columns makes the screen
    -- agree with the hardware.  Kept after the append and in its own pcall so
    -- an unexpected item shape here cannot cost us the five added rows.
    pcall(function()
      if not swapActive(overlay) then return end
      local rowA, rowB
      for _, it in ipairs(menu.items) do
        local id = type(it.button) == "table" and it.button.id or nil
        if id == "a" then rowA = it elseif id == "b" then rowB = it end
      end
      if rowA and rowB then rowA.right, rowB.right = rowB.right, rowA.right end
    end)
  end

  if BindingsMenu and BindingsMenu.new then
    local slot = BindingsMenu.__turboHotkeysRows
    if not slot then
      slot = {}
      BindingsMenu.__turboHotkeysRows = slot
      local orig = BindingsMenu.new
      BindingsMenu.new = function(game, ...)
        local menu = orig(game, ...)
        if slot.decorate then pcall(slot.decorate, menu, game) end
        return menu
      end
    end
    slot.decorate = decorate
  end

  ----------------------------------------------------------------------
  -- 4. Turbo.
  --
  -- input.step runs immediately before Input:step promotes queued edges, so
  -- a tap issued here is visible to this same logic tick -- identical
  -- latency to a physical press, which is the whole point.  The counter is
  -- parked at the period on release so the first held step fires at once
  -- rather than after a delay.
  ----------------------------------------------------------------------
  local countA, countB = 1, 1

  mod.hooks:wrap("input.step", function(nextFn, game, dt)
    local input = game and game.input
    if input and type(input.isDown) == "function"
        and optBool(mod, "turbo_enabled", true) then
      local period = ratePeriod(mod)

      if input:isDown("turbo_a") then
        countA = countA + 1
        if countA >= period then
          countA = 0
          pcall(function() mod.input:tap(game, "a") end)
        end
      else
        countA = period
      end

      if input:isDown("turbo_b") then
        countB = countB + 1
        if countB >= period then
          countB = 0
          pcall(function() mod.input:tap(game, "b") end)
        end
      else
        countB = period
      end
    end
    return nextFn(game, dt)
  end)

  ----------------------------------------------------------------------
  -- 5. Save and load.
  --
  -- Edges are derived from isDown rather than wasPressed: isDown is set by
  -- the real event the instant it arrives, so this needs no assumption about
  -- where in the step cycle the frame poll happens to sit.  The work runs
  -- after nextFn, once the frame's logic has finished, because restoreSave
  -- rebuilds the stack and must not do so mid-update.
  ----------------------------------------------------------------------
  local prevSave, prevLoad = false, false
  local loadHeld = 0

  local function doSave(game)
    if not (game and game.writeSave) then return end
    local ok = pcall(function() game:writeSave() end)
    toast(ok and "GAME SAVED" or "SAVE FAILED")
    if not ok then mod.log:warn("writeSave failed") end
  end

  local function doLoad(game)
    if not (SaveData and SaveData.load and game and game.restoreSave) then return end
    local ok, loaded, recovered = pcall(function()
      return SaveData.load()
    end)
    if not ok or not loaded then
      toast("NO SAVE FOUND")
      return
    end
    local restored = pcall(function()
      game:restoreSave(loaded, recovered, { freshBoot = true })
    end)
    toast(restored and "GAME LOADED" or "LOAD FAILED")
    if not restored then mod.log:warn("restoreSave failed") end
    prevSave, prevLoad, loadHeld = false, false, 0
  end

  -- Nothing else calls applyBindings until the CONTROLS screen is closed, so
  -- without this the SWAP A/B toggle would sit inert until then.  Watching the
  -- value costs one table read a frame and makes the option immediate.
  local lastSwap = optBool(mod, "swap_ab", true)

  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    nextFn(game, dt)

    local nowSwap = optBool(mod, "swap_ab", true)
    if nowSwap ~= lastSwap then
      lastSwap = nowSwap
      if Input and Input.applyBindings then
        pcall(function() Input:applyBindings(bindingsOf(game)) end)
      end
    end

    if toastLeft > 0 then
      toastLeft = toastLeft - (dt or 0)
      if toastLeft <= 0 then toastText = nil end
    end

    local input = game and game.input
    if not (input and type(input.isDown) == "function") then return end
    if not optBool(mod, "state_keys", true) then
      prevSave, prevLoad, loadHeld = false, false, 0
      return
    end

    local saveDown = input:isDown("state_save")
    if saveDown and not prevSave then doSave(game) end
    prevSave = saveDown

    local loadDown = input:isDown("state_load")
    if optBool(mod, "hold_to_load", false) then
      if loadDown then
        loadHeld = loadHeld + (dt or 0)
        if loadHeld >= HOLD_TO_LOAD_SECONDS and not prevLoad then
          prevLoad = true
          doLoad(game)
        end
      else
        loadHeld, prevLoad = 0, false
      end
    else
      if loadDown and not prevLoad then doLoad(game) end
      prevLoad = loadDown
    end
  end)

  ----------------------------------------------------------------------
  -- 6. The confirmation message, in LOVE window units like every other
  -- render.hud overlay in this collection.
  ----------------------------------------------------------------------
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    nextFn(game, viewport)
    if not toastText or toastLeft <= 0 then return end
    pcall(function()
      local w, h = love.graphics.getDimensions()
      local s = math.max(1, math.floor(h / 240))
      local fade = math.min(1, toastLeft / 0.4)
      love.graphics.setColor(0, 0, 0, 0.72 * fade)
      love.graphics.rectangle("fill", 0, h - 26 * s, w, 20 * s)
      love.graphics.setColor(1, 1, 1, fade)
      love.graphics.printf(toastText, 0, h - 21 * s, w / s, "center", 0, s, s)
      love.graphics.setColor(1, 1, 1, 1)
    end)
  end)

  ----------------------------------------------------------------------
  -- 7. Take effect without a restart.  The engine applied bindings at boot,
  -- before this mod patched applyBindings, so the defaults above are not in
  -- the live map yet.  BindingsMenu:commitBindings re-applies on close from
  -- then on.
  ----------------------------------------------------------------------
  mod.events:on("game.ready", function(ev)
    local game = ev and ev.game
    if not (game and Input and Input.applyBindings) then return end
    pcall(function() Input:applyBindings(bindingsOf(game)) end)
  end)

  mod.exports.apiVersion = 1
  mod.exports.rows = ROWS
  mod.exports.isTurboHeld = function(game, which)
    local input = game and game.input
    if not (input and type(input.isDown) == "function") then return false end
    return input:isDown(which == "b" and "turbo_b" or "turbo_a")
  end

  mod.log:info("turbo A/B + save/load rows added to CONTROLS (rate=%d shoulders=%s swap_ab=%s)",
    ratePeriod(mod), tostring(optBool(mod, "free_shoulders", true)),
    tostring(optBool(mod, "swap_ab", true)))
end
