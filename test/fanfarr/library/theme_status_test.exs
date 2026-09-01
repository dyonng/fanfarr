defmodule Fanfarr.Library.ThemeStatusTest do
  @moduledoc """
  The five states the brief asks us to distinguish, exercised against a real
  database rather than the calculation in isolation -- the point of deriving
  status is that it stays true to the underlying rows.
  """
  use Fanfarr.DataCase, async: true

  alias Fanfarr.Library.MediaItem
  alias Fanfarr.Library.Section
  alias Fanfarr.Themes.ThemeApplication

  setup do
    section =
      Section
      |> Ash.Changeset.for_create(:create, %{
        plex_key: "1",
        title: "TV Shows",
        kind: :show,
        enabled: true
      })
      |> Ash.create!()

    %{section: section}
  end

  defp item(section, attrs) do
    MediaItem
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          plex_rating_key: "rk-#{System.unique_integer([:positive])}",
          title: "A Show",
          kind: :show,
          section_id: section.id
        },
        attrs
      )
    )
    |> Ash.create!()
  end

  defp apply_theme(item, attrs) do
    ThemeApplication
    |> Ash.Changeset.for_create(
      :record_outcome,
      Map.merge(
        %{
          media_item_id: item.id,
          source: :themerrdb,
          method: :api_upload,
          theme_url: "https://www.youtube.com/watch?v=abc"
        },
        attrs
      )
    )
    |> Ash.create!()
  end

  defp status(item) do
    item |> Ash.load!(:theme_status) |> Map.fetch!(:theme_status)
  end

  test "an item with nothing at all is missing", %{section: section} do
    assert status(item(section, %{})) == :missing
  end

  test "a theme Plex supplied is distinguished from ours", %{section: section} do
    item = item(section, %{plex_theme_url: "https://plex.example/theme.mp3"})
    assert status(item) == :plex_supplied
  end

  test "a local theme.mp3 outranks a Plex-supplied one", %{section: section} do
    item =
      item(section, %{
        plex_theme_url: "https://plex.example/theme.mp3",
        local_theme_present: true
      })

    assert status(item) == :local_file
  end

  test "Plex reporting provider 'local' also counts as a local file", %{section: section} do
    item = item(section, %{plex_theme_url: "x", plex_theme_provider: "local"})
    assert status(item) == :local_file
  end

  test "a succeeded application means we applied it", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded})

    assert status(item) == :fanfarr_applied
  end

  test "a failure outranks everything, because it is the only actionable state",
       %{section: section} do
    item =
      item(section, %{
        plex_theme_url: "https://plex.example/theme.mp3",
        local_theme_present: true
      })

    apply_theme(item, %{status: :failed, error: "yt-dlp exited 1"})

    assert status(item) == :failed
  end

  test "the most recent application wins", %{section: section} do
    item = item(section, %{})

    apply_theme(item, %{status: :failed, error: "rate limited"})
    Process.sleep(5)
    apply_theme(item, %{status: :succeeded})

    assert status(item) == :fanfarr_applied
  end

  test "a dry run never changes what the item reports", %{section: section} do
    item = item(section, %{})
    apply_theme(item, %{status: :succeeded, dry_run: true})

    # The preview happened, but nothing was applied to the server.
    assert status(item) == :missing
  end

  test "status is calculated for a batch in one pass", %{section: section} do
    a = item(section, %{})
    b = item(section, %{plex_theme_url: "https://plex.example/t.mp3"})
    c = item(section, %{})
    apply_theme(c, %{status: :succeeded})

    statuses =
      MediaItem
      |> Ash.Query.load(:theme_status)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1.theme_status})

    assert statuses[a.id] == :missing
    assert statuses[b.id] == :plex_supplied
    assert statuses[c.id] == :fanfarr_applied
  end
end
