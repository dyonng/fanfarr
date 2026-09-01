defmodule Fanfarr.VersionTest do
  use ExUnit.Case, async: true

  alias Fanfarr.Version

  test "version matches the one in mix.exs" do
    assert Version.version() == Mix.Project.config()[:version]
    assert Version.version() =~ ~r/^\d+\.\d+\.\d+/
  end

  test "display always identifies the build, never just the number" do
    # "0.1.0" alone cannot distinguish two `latest` images built a week apart,
    # which is exactly what a bug report needs to do.
    assert Version.display() =~ ~r/^\d+\.\d+\.\d+ \(.+\)$/
  end

  test "it asks Mix to recompile when BUILD_REF changes" do
    # Without this the module keeps the ref it was first compiled with, and
    # reports the wrong build forever. Caught by rebuilding a release with a
    # new ref and watching it report the old one.
    assert function_exported?(Fanfarr.Version, :__mix_recompile__?, 0)

    # The suite compiles with BUILD_REF unset, so nothing has changed.
    refute Fanfarr.Version.__mix_recompile__?()
  end

  test "a build with no ref says dev rather than pretending" do
    # The suite compiles without BUILD_REF set.
    assert Version.build_ref() == nil
    assert Version.display() =~ "(dev)"
  end
end
