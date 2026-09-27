defmodule Fanfarr.NotifyTest do
  @moduledoc """
  Notifications: the shape each style sends, the switch per type, and the rule
  that delivery never fails the work that prompted it.

  Requests are served through a stub, and the health case makes its request from
  the monitor's process rather than this one, so the stub replies to a captured
  pid instead of to `self()`.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Notify

  setup do
    Req.Test.set_req_test_to_shared(%{})

    test_pid = self()

    Req.Test.stub(Fanfarr.NotifyReq, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:notified, conn, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    # The health checks probe Plex and ThemerrDB as well; without this the
    # monitor's own probe raises and the case stops being about notifications.
    Req.Test.stub(Fanfarr.PlexReq, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    Fanfarr.Settings.put_setting!("notify_url", "http://ntfy.test/fanfarr")
    :ok
  end

  defp received do
    receive do
      {:notified, conn, body} -> {conn, body}
    after
      500 -> :nothing
    end
  end

  describe "payload shapes" do
    test "ntfy gets plain text and a title header" do
      Fanfarr.Settings.put_setting!("notify_style", "ntfy")

      assert :ok = Notify.send(:job_failures, "A job gave up", "because reasons")

      {conn, body} = received()
      assert body == "because reasons"
      assert Plug.Conn.get_req_header(conn, "title") == ["A job gave up"]
      assert Plug.Conn.get_req_header(conn, "priority") == ["default"]
    end

    test "an error is sent at high priority to ntfy" do
      Fanfarr.Settings.put_setting!("notify_style", "ntfy")

      assert :ok = Notify.send(:backups, "T", "B", level: :error)

      {conn, _body} = received()
      assert Plug.Conn.get_req_header(conn, "priority") == ["high"]
    end

    test "discord and slack each get their own field" do
      Fanfarr.Settings.put_setting!("notify_style", "discord")
      assert :ok = Notify.send(:job_failures, "Title", "Body")
      assert {_conn, body} = received()
      assert Jason.decode!(body) == %{"content" => "Title\nBody"}

      Fanfarr.Settings.put_setting!("notify_style", "slack")
      assert :ok = Notify.send(:job_failures, "Title", "Body")
      assert {_conn, body} = received()
      assert Jason.decode!(body) == %{"text" => "*Title*\nBody"}
    end

    test "the generic shape carries the level and the version" do
      Fanfarr.Settings.put_setting!("notify_style", "json")

      assert :ok = Notify.send(:health, "Title", "Body", level: :error)

      {conn, body} = received()
      decoded = Jason.decode!(body)
      assert decoded["title"] == "Title"
      assert decoded["message"] == "Body"
      assert decoded["level"] == "error"
      assert decoded["source"] == "fanfarr"
      assert decoded["version"] =~ ~r/\d+\.\d+\.\d+/
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    end

    test "an unknown style falls back rather than sending nothing" do
      Fanfarr.Settings.put_setting!("notify_style", "carrier-pigeon")

      assert Notify.style() == "ntfy"
      assert :ok = Notify.send(:job_failures, "T", "B")
      assert {_conn, "B"} = received()
    end
  end

  describe "switches" do
    test "no URL means off, and the send is skipped rather than attempted" do
      Fanfarr.Settings.put_setting!("notify_url", "")

      refute Notify.enabled?()
      assert Notify.send(:job_failures, "T", "B") == :skipped
      assert received() == :nothing
    end

    test "a type that is off is skipped, one that is on is not" do
      Fanfarr.Settings.put_setting!("notify_sync", "false")

      assert Notify.send(:sync, "T", "B") == :skipped
      assert received() == :nothing

      assert Notify.send(:job_failures, "T", "B") == :ok
      assert {_conn, _body} = received()
    end

    test "the routine one is off unless asked for, the failures are on" do
      # No setting rows at all: the defaults are what count.
      refute Notify.enabled?(:sync)
      assert Notify.enabled?(:job_failures)
      assert Notify.enabled?(:health)
      assert Notify.enabled?(:backups)
    end

    test "every type has a switch, a label and a setting key" do
      assert length(Notify.types()) == 4

      for type <- Notify.types() do
        assert is_binary(type.setting)
        assert is_binary(type.label)
        assert is_boolean(type.default)
      end
    end

    test "a test notification ignores the switches" do
      for type <- Notify.types(), do: Fanfarr.Settings.put_setting!(type.setting, "false")

      assert :ok = Notify.test()
      assert {_conn, body} = received()
      assert body =~ "notifications are set up"
    end

    test "a test with no URL says so rather than sending" do
      Fanfarr.Settings.put_setting!("notify_url", "")

      assert {:error, :no_url} = Notify.test()
      assert received() == :nothing
    end
  end

  describe "delivery never fails the work" do
    test "a rejection is returned, not raised" do
      Req.Test.stub(Fanfarr.NotifyReq, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, {:status, 500}} = Notify.send(:job_failures, "T", "B")
    end

    test "an unreachable endpoint is returned, not raised" do
      Req.Test.stub(Fanfarr.NotifyReq, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} = Notify.send(:job_failures, "T", "B")
    end
  end

  describe "a job that gave up" do
    test "notifies with the error it died on" do
      job = %Oban.Job{
        worker: "Fanfarr.Workers.ApplyTheme",
        args: %{"media_item_id" => "abc"},
        max_attempts: 3,
        errors: [%{"attempt" => 3, "error" => "yt-dlp exited 1"}]
      }

      assert :ok =
               Notify.handle_oban([:oban, :job, :stop], %{}, %{job: job, state: :discarded}, nil)

      assert {_conn, body} = received()
      assert body =~ "Apply theme"
      assert body =~ "yt-dlp exited 1"
    end

    test "stays quiet for one that succeeded, and one that will be retried" do
      job = %Oban.Job{
        worker: "Fanfarr.Workers.ApplyTheme",
        args: %{},
        max_attempts: 3,
        errors: []
      }

      assert :skipped =
               Notify.handle_oban([:oban, :job, :stop], %{}, %{job: job, state: :completed}, nil)

      assert :skipped =
               Notify.handle_oban([:oban, :job, :stop], %{}, %{job: job, state: :retryable}, nil)

      assert received() == :nothing
    end
  end

  describe "health" do
    test "notifies on the way into failure, and not again while it stays there" do
      error = %{id: :plex, name: "Plex", level: :error, message: "Not configured", detail: nil}
      fine = %{id: :plex, name: "Plex", level: :ok, message: "Connected", detail: nil}

      # No snapshot yet counts as a transition: the first thing an operator
      # should hear about is the state, not the change.
      assert :ok = Notify.notify_transition(nil, %{results: [error]})
      assert {conn, body} = received()
      assert Plug.Conn.get_req_header(conn, "title") == ["1 health check(s) failing"]
      assert body =~ "Plex: Not configured"

      # Already failing, and the point is that it says nothing this time.
      assert :skipped = Notify.notify_transition(%{results: [error]}, %{results: [error]})
      assert received() == :nothing

      # Recovering is not a notification either: the switch is about failures.
      assert :skipped = Notify.notify_transition(%{results: [error]}, %{results: [fine]})
      assert received() == :nothing
    end

    test "a warning is not a failure" do
      warning = %{id: :ffmpeg, name: "ffmpeg", level: :warning, message: "Slow", detail: nil}

      assert :skipped = Notify.notify_transition(nil, %{results: [warning]})
      assert received() == :nothing
    end
  end
end
