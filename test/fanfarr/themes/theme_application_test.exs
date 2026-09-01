defmodule Fanfarr.Themes.ThemeApplicationTest do
  @moduledoc """
  The log is the only durable record of what was done to someone's Plex server,
  because uploads cannot be undone through its API. These cover the properties
  that makes necessary.
  """
  use Fanfarr.DataCase, async: true

  alias Fanfarr.Library.MediaItem
  alias Fanfarr.Library.Section
  alias Fanfarr.Themes.ThemeApplication

  setup do
    section =
      Section
      |> Ash.Changeset.for_create(:create, %{plex_key: "1", title: "TV", kind: :show})
      |> Ash.create!()

    item =
      MediaItem
      |> Ash.Changeset.for_create(:create, %{
        plex_rating_key: "rk1",
        title: "One Piece",
        kind: :show,
        section_id: section.id
      })
      |> Ash.create!()

    %{item: item}
  end

  defp record_outcome(item, attrs) do
    ThemeApplication
    |> Ash.Changeset.for_create(
      :record_outcome,
      Map.merge(%{media_item_id: item.id, source: :themerrdb, method: :api_upload}, attrs)
    )
    |> Ash.create!()
  end

  test "the log is append-only: no update or destroy action exists" do
    actions = ThemeApplication |> Ash.Resource.Info.actions() |> Enum.map(& &1.type)

    refute :update in actions
    refute :destroy in actions
  end

  test "intent is recorded before the attempt, so a crash leaves evidence", %{item: item} do
    intent =
      ThemeApplication
      |> Ash.Changeset.for_create(:record_intent, %{
        media_item_id: item.id,
        source: :themerrdb,
        method: :api_upload,
        theme_url: "https://y.t/x"
      })
      |> Ash.create!()

    assert intent.status == :pending
    assert intent.attempted_at
  end

  test "a retry is a new row, not a mutation of the old one", %{item: item} do
    record_outcome(item, %{status: :failed, error: "rate limited"})
    record_outcome(item, %{status: :succeeded})

    history =
      ThemeApplication |> Ash.Query.for_read(:for_item, %{media_item_id: item.id}) |> Ash.read!()

    assert length(history) == 2
    assert Enum.map(history, & &1.status) |> Enum.sort() == [:failed, :succeeded]
  end

  test "an irreversible upload is distinguishable from a local file", %{item: item} do
    api = record_outcome(item, %{status: :succeeded, method: :api_upload})

    local =
      record_outcome(item, %{
        status: :succeeded,
        method: :local_file,
        destination_path: "/tv1/One Piece"
      })

    assert api.method == :api_upload
    assert local.destination_path == "/tv1/One Piece"
  end

  test "skipped records the idempotency path", %{item: item} do
    skipped = record_outcome(item, %{status: :skipped})
    assert skipped.status == :skipped
  end

  test "failures can be listed for the activity view", %{item: item} do
    record_outcome(item, %{status: :succeeded})
    record_outcome(item, %{status: :failed, error: "yt-dlp exited 1"})
    record_outcome(item, %{status: :failed, error: "should not appear", dry_run: true})

    failures = ThemeApplication |> Ash.Query.for_read(:failures) |> Ash.read!()

    assert [only] = failures
    assert only.error == "yt-dlp exited 1"
  end
end
