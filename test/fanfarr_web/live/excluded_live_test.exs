defmodule FanfarrWeb.ExcludedLiveTest do
  @moduledoc """
  The two places an operator sets "never touch this title": the library's bulk
  actions, and the toggle on the item page.

  The bulk action is asserted to take effect *now* rather than queue a job,
  because that is the design decision being made: one field, no network, and a
  person who ticked twenty rows expects to see the result.
  """
  use FanfarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fanfarr.Library

  setup :register_and_log_in_user

  setup do
    section = Library.sync_section_from_plex!(%{plex_key: "1", title: "TV Shows", kind: :show})

    item =
      Library.sync_media_item_from_plex!(%{
        plex_rating_key: "101",
        section_id: section.id,
        title: "One Piece",
        kind: :show
      })

    %{item: item, section: section}
  end

  test "the library can exclude and include a selection", %{conn: conn, item: item} do
    {:ok, view, html} = live(conn, "/library")
    refute html =~ "Nothing unattended touches"

    # Tick the row, then act on the selection.
    view |> element(~s(input[phx-value-id="#{item.id}"])) |> render_click()
    view |> element(~s(button[phx-value-action="exclude"])) |> render_click()

    assert Library.get_media_item!(item.id).excluded

    # And the badge says so, which matters more than the control: this feature
    # fails by a title quietly being left out.
    assert render(view) =~ "Nothing unattended touches"

    view |> element(~s(input[phx-value-id="#{item.id}"])) |> render_click()
    view |> element(~s(button[phx-value-action="include"])) |> render_click()

    refute Library.get_media_item!(item.id).excluded
    refute render(view) =~ "Nothing unattended touches"
  end

  test "the item page can toggle it", %{conn: conn, item: item} do
    {:ok, view, _html} = live(conn, "/library/#{item.id}")

    assert has_element?(view, ~s(button[phx-click="toggle_excluded"]), "Not excluded")

    view |> element(~s(button[phx-click="toggle_excluded"])) |> render_click()

    assert Library.get_media_item!(item.id).excluded
    assert has_element?(view, ~s(button[phx-click="toggle_excluded"]), "Excluded")

    view |> element(~s(button[phx-click="toggle_excluded"])) |> render_click()

    refute Library.get_media_item!(item.id).excluded
  end
end
