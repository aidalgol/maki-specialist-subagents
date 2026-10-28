-- Test helper compatible with maki.test_helpers (case/eq/has/report). Uses
-- the real helper when running inside maki; otherwise a local stand-in so
-- `lua spec/run.lua` works outside the host.

local ok, th = pcall(require, "maki.test_helpers")
if ok and th and th.case and th.report then
  return th
end

local H = { failures = {}, count = 0 }

local function type_name(v)
  if type(v) == "table" then
    return "table"
  end
  return tostring(v)
end

local function deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local seen = {}
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
    seen[k] = true
  end
  for k in pairs(b) do
    if not seen[k] then
      return false
    end
  end
  return true
end

function H.case(name, fn)
  H.count = H.count + 1
  local ok_run, err = pcall(fn)
  if not ok_run then
    H.failures[#H.failures + 1] = name .. ": " .. tostring(err)
  end
end

function H.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error(string.format("%s: expected %s, got %s",
      msg or "eq", type_name(expected) .. " " .. tostring(expected),
      type_name(actual) .. " " .. tostring(actual)), 2)
  end
end

function H.has(s, substr, msg)
  if type(s) ~= "string" or not s:find(substr, 1, true) then
    error(string.format("%s: %r does not contain %q", msg or "has",
      tostring(s), tostring(substr)), 2)
  end
end

function H.truthy(v, msg)
  if not v then
    error(msg or "expected truthy", 2)
  end
end

function H.report()
  print(string.format("tests: %d, failures: %d", H.count, #H.failures))
  for _, f in ipairs(H.failures) do
    print("FAIL " .. f)
  end
  if #H.failures > 0 then
    error("test failures: " .. #H.failures)
  end
end

return H
