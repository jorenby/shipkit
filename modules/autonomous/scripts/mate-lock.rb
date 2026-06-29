#!/usr/bin/env ruby
# frozen_string_literal: true

# mate-lock.rb — Mate session lock: acquire/heartbeat/release/status.
#
# Prevents concurrent queue.md writes when multiple Mate sessions could overlap.
# Lock file: state/mate-lock.json  {session_id, acquired_at, heartbeat_at}
#
# Subcommands:
#   acquire  SESSION_ID  — take the lock; fails if held by a fresh session.
#                          Succeeds with TAKEOVER if lock is stale (>STALE_MINUTES).
#   heartbeat SESSION_ID — stamp heartbeat_at; fails if session doesn't hold the lock.
#   release  SESSION_ID  — release the lock; fails if session doesn't hold it.
#   release  SESSION_ID --force — release unconditionally (prints a warning).
#   status               — print lock state and exit 0 (free or mine) / 1 (held-fresh by other).
#   status   --json      — same, machine-readable JSON.
#
# Atomic writes: tmp file + rename (POSIX atomic on same filesystem).
#
# Usage:
#   ruby scripts/mate-lock.rb acquire   <session_id>
#   ruby scripts/mate-lock.rb heartbeat <session_id>
#   ruby scripts/mate-lock.rb release   <session_id> [--force]
#   ruby scripts/mate-lock.rb status    [--json]
#
# Environment overrides (for testing):
#   LOCK_FILE=/tmp/test-lock.json ruby scripts/mate-lock.rb ...
#   STALE_MINUTES=1 ruby scripts/mate-lock.rb ...

require "json"
require "time"
require "fileutils"
require "securerandom"

ROOT      = File.expand_path("../../..", __dir__)
LOCK_FILE = ENV.fetch("LOCK_FILE", File.join(ROOT, "state", "mate-lock.json"))
STALE_MINUTES = (ENV["STALE_MINUTES"] || "45").to_i

def now_iso
  Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
end

def read_lock
  return nil unless File.file?(LOCK_FILE)

  JSON.parse(File.read(LOCK_FILE))
rescue JSON::ParserError
  nil
end

def write_lock(data)
  tmp = "#{LOCK_FILE}.tmp.#{Process.pid}"
  File.write(tmp, JSON.generate(data))
  File.rename(tmp, LOCK_FILE)
end

def delete_lock
  File.delete(LOCK_FILE) if File.file?(LOCK_FILE)
end

def stale?(lock)
  return true if lock.nil?

  hb = lock["heartbeat_at"] || lock["acquired_at"]
  return true if hb.nil?

  age_minutes = (Time.now.utc - Time.parse(hb)) / 60.0
  age_minutes > STALE_MINUTES
rescue ArgumentError
  true
end

def age_string(ts_str)
  return "unknown" if ts_str.nil?

  age_minutes = (Time.now.utc - Time.parse(ts_str)) / 60.0
  if age_minutes < 60
    "#{age_minutes.round}m"
  else
    "#{(age_minutes / 60.0).round(1)}h"
  end
rescue ArgumentError
  "unknown"
end

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_acquire(session_id)
  if session_id.nil? || session_id.empty?
    warn "ERROR: acquire requires a session_id argument"
    exit 2
  end

  lock = read_lock

  if lock.nil?
    # Free — acquire fresh.
    write_lock({
      "session_id"   => session_id,
      "acquired_at"  => now_iso,
      "heartbeat_at" => now_iso
    })
    puts "ACQUIRED #{session_id}"
    exit 0
  end

  if lock["session_id"] == session_id
    # Re-entrant — already ours; refresh heartbeat.
    lock["heartbeat_at"] = now_iso
    write_lock(lock)
    puts "ACQUIRED (re-entrant) #{session_id}"
    exit 0
  end

  if stale?(lock)
    old_id  = lock["session_id"]
    hb      = lock["heartbeat_at"] || lock["acquired_at"]
    age_str = age_string(hb)
    write_lock({
      "session_id"   => session_id,
      "acquired_at"  => now_iso,
      "heartbeat_at" => now_iso
    })
    puts "TAKEOVER — prior session #{old_id} last heartbeat #{age_str} ago (>#{STALE_MINUTES}m stale)"
    puts "ACQUIRED #{session_id}"
    exit 0
  end

  # Held fresh by another session.
  hb      = lock["heartbeat_at"] || lock["acquired_at"]
  age_str = age_string(hb)
  warn "LOCK HELD by session #{lock['session_id']} (heartbeat #{age_str} ago — fresh)"
  warn "Cannot acquire. If the prior session is truly dead, wait #{STALE_MINUTES}m for stale-takeover."
  exit 1
