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

  describe "sources/1" do
    test "a cold cache reads as not looked up, not as nothing available", ctx do
      item = item(ctx)

      # The distinction that matters for a bulk apply: this item needs a lookup
      # queued, it is not a title ThemerrDB cannot help with.
      assert Choice.sources([item]) == %{item.id => :unknown}
    end

    test "a cached suggestion is what Apply would use", ctx do
      item = item(ctx)
      themerr(item, "https://www.youtube.com/watch?v=abc12345678")

      assert Choice.sources([item]) == %{item.id => :themerrdb}
    end

    test "a cached miss is a definite no", ctx do
      item = item(ctx)
      themerr(item, nil)

      assert Choice.sources([item]) == %{item.id => :none}
    end

    test "the operator's pick outranks the database", ctx do
      item = item(ctx)
      themerr(item, "https://www.youtube.com/watch?v=abc12345678")

      item =
        Fanfarr.Library.set_manual_theme!(item, %{
          manual_theme_url: "https://www.youtube.com/watch?v=zzz12345678"
        })

      assert Choice.sources([item]) == %{item.id => :pick}
    end

    test "one query answers a whole page", ctx do
      items = for _ <- 1..5, do: item(ctx)
      Enum.each(items, &themerr(&1, "https://www.youtube.com/watch?v=abc12345678"))

      sources = Choice.sources(items)
      assert map_size(sources) == 5
      assert Enum.all?(items, &(sources[&1.id] == :themerrdb))
    end

    test "an empty page asks nothing" do
      assert Choice.sources([]) == %{}
    end
  end

  describe "agreeing with what the worker would do" do
    # The table's promise is only worth anything if it matches the worker. Both
    # read this module, and these pin that the two answers correspond.
    test "every source maps to the URL result the worker acts on", ctx do
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

      assert Choice.source(cold, []) == :unknown
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
