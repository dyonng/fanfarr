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

  test "a build with no ref says dev rather than pretending" do
    # The suite compiles without BUILD_REF set.
    assert Version.build_ref() == nil
    assert Version.display() =~ "(dev)"
  end
end
