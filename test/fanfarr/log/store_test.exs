defmodule Fanfarr.Log.StoreTest do
  @moduledoc """
  The log as written down, which is the half that survives a restart.
  """
  use Fanfarr.DataCase, async: false

  require Logger

  alias Fanfarr.Log.Store

  setup do
    Fanfarr.Log.Buffer.clear()
    Store.clear()

    # Restored between tests: the store keeps it in process state, so a test
    # that changes it would otherwise change every test after it.
    retention = Store.retention()
    on_exit(fn -> Store.put_retention(retention) end)

    :ok
  end

  defp settle do
    Fanfarr.Log.Buffer.entries(limit: 1)
    Store.flush()
  end

  defp append(message, opts \\ []) do
    Store.append(%{
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      level: Keyword.get(opts, :level, :error),
      message: message,
      where: Keyword.get(opts, :where, "Fanfarr.Thing.do_it/1")
    })

    Store.flush()
  end

  describe "persisting" do
    test "a logged line is written down, not just held in memory" do
      Logger.error("a line worth keeping after a restart")
      settle()

      assert [entry | _] = Store.entries(level: :error)
      assert entry.message =~ "a line worth keeping after a restart"
      assert entry.level == :error
    end

    test "entries come back newest first" do
      append("first")
      append("second")

      assert [%{message: "second"}, %{message: "first"}] = Store.entries(level: :debug)
    end

    test "it survives the process that wrote it" do
      # The point of the whole module: the in-memory ring is gone on restart,
      # and this is what is still there.
      append("written before the restart")
      Fanfarr.Log.Buffer.clear()

      assert Fanfarr.Log.Buffer.entries(limit: 10) == []
      assert [%{message: "written before the restart"}] = Store.entries(level: :debug)
    end

    test "what is written is what the console shows, redaction included" do
      # The buffer redacts on capture and forwards the redacted entry, so a
      # secret cannot reach the table by a path the console does not take.
      Fanfarr.Diagnostics.Redactor.remember("super-secret-plex-token")
      on_exit(&Fanfarr.Diagnostics.Redactor.forget_all/0)

      Logger.error("connecting with super-secret-plex-token")
      settle()

      [entry | _] = Store.entries(level: :error)
      refute entry.message =~ "super-secret-plex-token"
    end
  end

  describe "filtering" do
    test "level keeps entries at or above a severity" do
      append("a debug line", level: :debug)
      append("an error line", level: :error)

      assert [%{message: "an error line"}] = Store.entries(level: :error)
      assert length(Store.entries(level: :debug)) == 2
    end

    test "a text search reaches the message and the module that logged it" do
      append("nothing to see", where: "Fanfarr.Plex.HTTPClient.items/2")
      append("a distinctive phrase", where: "Fanfarr.Other.thing/0")

      assert [%{message: "a distinctive phrase"}] = Store.entries(query: "distinctive")
      assert [%{message: "nothing to see"}] = Store.entries(query: "HTTPClient")
    end

    test "a search reaches past what the page would render" do
      # The reason the filters are in SQL rather than over the rendered rows:
      # the needle here is older than any window the console shows.
      append("the needle")
      for n <- 1..30, do: append("filler #{n}")

      assert [%{message: "the needle"}] = Store.entries(query: "needle", limit: 5)
    end

    test "a search for a percent sign is not a search for everything" do
      append("normalised to 100% of target")
      append("something else entirely")

      assert [%{message: "normalised to 100% of target"}] = Store.entries(query: "100%")
    end

    test "counts describe the whole store, by level" do
      append("one", level: :error)
      append("two", level: :error)
      append("three", level: :info)

      assert %{error: 2, info: 1} = Store.counts()
    end
  end

  describe "retention" do
    test "defaults to five thousand" do
      assert Store.retention() == 5_000
    end

    test "the oldest are dropped once the cap is passed" do
      assert :ok = Store.put_retention("100")

      for n <- 1..120, do: append("line #{n}")

      entries = Store.entries(level: :debug, limit: 500)

      assert length(entries) == 100
      assert hd(entries).message == "line 120"
      refute Enum.any?(entries, &(&1.message == "line 1"))
    end

    test "lowering it trims what is already there, without waiting for a write" do
      assert :ok = Store.put_retention("200")
      for n <- 1..150, do: append("line #{n}")

      assert :ok = Store.put_retention("100")

      assert length(Store.entries(level: :debug, limit: 500)) == 100
    end

    test "a value outside the range is refused rather than clamped silently" do
      assert {:error, :invalid} = Store.put_retention("0")
      assert {:error, :invalid} = Store.put_retention("99")
      assert {:error, :invalid} = Store.put_retention("10000000")
      assert {:error, :invalid} = Store.put_retention("some")

      assert Store.retention() == 5_000
    end

    test "it is remembered across a restart of the store" do
      assert :ok = Store.put_retention("250")

      # What a container restart does: the process goes, the setting does not.
      pid = Process.whereis(Store)
      Supervisor.terminate_child(Fanfarr.Supervisor, Store)
      Supervisor.restart_child(Fanfarr.Supervisor, Store)
      refute Process.whereis(Store) == pid

      assert Store.retention() == 250
    end
  end

  describe "clearing" do
    test "the operator's own button empties it" do
      append("something")
      refute Store.entries(level: :debug) == []

      assert :ok = Store.clear()

      assert Store.entries(level: :debug) == []
      assert Store.counts() == %{}
    end

    test "anything queued but not yet written goes too" do
      # Otherwise the next flush repopulates the console a second after the
      # button was pressed, and the button looks broken.
      Store.append(%{at: DateTime.utc_now(), level: :error, message: "pending", where: nil})

      assert :ok = Store.clear()
      assert :ok = Store.flush()

      assert Store.entries(level: :debug) == []
    end
  end

  describe "not feeding itself" do
    test "writing the log does not write more log" do
      # The failure this guards is not a crash: every query Ecto runs is
      # logged, that line is captured, and capturing it queues another write.
      # One flush would guarantee the next one had work, forever. Every
      # database call in the store passes log: false so a flush produces no
      # log lines at all.
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      append("one real line")
      before = length(Store.entries(level: :debug, limit: 500))

      # Three flushes with nothing new logged in between. If a flush logged,
      # each of these would find work and the count would climb.
      for _ <- 1..3, do: settle()

      assert length(Store.entries(level: :debug, limit: 500)) == before
    end

    test "reading the log does not write log either" do
      # The console tails every second; a read that logged would fill the
      # store with the console reading the store.
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      append("one real line")
      before = length(Store.entries(level: :debug, limit: 500))

      for _ <- 1..5 do
        Store.entries(level: :debug, limit: 500)
        Store.counts()
      end

      settle()

      assert length(Store.entries(level: :debug, limit: 500)) == before
    end
  end
end
