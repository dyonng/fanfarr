defmodule Fanfarr.Themes.Downloader.YtDlpTest do
  @moduledoc """
  `Fanfarr.Themes.DownloaderTest` covers YtDlp's pure functions without a
  database; `proxy_args/0` reads Settings, so it needs the sandbox this file
  pulls in instead.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Themes.Downloader.YtDlp

  describe "proxy_args/0" do
    test "no proxy by default" do
      assert YtDlp.proxy_args() == []
    end

    test "passes --proxy when the setting is on" do
      Fanfarr.Settings.put_setting!("ytdlp_proxy", "socks5://127.0.0.1:1080")
      assert YtDlp.proxy_args() == ["--proxy", "socks5://127.0.0.1:1080"]
    end

    test "a blank value is treated as unset" do
      Fanfarr.Settings.put_setting!("ytdlp_proxy", "")
      assert YtDlp.proxy_args() == []
    end
  end
end
