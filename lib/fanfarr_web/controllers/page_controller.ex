defmodule FanfarrWeb.PageController do
  use FanfarrWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
