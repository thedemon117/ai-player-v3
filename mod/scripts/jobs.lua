-- Sequential job queue (v3). queue_jobs runs a list of skill entries one after
-- another from on_tick, so a plan survives across turns (and ignores the
-- autonomy gate, like walking): "gather wood, goto the patch, build_plan, ...".
--
-- Skills here are one call each, and several answer "out of reach — walking to X,
-- call me again". The runner honours that: while a walk or drive is in progress
-- it waits; once it ends it re-runs the same entry, until the skill stops asking
-- (up to MAX_RUNS attempts) or the walk fails. A failed entry stops the queue
-- (on_fail = "stop", default) or is skipped (on_fail = "continue").
-- Entries: {skill=..., ...params} | {action=..., ...} | {wait = seconds}.
--
-- Lighter than the source repo's per-companion task lanes (scripts/tasks.lua):
-- one lane for the one AI character, no per-action tick machines — those exist
-- here as skills and as the async walk/drive state machines.

AIJobs = {}

local MAX_STEPS = 50
local MAX_RUNS  = 25
local KEEP_DONE = 20

local function root()
  storage.ai_player.jobs = storage.ai_player.jobs or {queue = {}, done = {}}
  return storage.ai_player.jobs
end

local function describe(entry)
  if entry.wait then return "wait " .. tostring(entry.wait) .. "s" end
  return tostring(entry.skill or entry.action or "?")
end

local function record(j, cur, ok, detail)
  local row = {job = describe(cur.entry), ok = ok, detail = detail, runs = cur.runs, tick = game.tick}
  table.insert(j.done, row)
  while #j.done > KEEP_DONE do table.remove(j.done, 1) end
  local mem = storage.ai_player.memory
  if mem then
    mem.last_action_results = mem.last_action_results or {}
    table.insert(mem.last_action_results, {action = "job:" .. row.job, ok = ok, detail = detail})
  end
end

-- Returns (ok, detail). `steps` is a list of entries.
function AIJobs.enqueue(steps, on_fail)
  if type(steps) ~= "table" or #steps == 0 then
    return false, 'queue_jobs: give steps = [{"skill":"gather","item":"coal","count":20}, {"skill":"goto",...}, {"wait":5}]'
  end
  if #steps > MAX_STEPS then return false, "queue_jobs: at most " .. MAX_STEPS .. " steps" end
  for i, e in ipairs(steps) do
    if type(e) ~= "table" or not (e.skill or e.action or tonumber(e.wait)) then
      return false, "queue_jobs: step " .. i .. " needs skill, action or wait"
    end
    if e.skill == "queue_jobs" or e.skill == "cancel_jobs" then
      return false, "queue_jobs: step " .. i .. " can't be a queue command"
    end
    if e.skill and not AISkills.REGISTRY[e.skill] then
      return false, "queue_jobs: step " .. i .. " names an unknown skill '" .. tostring(e.skill) .. "'"
    end
  end
  local j = root()
  j.on_fail = (on_fail == "continue") and "continue" or "stop"
  for _, e in ipairs(steps) do
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    j.queue[#j.queue + 1] = {entry = copy, runs = 0}
  end
  return true, string.format("queued %d step(s) (%d waiting in total); outcomes arrive in your action results, job_status shows progress",
    #steps, #j.queue + (j.current and 1 or 0))
end

function AIJobs.status()
  local j = root()
  local queue = {}
  for _, c in ipairs(j.queue) do queue[#queue + 1] = describe(c.entry) end
  return {current = j.current and describe(j.current.entry) or nil, runs = j.current and j.current.runs or nil,
          queued = queue, done = j.done, on_fail = j.on_fail}
end

function AIJobs.cancel(character)
  local j = root()
  local n = #j.queue + (j.current and 1 or 0)
  j.queue, j.current = {}, nil
  if AIMovement.status() and character and character.valid then AIMovement.cancel(character) end
  return n
end

local function fail(j, cur, detail)
  record(j, cur, false, detail)
  j.current = nil
  if j.on_fail == "stop" then
    local n = #j.queue
    j.queue = {}
    if n > 0 then record(j, {entry = {skill = "queue"}, runs = 0}, false, "stopped: " .. n .. " later step(s) dropped") end
  end
end

-- Called every tick from on_tick, independent of the autonomy gate.
function AIJobs.step()
  local ai = storage.ai_player
  local j = ai and ai.jobs
  if not j or (not j.current and #j.queue == 0) then return end
  local character = AICharacter.get_character()
  if not character then return end
  if ai.walk or ai.drive then return end   -- wait for the async job in progress

  local cur = j.current
  if not cur then cur = table.remove(j.queue, 1); j.current = cur end

  if cur.wait_until then
    if game.tick < cur.wait_until then return end
    record(j, cur, true, "waited " .. tostring(cur.entry.wait) .. "s")
    j.current = nil
    return
  end
  if tonumber(cur.entry.wait) then
    cur.wait_until = game.tick + math.floor(tonumber(cur.entry.wait) * 60)
    return
  end

  if cur.retry_at and game.tick < cur.retry_at then return end
  -- The skill started a walk or drive and did not ask to be re-run: it is done
  -- when that ends, and only a walk that arrived / a car that parked counts.
  if cur.awaiting then
    local wr, dr = ai.walk_result, ai.drive_result
    if wr and cur.walked and wr.tick >= cur.run_tick and wr.status ~= "arrived" then
      return fail(j, cur, string.format("the walk ended '%s' at (%.0f, %.0f) — %s", wr.status,
        wr.pos and wr.pos.x or 0, wr.pos and wr.pos.y or 0, cur.last_detail))
    end
    if dr and cur.drove and dr.tick >= cur.run_tick and dr.status ~= "parked" then
      return fail(j, cur, dr.detail or "the drive failed")
    end
    record(j, cur, true, cur.last_detail .. " — finished")
    j.current = nil
    return
  end
  -- A walk that just ended badly means the retry would only walk into the same wall.
  local wr = ai.walk_result
  if cur.again and wr and cur.run_tick and wr.tick >= cur.run_tick and wr.status ~= "arrived" then
    return fail(j, cur, string.format("the walk it needed ended '%s' at tick %d", wr.status, wr.tick))
  end
  if cur.runs >= MAX_RUNS then
    return fail(j, cur, "gave up after " .. MAX_RUNS .. " attempts (still asking to be called again)")
  end

  cur.runs = cur.runs + 1
  cur.run_tick = game.tick
  local copy = {}
  for k, v in pairs(cur.entry) do copy[k] = v end
  local ok, detail = AISkills.run(character, copy)
  detail = detail or ""
  -- "...call X again", "...retry next turn", "...again to continue" = not finished, a walk was started
  local busy = ai.walk ~= nil or ai.drive ~= nil
  local asks = detail:find("again") ~= nil or detail:find("retry") ~= nil
  cur.again = busy and (asks or not ok) or false
  if busy and ok and not asks then
    cur.awaiting, cur.last_detail = true, detail
    cur.walked, cur.drove = ai.walk ~= nil, ai.drive ~= nil
    return
  end
  if cur.again then return end
  -- asks to be called again without a walk (e.g. a rocket still rising): try again shortly
  if detail:find("call %S+ again") then cur.retry_at = game.tick + 120; return end
  if ok then
    record(j, cur, true, detail)
    j.current = nil
  else
    fail(j, cur, detail)
  end
end

return AIJobs
