defmodule Fanfarr.HostOnlyPath do
  @moduledoc """
  A path Plex reports on the host that this container cannot see.

  The shape comes from the case this exists for. Plex runs on the host and
  reports `/media/red-10-redemption/TV/One Pace`, while Fanfarr runs in a
  container that mounts the same drives as `/tv1../tv5`. Root folders are the
  whole mechanism for bridging that, and every test in that area depends on the
  reported path being *absent* here, so it cannot be used directly.

  The path is synthetic rather than the one from the report. That literal is a
  real directory on a machine that runs the media stack -- this project's own
  development server is one -- and a test that hardcoded it would do two wrong
  things there. It would assert a premise that is false, and -- worse, because
  it is quiet -- the code under test would take the branch the test exists to
  exclude, resolving to the real directory and downloading into a live library
  instead of failing loudly on a missing mount.

  One name per call, so a test that reports a path and then asserts on the same
  string holds it in a variable rather than building it twice.
  """

  @doc "A path under `/media` that does not exist here, tagged with `name`."
  @spec hidden(String.t()) :: String.t()
  def hidden(name) do
    Path.join([
      "/media",
      "fanfarr-nonexistent-#{:erlang.unique_integer([:positive])}",
      "TV",
      name
    ])
  end
end
