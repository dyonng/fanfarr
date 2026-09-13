defmodule Fanfarr.Themes.BlacklistTest do
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Themes.Blacklist

  defp hit(title, channel \\ "Some Channel"), do: %{title: title, channel: channel, id: "x"}

  describe "the default" do
    test "is vevo, and matches a channel that names itself" do
      assert Blacklist.text() == "vevo"
      assert Blacklist.blocked?(hit("Mistress", "JonNguyenVEVO"))
    end

    test "does not match a label upload, which is the point worth knowing" do
      # Measured against a real flat-playlist search: the listing reports the
      # artist, not the channel. Taylor Swift's official upload comes back as
      # channel "Taylor Swift" with uploader_id and uploader_url both null, so
      # there is no VEVO anywhere in it. One of ten results matched.
      #
      # Asserted rather than left as a comment, because the default is named
      # after a thing it mostly does not catch and someone will otherwise
      # assume it does.
      refute Blacklist.blocked?(hit("Taylor Swift - The Fate of Ophelia", "Taylor Swift"))
      refute Blacklist.blocked?(hit("Katy Perry - Bon Appétit (Official)", "Katy Perry"))
    end

    test "a title pattern is what catches the rest" do
      :ok = Blacklist.put("\\(Official.*Video\\)")

      assert Blacklist.blocked?(hit("Tyla - IS IT (Official Music Video)", "Tyla"))
      assert Blacklist.blocked?(hit("Lloyd - Tru (Official Video)", "Lloyd"))
      refute Blacklist.blocked?(hit("One Piece OP 1 - We Are!", "Toei"))
    end
  end

  describe "split/1" do
    test "keeps what does not match and counts what does" do
      :ok = Blacklist.put("vevo\nnightcore")

      {kept, hidden} =
        Blacklist.split([
          hit("We Are!", "Toei"),
          hit("Some Song", "ArtistVEVO"),
          hit("Theme (Nightcore)", "Uploader"),
          hit("Bring Me To Life", "Evanescence")
        ])

      assert Enum.map(kept, & &1.title) == ["We Are!", "Bring Me To Life"]
      assert length(hidden) == 2
    end

    test "no patterns hides nothing" do
      :ok = Blacklist.put("")
      hits = [hit("anything"), hit("else")]
      assert Blacklist.split(hits) == {hits, []}
    end

    test "a blank line does not become a pattern that hides everything" do
      # An empty regex matches every string, so a stray newline would empty
      # the search results and look exactly like YouTube returning nothing.
      :ok = Blacklist.put("vevo\n\n   \n")

      {kept, hidden} = Blacklist.split([hit("We Are!", "Toei")])
      assert length(kept) == 1
      assert hidden == []
    end

    test "matching is case-insensitive and covers both title and channel" do
      :ok = Blacklist.put("VEVO")

      assert Blacklist.blocked?(hit("something", "artistvevo"))
      assert Blacklist.blocked?(hit("a vevo upload", "Someone"))
    end
  end

  describe "validate/1" do
    test "a pattern that will not compile names itself" do
      assert {:error, message} = Blacklist.validate("vevo\n(unclosed")
      assert message =~ "(unclosed"
    end

    test "an invalid pattern is refused rather than stored" do
      :ok = Blacklist.put("vevo")
      assert {:error, _} = Blacklist.put("(unclosed")
      assert Blacklist.text() == "vevo"
    end

    test "the bounds are enforced" do
      # These compile to PCRE and run against every hit of every search, and
      # :re has no timeout to stop a pathological one, so the defence is to
      # keep them short and few.
      limits = Blacklist.limits()

      assert {:error, message} =
               Blacklist.validate(Enum.map_join(1..(limits.patterns + 1), "\n", &"p#{&1}"))

      assert message =~ "Too many patterns"

      assert {:error, long} = Blacklist.validate(String.duplicate("a", limits.length + 1))
      assert long =~ "longer than"
    end

    test "a stored pattern that cannot compile loses only itself" do
      # Reachable only by editing the database by hand, since put/1 refuses
      # them -- but losing every filter over one bad line would be worse than
      # losing the bad line.
      Fanfarr.Settings.put_setting!("search_blacklist", "vevo\n(unclosed")

      assert length(Blacklist.patterns()) == 1
      assert Blacklist.blocked?(hit("x", "ArtistVEVO"))
    end
  end
end