end

def cmd_heartbeat(session_id)
  if session_id.nil? || session_id.empty?
    warn "ERROR: heartbeat requires a session_id argument"
    exit 2
  end

  lock = read_lock

  if lock.nil?
    warn "ERROR: no lock held — cannot heartbeat session #{session_id}"
    exit 1
  end

  unless lock["session_id"] == session_id
    warn "ERROR: lock held by #{lock['session_id']}, not #{session_id} — cannot heartbeat"
    exit 1
  end

  lock["heartbeat_at"] = now_iso
  write_lock(lock)
  puts "HEARTBEAT #{session_id} at #{lock['heartbeat_at']}"
  exit 0
end

def cmd_release(session_id, force:)
  if session_id.nil? || session_id.empty?
    warn "ERROR: release requires a session_id argument"
    exit 2
  end

  lock = read_lock

  if lock.nil?
    puts "RELEASED (was already free)"
    exit 0
  end

  if lock["session_id"] == session_id
    delete_lock
    puts "RELEASED #{session_id}"
    exit 0
  end

  if force
    warn "WARNING: --force releasing lock held by #{lock['session_id']} (you are #{session_id})"
    delete_lock
    puts "RELEASED (forced) by #{session_id}"
    exit 0
  end

  warn "ERROR: lock held by #{lock['session_id']}, not #{session_id}"
  warn "Use --force to override (prints a warning)."
  exit 1
end

def cmd_status(json_output:)
  lock = read_lock

  if lock.nil?
    if json_output
      puts JSON.generate({ "state" => "free", "holder" => nil, "age" => nil, "fresh" => false })
    else
      puts "STATE: free"
      puts "No lock held."
    end
    exit 0
  end

  hb      = lock["heartbeat_at"] || lock["acquired_at"]
  age_str = age_string(hb)
  fresh   = !stale?(lock)

  if json_output
    puts JSON.generate({
      "state"        => "held",
      "holder"       => lock["session_id"],
      "acquired_at"  => lock["acquired_at"],
      "heartbeat_at" => lock["heartbeat_at"],
      "age"          => age_str,
      "fresh"        => fresh,
      "stale_minutes" => STALE_MINUTES
    })
  else
    puts "STATE: held"
    puts "Holder:       #{lock['session_id']}"
    puts "Acquired:     #{lock['acquired_at']}"
    puts "Last beat:    #{lock['heartbeat_at']} (#{age_str} ago)"
    puts "Freshness:    #{fresh ? "FRESH (<#{STALE_MINUTES}m)" : "STALE (>#{STALE_MINUTES}m)"}"
  end

  # Exit 1 if held-fresh by some session (caller can't infer "mine" without knowing their id).
  # Exit 0 if free or stale (takeover possible).
  if fresh
    exit 1
  else
    exit 0
  end
end

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

subcmd    = ARGV[0]
arg1      = ARGV[1]
flags     = ARGV[2..] || []
force     = flags.include?("--force")
json_flag = (arg1 == "--json") || flags.include?("--json")

case subcmd
when "acquire"
  cmd_acquire(arg1)
when "heartbeat"
  cmd_heartbeat(arg1)
when "release"
  cmd_release(arg1, force: force)
when "status"
  cmd_status(json_output: json_flag)
else
  warn "Usage: ruby scripts/mate-lock.rb <acquire|heartbeat|release|status> [session_id] [--force] [--json]"
  exit 2
end
