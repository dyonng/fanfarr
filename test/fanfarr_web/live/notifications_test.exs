defmodule FanfarrWeb.NotificationsTest do
  @moduledoc """
  The Notifications card: one switch per kind of event, and a test button.

  The switches are asserted to be one per type from the module's own list, so
  adding a kind later cannot leave the card showing a switch that saves nothing
  or missing one that the code reads.
  """
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fanfarr.Notify

  setup :register_and_log_in_user

  setup do
    Req.Test.set_req_test_to_shared(%{})
    test_pid = self()

    Req.Test.stub(Fanfarr.NotifyReq, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:notified, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    :ok
  end

  test "there is a switch for every kind of notification", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#notifications-card")

    for type <- Notify.types() do
      assert has_element?(view, "input[name='#{type.setting}']"),
             "no switch for #{type.key}"

      assert render(view) =~ type.label
    end
  end

  test "with no URL the card says nothing is being sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    assert render(view) =~ "No URL set"
  end

  test "saving the URL, the shape and the switches stores them", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    # An explicit payload rather than `form/3`: LiveViewTest validates a checkbox
    # against its *rendered* value, which is "true", so "off" cannot be said
    # through it. The handler is what decides what the value means.
    view
    |> element("#notifications-form")
    |> render_submit(%{
      "notify_url" => "https://ntfy.sh/fanfarr",
      "notify_style" => "json",
      "notify_job_failures" => "true",
      "notify_health" => "true",
      "notify_backups" => "false",
      "notify_sync" => "true"
    })

    assert Notify.url() == "https://ntfy.sh/fanfarr"
    assert Notify.style() == "json"
    assert Notify.enabled?(:job_failures)
    refute Notify.enabled?(:backups)
    assert Notify.enabled?(:sync)
  end

  test "a URL that is not a URL is refused rather than stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    html = view |> form("#notifications-form", notify_url: "ntfy.sh/fanfarr") |> render_submit()

    assert html =~ "has to start with http://"
    assert Notify.url() == nil
  end

  test "a shape that is not a shape is refused", %{conn: conn} do
    Fanfarr.Settings.put_setting!("notify_url", "https://ntfy.sh/fanfarr")

    {:ok, view, _html} = live(conn, "/settings")

    # The select cannot produce this value, which is the point of the guard: it
    # is there for a request that did not come from the form.
    html =
      view
      |> element("#notifications-form")
      |> render_submit(%{"notify_style" => "carrier-pigeon", "notify_url" => ""})

    assert html =~ "Pick one of"
    assert Notify.style() == "ntfy"
  end

  test "the card offers the token Gotify needs, and detects the shape", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    assert has_element?(view, "#notifications-card input[name='notify_token']")
    assert has_element?(view, "#notifications-card", "Webhook Type")
    assert has_element?(view, "#notifications-card option[value='']", "Auto")
  end

  test "a token is stored, and a blank shape leaves the URL deciding", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    view
    |> element("#notifications-form")
    |> render_submit(%{
      "notify_url" => "https://gotify.example.com",
      "notify_style" => "",
      "notify_token" => "apptoken123"
    })

    assert Fanfarr.Notify.token() == "apptoken123"
    assert Fanfarr.Notify.style() == "gotify"
    assert Fanfarr.Notify.inferred?()
  end

  test "the test button sends one, whatever the switches say", %{conn: conn} do
    Fanfarr.Settings.put_setting!("notify_url", "https://ntfy.sh/fanfarr")
    for type <- Notify.types(), do: Fanfarr.Settings.put_setting!(type.setting, "false")

    {:ok, view, _html} = live(conn, "/settings")

    view |> element(~s(button[phx-click="test_notification"])) |> render_click()

    assert_receive {:notified, body}, 2_000
    assert body =~ "notifications are set up"
    assert render(view) =~ "Sent."
  end
end
