defmodule Fanfarr.Log.BufferTest do
  use Fanfarr.DataCase, async: false

  require Logger

  alias Fanfarr.Diagnostics.Redactor
  alias Fanfarr.Log.Buffer

  setup do
    # The handler is attached by the application; these tests only need a
    # clean buffer.
    Buffer.clear()
    Redactor.forget_all()
    on_exit(fn -> Buffer.clear() end)
    :ok
  end

  # The handler casts from the logging process, so a call afterwards is the
  # barrier that guarantees the cast has been processed.
  defp settle, do: Buffer.entries(limit: 1)

  describe "events that defeat formatting" do
    test "a message with invalid UTF-8 is kept, not dropped" do
      # The redactor runs regexes, which raise on a binary that is not valid
      # UTF-8. This used to take the whole entry down silently -- and a crash
      # report carrying raw bytes is exactly the entry worth keeping.
      Logger.error(["broken: ", <<0xFF, 0xFE>>])
      settle()

      assert [entry | _] = Buffer.entries(level: :error)
      assert entry.level == :error
      assert entry.message =~ "broken"
      assert String.valid?(entry.message)
    end

    test "chardata that cannot be flattened still produces an entry" do
      :logger.log(:error, {:string, [:not_chardata, 1_114_112]}, %{})
      settle()

      assert [entry | _] = Buffer.entries(level: :error)
      assert entry.level == :error
      assert entry.message != ""
    end

    test "a report the formatter chokes on is degraded, and says so" do
      # A format string and arguments that do not line up: :io_lib.format/2
      # raises, and the entry must survive as something rather than nothing.
      :logger.log(:error, {"~ts ~ts", ["only one"]}, %{})
      settle()

      assert [entry | _] = Buffer.entries(level: :error)
      assert entry.level == :error
      assert entry.message != ""
    end
  end

  test "captures log lines, newest first" do
    Logger.error("first thing")
    Logger.error("second thing")
    settle()

    messages = Buffer.entries(level: :error) |> Enum.map(& &1.message)
    assert ["second thing", "first thing" | _] = messages
  end

  test "a secret in a log line never reaches the buffer" do
    Fanfarr.Settings.put_setting!("plex_token", "SECRET-TOKEN-abc123")
    Redactor.prime()

    Logger.error("calling plex with X-Plex-Token=SECRET-TOKEN-abc123")
    settle()

    [entry | _] = Buffer.entries(level: :error)
    refute entry.message =~ "SECRET-TOKEN-abc123"
    assert entry.message =~ "[redacted]"
  end

  test "filters by level" do
    Logger.warning("a warning here")
    Logger.error("an error here")
    settle()

    assert Buffer.entries(level: :error) |> Enum.all?(&(&1.level == :error))

    levels = Buffer.entries(level: :warning) |> Enum.map(& &1.level) |> Enum.uniq()
    assert :error in levels
    assert :warning in levels
  end

  test "entries carry a time and where they came from" do
    Logger.error("located")
    settle()

    [entry | _] = Buffer.entries(level: :error)
    assert %DateTime{} = entry.at
    assert entry.where =~ "BufferTest"
  end

  test "clear empties it" do
    Logger.error("gone soon")
    settle()
    refute Buffer.entries(level: :error) == []

    Buffer.clear()
    assert Buffer.entries(level: :error) == []
  end

  test "a report rather than a string is captured too" do
    Logger.error(fn -> "from a function" end)
    settle()

    assert Buffer.entries(level: :error) |> Enum.any?(&(&1.message =~ "from a function"))
  end
end
