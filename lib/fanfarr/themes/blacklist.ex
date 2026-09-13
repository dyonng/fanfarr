defmodule Fanfarr.Themes.Blacklist do
  @moduledoc """
  Search results the operator never wants offered, as a list of patterns.

  One regular expression per line, matched case-insensitively against each
  hit's title and channel. Anything that matches is dropped from the results
  before they reach the page.

  This exists because some classes of video reliably fail to download and
  nothing in a search listing marks them. It is a blunt instrument on purpose:
  the alternative is asking yt-dlp about every result, which is 25 more
  requests into the rate limit that causes most of the failures in the first
  place.

  **`vevo` is the default, and it is worth knowing what it does and does not
  catch.** Measured over ten results for "official music video vevo": one
  matched. A flat listing reports the artist, not the channel -- Taylor
  Swift's official upload comes back as `channel: "Taylor Swift"` with
  `uploader_id` and `uploader_url` both null, so there is no "VEVO" anywhere in
  it to match. It catches channels that name themselves, which is the honest
  meaning of the word, and the operator can add what else they want. A pattern
  on the title, like `\\(Official.*Video\\)`, catches far more of the same
  material.

  The count of what was hidden is reported back to the page rather than
  swallowed: results silently vanishing is how a filter becomes a bug report.
  """

  @setting "search_blacklist"
  @default "vevo"

  # Bounds, because these compile to PCRE and are matched against every hit of
  # every search. A pathological pattern can backtrack for a very long time and
  # Erlang's :re has no timeout to stop it, so the defence is to keep them
  # short and few rather than to try to catch it afterwards.
  @max_patterns 50
  @max_length 200

  @doc "The raw setting text, one pattern per line."
  @spec text() :: String.t()
  def text do
    case Fanfarr.Config.get(@setting) do
      nil -> @default
      value -> value
    end
  end

  @spec default() :: String.t()
  def default, do: @default

  @spec limits() :: %{patterns: pos_integer(), length: pos_integer()}
  def limits, do: %{patterns: @max_patterns, length: @max_length}

  @doc """
  The compiled patterns, skipping any line that will not compile.

  Skipping rather than failing: a bad line is refused at the point it is saved,
  so one reaching here means it was written before that check existed or edited
  into the database by hand. Losing every filter over one bad line would be a
  worse answer than losing the bad line.
  """
  @spec patterns() :: [Regex.t()]
  def patterns do
    text()
    |> lines()
    |> Enum.flat_map(fn line ->
      case Regex.compile(line, "i") do
        {:ok, regex} -> [regex]
        {:error, _} -> []
      end
    end)
  end

  @doc "Whether a search hit matches any pattern."
  @spec blocked?(map(), [Regex.t()]) :: boolean()
  def blocked?(hit, patterns \\ patterns()) do
    subject = "#{hit[:title]} #{hit[:channel]}"
    Enum.any?(patterns, &Regex.match?(&1, subject))
  end

  @doc """
  Splits hits into the ones to show and the ones to hide.

  Returns `{kept, hidden}` so the caller can say how many went, which is the
  difference between a filter and results mysteriously going missing.
  """
  @spec split([map()]) :: {[map()], [map()]}
  def split(hits) do
    case patterns() do
      [] -> {hits, []}
      patterns -> Enum.split_with(hits, &(not blocked?(&1, patterns)))
    end
  end

  @doc """
  Checks the text an operator typed, naming the line that is wrong.

  Regex errors are reported with the offending pattern quoted, because
  "missing )" on its own is useless when the box holds twenty lines.
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(text) do
    patterns = lines(text)

    cond do
      length(patterns) > @max_patterns ->
        {:error, "Too many patterns: #{length(patterns)}, and the limit is #{@max_patterns}."}

      long = Enum.find(patterns, &(String.length(&1) > @max_length)) ->
        {:error,
         "This pattern is longer than #{@max_length} characters: #{String.slice(long, 0, 40)}…"}

      true ->
        case Enum.find_value(patterns, &compile_error/1) do
          nil -> :ok
          message -> {:error, message}
        end
    end
  end

  defp compile_error(line) do
    case Regex.compile(line, "i") do
      {:ok, _} -> nil
      {:error, {reason, at}} -> ~s(Not a valid pattern: "#{line}" — #{reason} at #{at}.)
      {:error, reason} -> ~s(Not a valid pattern: "#{line}" — #{inspect(reason)}.)
    end
  end

  @doc "Stores the patterns after checking every one of them."
  @spec put(String.t()) :: :ok | {:error, String.t()}
  def put(text) do
    text = to_string(text)

    with :ok <- validate(text) do
      Fanfarr.Settings.put_setting!(@setting, String.trim(text))
      :ok
    end
  end

  # Blank lines are dropped rather than compiled: an empty pattern matches
  # everything, so a stray newline would hide the whole search.
  defp lines(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
