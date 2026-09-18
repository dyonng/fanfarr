defmodule FanfarrWeb.Format do
  @moduledoc """
  Byte counts, in the units a person reads them in.

  One definition because the number now appears in two places -- the size of a
  written theme on an item page, and the totals on the dashboard -- and two
  pages disagreeing about whether 1.5 GB is "1.5 GB" or "1536 MB" is the kind
  of thing that makes an operator distrust both.

  Binary units (1024), named the way the rest of the world names them: the
  "2 GB" trim cache cap is 2 * 1024^3, because that is what the config says.
  """

  @kb 1024
  @mb 1024 * 1024
  @gb 1024 * 1024 * 1024

  @doc """
  A byte count as a short string: `"912 B"`, `"417 KB"`, `"1.3 MB"`, `"2.0 GB"`.

  One decimal from MB up, because that is where the digit that moves is worth
  seeing. KB stays whole: a theme is tens or hundreds of KB, and the fraction
  would be noise. GB is included because the numbers on the dashboard are
  whole-install numbers and "1536.0 MB" is not what anyone calls that.
  """
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) when n >= @gb, do: "#{Float.round(n / @gb, 1)} GB"
  def bytes(n) when n >= @mb, do: "#{Float.round(n / @mb, 1)} MB"
  def bytes(n) when n >= @kb, do: "#{div(n, @kb)} KB"
  def bytes(n), do: "#{n} B"
end
