defmodule FanfarrWeb.HealthControllerTest do
  use FanfarrWeb.ConnCase, async: false

  test "reports ok and the app version when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok", "version" => version} = json_response(conn, 200)
    assert version =~ ~r/^\d+\.\d+\.\d+/
  end
end
