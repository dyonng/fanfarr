defmodule Fanfarr.Themes.ChoiceTest do
  @moduledoc """
  What Apply would use, which the library table now promises ahead of time.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Themes
  alias Fanfarr.Themes.Choice

  setup do
    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})
    %{section: section}
  end

  defp item(ctx, over \\ %{}) do
    Fanfarr.Library.sync_media_item_from_plex!(
      Map.merge(
        %{
          plex_rating_key: "rk-#{System.unique_integer([:positive])}",
          section_id: ctx.section.id,
          title: "A Show",
          kind: :show,
          imdb_id: "tt#{System.unique_integer([:positive])}"
        },
        over
      )
    )
  end

  defp themerr(item, url) do
    Themes.record_themerr_lookup!(%{
      item_type: :tv_shows,
      database: :imdb,
      external_id: item.imdb_id,
      found: url != nil,
      youtube_theme_url: url
    })
  end

  describe "what the worker would apply" do
    test "each cache state gives the worker the answer it acts on", ctx do
      cold = item(ctx)

      hit = item(ctx)
      themerr(hit, "https://www.youtube.com/watch?v=abc12345678")

      miss = item(ctx)
      themerr(miss, nil)

      picked = item(ctx)

      picked =
        Fanfarr.Library.set_manual_theme!(picked, %{
          manual_theme_url: "https://www.youtube.com/watch?v=zzz12345678"
        })

      # A cold cache and a cached miss both refuse, and deliberately look the
      # same from here: neither can be applied. Which one it is decides the
      # remedy -- queue a lookup, or pick a theme by hand -- and that is the
      # item page's job to explain, not this module's.
      assert {:error, :no_themerrdb_entry} = Choice.url(cold)

      assert {:ok, _, :themerrdb} = Choice.url(hit)
      assert {:error, :no_themerrdb_entry} = Choice.url(miss)
      assert {:ok, "https://www.youtube.com/watch?v=zzz12345678", :youtube} = Choice.url(picked)
    end

    test "a URL passed with the job outranks everything", ctx do
      item = item(ctx)

      themerr(item, "https://www.youtube.com/watch?v=abc12345678")

      assert {:ok, "https://youtu.be/passed", :youtube} =
               Choice.url(item, %{"theme_url" => "https://youtu.be/passed"})
    end
  end
end
