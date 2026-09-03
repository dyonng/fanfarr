defmodule FanfarrWeb.SendFileTest do
  @moduledoc """
  `Phoenix.ConnTest` dispatches straight into the plug pipeline with no real
  socket or adapter involved, so it can never raise the
  `Bandit.TransportError` this module exists to catch. Proving the fix means
  putting a real Bandit listener in front of the actual endpoint and
  reproducing the abort over a real TCP socket, the same way the bug itself
  was first found.
  """
  use FanfarrWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Fanfarr.Repo, {:shared, self()})

    dir = Path.join(System.tmp_dir!(), "fanfarr-sendfile-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    content = String.duplicate("0123456789", 500_000)
    path = Path.join(dir, "theme.mp3")
    File.write!(path, content)

    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    item =
      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "One Pace",
        kind: :show
      })

    item =
      Fanfarr.Library.record_local_theme!(item, %{
        local_theme_present: true,
        local_theme_path: path
      })

    {:ok, bandit} =
      start_supervised({Bandit, plug: FanfarrWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{item: item, port: port, content: content}
  end

  test "a client that disconnects mid-stream logs as benign, not a crash", %{
    item: item,
    port: port
  } do
    # The test config's primary Logger level is :warning, which drops debug
    # events before they ever reach a handler -- capture_log's own :level
    # option only narrows what a handler sees, it can't loosen that ceiling.
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(fn ->
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        request =
          "GET /library/#{item.id}/theme HTTP/1.1\r\n" <>
            "Host: localhost\r\n" <>
            "Range: bytes=0-\r\n" <>
            "\r\n"

        :ok = :gen_tcp.send(socket, request)
        :ok = :gen_tcp.close(socket)

        # Give the acceptor process time to run the controller action and hit
        # the closed socket before the log is captured.
        Process.sleep(200)
      end)

    refute log =~ "[error]"
    refute log =~ "TransportError"
    assert log =~ "theme/poster stream interrupted, client gone"
  end

  test "the listener keeps serving other requests afterwards", %{
    item: item,
    port: port,
    content: content
  } do
    capture_log(fn ->
      {:ok, dead_socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok =
        :gen_tcp.send(dead_socket, "GET /library/#{item.id}/theme HTTP/1.1\r\nHost: x\r\n\r\n")

      :ok = :gen_tcp.close(dead_socket)
      Process.sleep(200)
    end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request =
      "GET /library/#{item.id}/theme HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Connection: close\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, request)

    {:ok, response} = read_full_response(socket)

    assert response =~ "HTTP/1.1 200 OK"
    assert String.ends_with?(response, content)
  end

  defp read_full_response(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_full_response(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
