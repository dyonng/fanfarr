defmodule DockerfileContextTest do
  @moduledoc """
  Guards the Docker build context against .dockerignore.

  A `.dockerignore` pattern that excludes something the Dockerfile copies fails
  the image build with "not found" -- and only in CI, minutes in, long after the
  code that caused it looked fine locally. That is exactly how `/config/` came
  to strip the application's own Elixir configuration: the pattern was written
  for the container's /config state volume, which happened to share a name.

  This checks every context path the Dockerfile copies still survives the
  ignore rules.
  """
  use ExUnit.Case, async: true

  @dockerfile "Dockerfile"
  @dockerignore ".dockerignore"

  test "no COPY source in the Dockerfile is excluded by .dockerignore" do
    patterns = ignore_patterns()

    for source <- copy_sources() do
      refute excluded?(source, patterns),
             """
             .dockerignore excludes "#{source}", which the Dockerfile copies.
             The image build will fail with `"#{source}": not found`.
             Offending pattern(s): #{inspect(matching_patterns(source, patterns))}
             """
    end
  end

  test "the runtime state directory is still excluded" do
    # The rule this all exists to serve: a developer's local database and
    # generated secret must never be baked into a published image.
    patterns = ignore_patterns()

    assert excluded?("appdata", patterns)
    assert excluded?("secret_key_base", patterns)
  end

  defp copy_sources do
    @dockerfile
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\s*COPY\s/i))
    # Sources for --from=<stage> come from an earlier build stage, not the
    # build context, so .dockerignore does not apply to them.
    |> Enum.reject(&String.contains?(&1, "--from="))
    |> Enum.flat_map(&parse_copy/1)
    |> Enum.uniq()
  end

  defp parse_copy(line) do
    args =
      line
      |> String.replace(~r/^\s*COPY\s+/i, "")
      |> String.replace(~r/--\S+\s+/, "")
      |> String.replace("${MIX_ENV}", "prod")
      |> String.split(~r/\s+/, trim: true)

    # The final argument is the destination inside the image.
    case args do
      [] -> []
      [_only] -> []
      args -> Enum.drop(args, -1)
    end
  end

  defp ignore_patterns do
    @dockerignore
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp matching_patterns(path, patterns) do
    Enum.filter(patterns, &matches?(path, &1))
  end

  # Negations (!pattern) re-include; a path is excluded only if some pattern
  # matches it and no later negation rescues it.
  defp excluded?(path, patterns) do
    Enum.reduce(patterns, false, fn pattern, excluded ->
      cond do
        String.starts_with?(pattern, "!") ->
          if matches?(path, String.trim_leading(pattern, "!")), do: false, else: excluded

        matches?(path, pattern) ->
          true

        true ->
          excluded
      end
    end)
  end

  defp matches?(path, pattern) do
    normalized = path |> String.trim_leading("./") |> String.trim_trailing("/")
    cleaned = pattern |> String.trim_leading("/") |> String.trim_trailing("/")

    regex =
      cleaned
      |> Regex.escape()
      # Restore glob semantics that Regex.escape flattened.
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    # A pattern matches the path itself, or the path as a directory prefix --
    # excluding "config" also excludes "config/runtime.exs".
    Regex.match?(~r/^#{regex}$/, normalized) or
      Regex.match?(~r/^#{regex}\//, normalized) or
      Regex.match?(~r/^#{regex}$/, Path.basename(normalized))
  end
end
