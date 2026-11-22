defmodule FanfarrWeb.Format do
  @moduledoc """
  The numbers a person reads: byte counts and track lengths.

  One definition each, because they appear in more than one place -- a theme's
  size on an item page, the totals on the dashboard, and the size and length of
  every row in the library -- and two pages disagreeing about whether 1.5 GB is
  "1.5 GB" or "1536 MB" is the kind of thing that makes an operator distrust
  both.

  Binary units (1024), named the way the rest of the world names them: the
  "2 GB" trim cache cap is 2 * 1024^3, because that is what the config says.
  """

  @kb 1024
  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024
  @tb 1024 * 1024 * 1024 * 1024

  @doc """
  A byte count as a short string: `"912 B"`, `"417 KB"`, `"1.3 MB"`, `"2.0 GB"`,
  `"3.6 TB"`.

  One decimal from MB up, because that is where the digit that moves is worth
  seeing. KB stays whole: a theme is tens or hundreds of KB, and the fraction
  would be noise. GB is included because the numbers on the dashboard are
  whole-install numbers and "1536.0 MB" is not what anyone calls that. TB is
  included because free space on a media drive is counted in them, and
  "3686.4 GB" is not what anyone calls that either.
  """
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) when n >= @tb, do: "#{Float.round(n / @tb, 1)} TB"
  def bytes(n) when n >= @gb, do: "#{Float.round(n / @gb, 1)} GB"
  def bytes(n) when n >= @mb, do: "#{Float.round(n / @mb, 1)} MB"
  def bytes(n) when n >= @kb, do: "#{div(n, @kb)} KB"
  def bytes(n), do: "#{n} B"

  @doc """
  A length in milliseconds as `m:ss`, e.g. `"2:42"`.

  Truncated rather than rounded: a file that reports 2:42.9 holds 2:42 of
  audio, and rounding up would claim a second it does not have. The
  downloader's ceiling keeps themes well under an hour, so there is no hours
  field to format and "15:00" is unambiguous. A caller with no length passes a
  dash of its own -- nil here means unknown, and that is not the same as 0:00.
  """
  @spec duration_ms(non_neg_integer()) :: String.t()
  def duration_ms(ms) when is_integer(ms) and ms >= 0 do
    total = div(ms, 1000)
    minutes = div(total, 60)
    seconds = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{minutes}:#{seconds}"
  end

  @doc """
  A per-title crop length typed into the trim panel or the bulk dialog, in
  milliseconds.

  One definition because the two inputs mean the same thing and the bounds
  are the same judgement: shorter than five seconds is not a theme, and
  longer than fifteen minutes never survives the downloader's ceiling. Blank
  clears back to the global target. The settings page parses its own
  version, with its own bounds, and stays separate.
  """
  @spec parse_crop_seconds(String.t()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  def parse_crop_seconds(raw) do
    case raw |> to_string() |> String.trim() do
      "" ->
        {:ok, nil}

      typed ->
        case Integer.parse(typed) do
          {seconds, ""} when seconds >= 5 and seconds <= 900 ->
            {:ok, seconds * 1000}

          _ ->
            {:error, "Crop length must be a whole number of seconds, from 5 to 900."}
        end
    end
  end
end
