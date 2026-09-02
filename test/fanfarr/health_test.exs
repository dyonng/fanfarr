defmodule Fanfarr.HealthTest do
  use Fanfarr.DataCase, async: false

  import Mox

  setup :verify_on_exit!

  alias Fanfarr.Health

  describe "plex/0" do
    test "unconfigured is an error that says where to fix it" do
      Fanfarr.Settings.list_settings!() |> Enum.each(&Fanfarr.Settings.delete_setting!/1)
      System.delete_env("PLEX_URL")
      System.delete_env("PLEX_TOKEN")

      assert %{level: :error, message: "Not configured", detail: detail} = Health.plex()
      assert detail =~ "Settings"
    end

    test "a reachable server is ok, with its name and version" do
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      expect(Fanfarr.PlexClientMock, :server_info, fn config ->
        # Probing must be short; a health page that hangs is not health.
        assert config.req_options[:retry] == false
        {:ok, %{name: "Serve The DY", version: "1.43.4"}}
      end)

      assert %{level: :ok, message: "Connected to Serve The DY", detail: "Plex 1.43.4"} =
               Health.plex()
    end

    test "a rejected token and an unreachable host are told apart" do
      Fanfarr.Settings.put_setting!("plex_url", "http://plex.test:32400")
      Fanfarr.Settings.put_setting!("plex_token", "t")

      expect(Fanfarr.PlexClientMock, :server_info, fn _ -> {:error, :unauthorized} end)
      assert %{level: :error, message: "Token rejected"} = Health.plex()

      expect(Fanfarr.PlexClientMock, :server_info, fn _ -> {:error, %{reason: :econnrefused}} end)
      assert %{level: :error, message: "Unreachable", detail: detail} = Health.plex()
      assert detail =~ "connection refused"
      assert detail =~ "inside the container"
    end
  end

  describe "ytdlp/0" do
    test "reports the version when present" do
      expect(Fanfarr.ThemeDownloaderMock, :version, fn -> {:ok, "2026.08.01"} end)
      assert %{level: :ok, detail: "yt-dlp 2026.08.01"} = Health.ytdlp()
    end

    test "missing is an error, since nothing can be downloaded" do
      expect(Fanfarr.ThemeDownloaderMock, :version, fn -> {:error, :not_installed} end)
      assert %{level: :error, message: "Not installed"} = Health.ytdlp()
    end
  end

  describe "root_folders/0" do
    test "none configured is a warning, not an error" do
      assert %{level: :warning, message: "None configured"} = Health.root_folders()
    end

    test "a folder that vanished is named" do
      dir = Path.join(System.tmp_dir!(), "fanfarr-h-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Fanfarr.Library.create_root_folder!(%{path: dir, kind: :any})
      Fanfarr.Library.create_root_folder!(%{path: Path.join(dir, "gone"), kind: :any})

      assert %{level: :error, message: "1 of 2 unusable", detail: detail} = Health.root_folders()
      assert detail =~ "gone is missing"
      File.rm_rf(dir)
    end
  end

  describe "path_resolution/0" do
    test "nothing synced is a warning that says to sync" do
      assert %{level: :warning, detail: "Sync the library first."} = Health.path_resolution()
    end

    test "a path that does not exist here names the item" do
      section =
        Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

      Fanfarr.Library.sync_media_item_from_plex!(%{
        plex_rating_key: "1",
        section_id: section.id,
        title: "Ghost Show",
        kind: :show,
        plex_path: "/media/merged-storage/TV/Ghost Show"
      })

      assert %{level: :error, detail: detail} = Health.path_resolution()
      assert detail =~ "Ghost Show"
      assert detail =~ "/media/merged-storage/TV/Ghost Show"
    end
  end

  test "path_resolution/0 resolves through configured root folders" do
    root = Path.join(System.tmp_dir!(), "fanfarr-hp-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "tv1", "One Piece (1999)"]))
    on_exit(fn -> File.rm_rf(root) end)
    Fanfarr.Library.create_root_folder!(%{path: Path.join(root, "tv1"), kind: :show})

    section = Fanfarr.Library.sync_section_from_plex!(%{plex_key: "1", title: "TV", kind: :show})

    Fanfarr.Library.sync_media_item_from_plex!(%{
      plex_rating_key: "1",
      section_id: section.id,
      title: "One Piece",
      kind: :show,
      # The pool path Plex reports does not exist here; the root folder does.
      plex_path: "/media/merged-storage/TV/One Piece (1999)"
    })

    assert %{level: :ok, message: "1 of 1 sampled paths resolve"} = Health.path_resolution()
  end

  test "database/0 sees WAL mode" do
    assert %{level: :ok, detail: "SQLite, WAL mode"} = Health.database()
  end

  test "worst/1 is the most severe level present" do
    r = fn level -> %{id: :x, name: "x", level: level, message: "", detail: nil} end
    assert Health.worst([r.(:ok), r.(:ok)]) == :ok
    assert Health.worst([r.(:ok), r.(:warning)]) == :warning
    assert Health.worst([r.(:warning), r.(:error), r.(:ok)]) == :error
    assert Health.worst([]) == :ok
  end
end
