defmodule Fanfarr.Diagnostics.Redactor do
  @moduledoc """
  Removes secrets from anything the System page will show.

  The point of the log and diagnostics panels is that their output gets pasted
  into a bug report, so the safe assumption is that everything on that page
  becomes public. Redaction therefore happens at *capture* time rather than at
  render time -- a secret that never enters the buffer cannot leak out of it
  through some path nobody thought about.

  Two passes, because each catches what the other cannot:

    * known values -- the actual Plex token, the operator password, the signing
      secrets. Catches a secret that appears with no label at all, which is how
      it shows up in a SQL parameter list.
    * labelled patterns -- `X-Plex-Token=...`, `password: ...`. Catches a
      secret this process does not know, such as one belonging to a different
      server that appears in a pasted URL.
  """

  # Anything shorter is more likely to be a common substring than a secret, and
  # replacing it would corrupt the output without protecting anything.
  @min_secret_length 6

  @env_secrets ~w(PLEX_TOKEN AUTH_PASSWORD SECRET_KEY_BASE TOKEN_SIGNING_SECRET)

  @cache_key {__MODULE__, :secrets}

  @labelled [
    # Plex puts its token in query strings and headers.
    ~r/(X-Plex-Token["'=:\s]+)([^\s&"'<>]+)/i,
    ~r/([?&](?:token|api_?key|auth)=)([^\s&"'<>]+)/i,
    # Generic key/value shapes seen in inspected structs and JSON. The \w*
    # matters: the keyword is usually a prefix, as in secret_key_base.
    ~r/((?:password|passwd|secret|token|api[_-]?key)\w*["'\s]*[:=]["'\s]*)([^\s,;"'<>}\]]+)/i
  ]

  @replacement "[redacted]"

  @doc """
  Scrubs secrets from `text`.

  Safe to call on anything; non-binaries are inspected first.
  """
  @spec redact(term()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> replace_known()
    |> replace_labelled()
  end

  def redact(other), do: other |> inspect(limit: :infinity, printable_limit: 4096) |> redact()

  @doc """
  The secret values this process knows about.

  Read from the environment and from a small cache, never from the database.
  That is not an optimisation: Ecto logs every query it runs, so a redactor
  that queried would log, which would redact, which would query -- and one log
  line would spin forever. The cache is primed at boot, whenever the token is
  saved, and on every health tick, so it cannot drift for long.
  """
  @spec known_secrets() :: [String.t()]
  def known_secrets do
    env = Enum.map(@env_secrets, &System.get_env/1)

    (env ++ cached())
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) >= @min_secret_length))
    |> Enum.uniq()
    # Longest first, so a secret that contains another is replaced whole.
    |> Enum.sort_by(&(-String.length(&1)))
  end

  @doc """
  Reads the secrets that live in the database into the cache.

  Safe to call whenever; a failure leaves the previous cache in place, and the
  labelled patterns still catch a token that appears with its name next to it.
  """
  @spec prime() :: :ok
  def prime do
    case Fanfarr.Config.get("plex_token") do
      value when is_binary(value) -> remember(value)
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Adds a value to the set that will be scrubbed from now on."
  @spec remember(String.t()) :: :ok
  def remember(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) >= @min_secret_length do
      :persistent_term.put(@cache_key, Enum.uniq([trimmed | cached()]))
    end

    :ok
  end

  def remember(_), do: :ok

  @doc false
  def forget_all, do: :persistent_term.put(@cache_key, [])

  defp cached, do: :persistent_term.get(@cache_key, [])

  defp replace_known(text) do
    Enum.reduce(known_secrets(), text, fn secret, acc ->
      String.replace(acc, secret, @replacement)
    end)
  end

  defp replace_labelled(text) do
    Enum.reduce(@labelled, text, fn pattern, acc ->
      String.replace(acc, pattern, fn full ->
        case Regex.run(pattern, full, capture: :all_but_first) do
          [label, _value] -> label <> @replacement
          _ -> @replacement
        end
      end)
    end)
  end
end
