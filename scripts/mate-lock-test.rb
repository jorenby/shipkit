#!/usr/bin/env ruby
# frozen_string_literal: true

# mate-lock-test.rb — Scenario tests for mate-lock.rb.
#
# Simulates multiple session IDs; exercises all subcommands.
# Uses a temp lock file so it never touches the live lock.
#
# Run: ruby scripts/mate-lock-test.rb

require "json"
require "tempfile"
require "fileutils"

SCRIPT = File.expand_path("mate-lock.rb", __dir__)
PASS   = "\e[32mPASS\e[0m"
FAIL   = "\e[31mFAIL\e[0m"

failures = 0

def run_lock(lock_file, *args, stale_minutes: 45)
  env = { "LOCK_FILE" => lock_file, "STALE_MINUTES" => stale_minutes.to_s }
  stdout = IO.popen([env, "ruby", SCRIPT, *args.map(&:to_s)], err: %i[child out]) { |io| io.read }
  exit_code = $?.exitstatus
  [stdout.strip, exit_code]
end

def assert(label, condition, got, failures)
  if condition
    puts "  #{"\e[32mPASS\e[0m"} #{label}"
  else
    puts "  #{"\e[31mFAIL\e[0m"} #{label} — got: #{got.inspect}"
    failures << label
  end
end

LOCK_FILE = Tempfile.new(["mate-lock-test", ".json"]).path
FileUtils.rm_f(LOCK_FILE)

SESSION_A = "aaaa1111-0000-0000-0000-000000000001"
SESSION_B = "bbbb2222-0000-0000-0000-000000000002"

puts "=== mate-lock tests ==="
puts "Lock file: #{LOCK_FILE}"
puts

test_failures = []

# ---------------------------------------------------------------------------
# Scenario 1: acquire on a free lock
# ---------------------------------------------------------------------------
puts "Scenario 1: acquire-free"
FileUtils.rm_f(LOCK_FILE)
out, code = run_lock(LOCK_FILE, "acquire", SESSION_A)
assert("exit 0",     code == 0,               code,  test_failures)
assert("ACQUIRED",   out.include?("ACQUIRED"), out,   test_failures)
assert("lock exists", File.file?(LOCK_FILE),   false, test_failures)
data = JSON.parse(File.read(LOCK_FILE))
assert("session_id set", data["session_id"] == SESSION_A, data, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 2: acquire when held fresh by another session — must fail
# ---------------------------------------------------------------------------
puts "Scenario 2: acquire-held-fresh (should fail)"
out, code = run_lock(LOCK_FILE, "acquire", SESSION_B, stale_minutes: 45)
assert("exit 1",         code == 1,               code, test_failures)
assert("LOCK HELD",      out.include?("LOCK HELD") || out.include?("lock held") || out.include?("held"), out, test_failures)
assert("B not in file",  JSON.parse(File.read(LOCK_FILE))["session_id"] == SESSION_A, nil, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 3: heartbeat by holder
# ---------------------------------------------------------------------------
puts "Scenario 3: heartbeat by holder"
out, code = run_lock(LOCK_FILE, "heartbeat", SESSION_A)
assert("exit 0",      code == 0,                 code, test_failures)
assert("HEARTBEAT",   out.include?("HEARTBEAT"), out,  test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 4: heartbeat by wrong session — must fail
# ---------------------------------------------------------------------------
puts "Scenario 4: heartbeat by wrong session (should fail)"
out, code = run_lock(LOCK_FILE, "heartbeat", SESSION_B)
assert("exit 1",   code == 1, code, test_failures)
assert("ERROR msg", out.include?("ERROR"), out, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 5: acquire-held-stale-takeover (STALE_MINUTES=0 forces instant stale)
# ---------------------------------------------------------------------------
puts "Scenario 5: acquire-held-stale-takeover"
# Backdate heartbeat_at to 2 hours ago so stale check fires even without waiting.
lock_data = JSON.parse(File.read(LOCK_FILE))
lock_data["heartbeat_at"] = (Time.now.utc - 7200).strftime("%Y-%m-%dT%H:%M:%SZ")
lock_data["acquired_at"]  = lock_data["heartbeat_at"]
File.write(LOCK_FILE, JSON.generate(lock_data))

out, code = run_lock(LOCK_FILE, "acquire", SESSION_B)
assert("exit 0",         code == 0,                 code, test_failures)
assert("TAKEOVER",       out.include?("TAKEOVER"),   out,  test_failures)
assert("ACQUIRED B",     out.include?("ACQUIRED"),   out,  test_failures)
assert("B now holder",   JSON.parse(File.read(LOCK_FILE))["session_id"] == SESSION_B, nil, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 6: release by holder
# ---------------------------------------------------------------------------
puts "Scenario 6: release by holder"
out, code = run_lock(LOCK_FILE, "release", SESSION_B)
assert("exit 0",          code == 0,               code, test_failures)
assert("RELEASED",        out.include?("RELEASED"), out,  test_failures)
assert("file gone",       !File.file?(LOCK_FILE),   true, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 7: release by wrong session — must fail
# ---------------------------------------------------------------------------
puts "Scenario 7: release-wrong-session (should fail)"
FileUtils.rm_f(LOCK_FILE)
run_lock(LOCK_FILE, "acquire", SESSION_A)
out, code = run_lock(LOCK_FILE, "release", SESSION_B)
assert("exit 1",      code == 1,               code, test_failures)
assert("ERROR msg",   out.include?("ERROR") || out.include?("held"), out, test_failures)
assert("A still held", JSON.parse(File.read(LOCK_FILE))["session_id"] == SESSION_A, nil, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 8: release --force by wrong session (prints warning, succeeds)
# ---------------------------------------------------------------------------
puts "Scenario 8: release --force by wrong session"
out, code = run_lock(LOCK_FILE, "release", SESSION_B, "--force")
assert("exit 0",           code == 0,                 code, test_failures)
assert("WARNING",          out.include?("WARNING") || out.include?("force"), out, test_failures)
assert("RELEASED (forced)", out.include?("RELEASED"),  out,  test_failures)
assert("file gone",         !File.file?(LOCK_FILE),    true, test_failures)
puts

# ---------------------------------------------------------------------------
# Scenario 9: status when free
# ---------------------------------------------------------------------------
puts "Scenario 9: status free"
FileUtils.rm_f(LOCK_FILE)
out, code = run_lock(LOCK_FILE, "status")
assert("exit 0",   code == 0,              code, test_failures)
assert("free msg", out.include?("free"),   out,  test_failures)
puts

# Scenario 9b: status --json when free
out, code = run_lock(LOCK_FILE, "status", "--json")
assert("exit 0 json", code == 0, code, test_failures)
begin
  j = JSON.parse(out)
  assert("state=free", j["state"] == "free", j, test_failures)
rescue JSON::ParserError
  assert("valid json", false, out, test_failures)
end
puts

# ---------------------------------------------------------------------------
# Scenario 10: status when held (fresh)
# ---------------------------------------------------------------------------
puts "Scenario 10: status held-fresh"
run_lock(LOCK_FILE, "acquire", SESSION_A)
out, code = run_lock(LOCK_FILE, "status")
assert("exit 1 (held-fresh)", code == 1,                   code, test_failures)
assert("Holder shown",        out.include?(SESSION_A),      out,  test_failures)
assert("FRESH label",         out.include?("FRESH"),        out,  test_failures)

out_json, code_json = run_lock(LOCK_FILE, "status", "--json")
assert("json exit 1", code_json == 1, code_json, test_failures)
begin
  j = JSON.parse(out_json)
  assert("json state=held",  j["state"] == "held",   j, test_failures)
  assert("json fresh=true",  j["fresh"] == true,     j, test_failures)
  assert("json holder set",  j["holder"] == SESSION_A, j, test_failures)
rescue JSON::ParserError
  assert("valid json", false, out_json, test_failures)
end
puts

# ---------------------------------------------------------------------------
# Scenario 11: re-entrant acquire (same session, fresh lock)
# ---------------------------------------------------------------------------
puts "Scenario 11: re-entrant acquire"
out, code = run_lock(LOCK_FILE, "acquire", SESSION_A)
assert("exit 0",        code == 0,                    code, test_failures)
assert("re-entrant msg", out.include?("re-entrant"),   out,  test_failures)
puts

# Cleanup
FileUtils.rm_f(LOCK_FILE)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "=" * 40
if test_failures.empty?
  puts "\e[32mAll scenarios passed.\e[0m"
  exit 0
else
  puts "\e[31mFailed: #{test_failures.size} assertion(s)\e[0m"
  test_failures.each { |f| puts "  - #{f}" }
  exit 1
end
