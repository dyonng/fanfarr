defmodule Fanfarr.Notify do
  @moduledoc """
  Outbound notifications, for the things nobody is watching for.

  Every scheduled job here runs unattended, and until now the only sign that one
  had failed was a badge on a page nobody had open. That is the wrong shape for
  an appliance: the failure and the discovery of it are separated by however long
  it takes somebody to log in.

  ## One URL, and the shape is read from it

  A webhook URL, because the services people actually run disagree about what a
  notification is: `ntfy` wants plain text with a title header, Discord and Slack
  each want a JSON field of their own, Gotify wants a token in a header, and
  anything else gets the generic object. No SDK, no vendor client -- one POST.

  The shape is **inferred from the URL**, so pasting a Discord webhook address is
  the whole of the setup and there is no "which service is this" question to get
  wrong. A host nobody recognises falls back to plain text, which a dumb receiver
  understands where JSON would need a parser, and the explicit setting overrides
  the guess -- for a self-hosted Gotify, or an ntfy on its own domain.

  ## A switch per type

  Each kind of event has its own, because the useful set is not the same for
  everyone: a sync that finishes every six hours is noise to most people and
  exactly what somebody else wants. Failures are on by default; the routine one
  is off.

  ## Delivery never fails the work

  A notification is a courtesy, so sending one is best-effort. A timeout, a DNS
  failure or a 500 is logged and swallowed. The alternative -- a job that did its
  work and then failed because the notification *about* it could not be
  delivered -- is worse than silence.
  """

  require Logger

  @types [
    %{
      key: :job_failures,
      setting: "notify_job_failures",
      default: true,
      label: "A job gives up",
      description: "After its last retry, with the error it died on."
    },
    %{
      key: :health,
      setting: "notify_health",
      default: true,
      label: "A health check starts failing",
      description: "On the change, not on every check that finds it still failing."
    },
    %{
      key: :backups,
      setting: "notify_backups",
      default: true,
      label: "A database backup fails",
      description: "The record of what this appliance has done is not being copied."
    },
    %{
      key: :sync,
      setting: "notify_sync",
      default: false,
      label: "A library sync finishes",
      description: "Routine, and therefore off unless you want the heartbeat."
    }
  ]

  @styles ~w(ntfy discord slack gotify json)

  @doc "Every kind of notification, with the settings that switch it."
  @spec types() :: [map()]
  def types, do: @types

  @doc "The payload shapes a webhook can be sent in."
  @spec styles() :: [String.t()]
  def styles, do: @styles

  @doc "The webhook URL, or nil when notifications are unconfigured."
  @spec url() :: String.t() | nil
  def url do
    case Fanfarr.Config.get("notify_url") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc "The payload shape, falling back to `ntfy` rather than sending nothing."
  @spec style() :: String.t()
  def style do
    case Fanfarr.Config.get("notify_style") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> infer(url())
          explicit -> if explicit in @styles, do: explicit, else: infer(url())
        end

      _ ->
        infer(url())
    end
  end

  @doc """
  Whether the shape was read from the URL rather than chosen.

  The settings form says so: a select showing a value nobody picked is otherwise
  a small lie, and it is the value people would blame for a wrong payload.
  """
  @spec inferred?() :: boolean()
  def inferred? do
    case Fanfarr.Config.get("notify_style") do
      value when is_binary(value) -> String.trim(value) not in @styles
      _ -> true
    end
  end

  @doc """
  The shape an address implies.

  Substring matching rather than a parser: these are the addresses the services
  hand out, and the setting is there for everything else. Plain text is the
  fallback because a dumb receiver understands anything, where JSON needs a
  parser on the other end to have been written for it.
  """
  @spec infer(String.t() | nil) :: String.t()
  def infer(nil), do: "ntfy"

  def infer(address) do
    lowered = String.downcase(address)

    cond do
      String.contains?(lowered, "discord") -> "discord"
      String.contains?(lowered, "slack") -> "slack"
      String.contains?(lowered, "gotify") -> "gotify"
      # ntfy topics are usually on a subdomain of the word; ntfy.sh is the hosted
      # one.
      String.contains?(lowered, "ntfy") -> "ntfy"
      true -> "ntfy"
    end
  end

  @doc "The Gotify application token, which only that shape needs."
  @spec token() :: String.t() | nil
  def token do
    case Fanfarr.Config.get("notify_token") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc "Whether a URL is set at all. No URL means the feature is off."
  @spec enabled?() :: boolean()
  def enabled?, do: url() != nil

  @doc """
  Whether this kind of notification is switched on.

  Unset means the type's own default, not "on": the routine one is off unless
  somebody asks for it.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(key), do: enabled?() and switched_on?(key)

  @doc """
  The switch as it is set, ignoring whether a URL exists.

  The settings form needs this rather than `enabled?/1`: with no URL set every
  box would render unticked, and the next save would persist that as "off" -- a
  setting nobody chose.
  """
  @spec switched_on?(atom()) :: boolean()
  def switched_on?(key) do
    case Enum.find(@types, &(&1.key == key)) do
      # A key with no type behind it is off, not on: a typo at a call site should
      # send nothing rather than everything.
      nil -> false
      type -> enabled_setting?(type)
    end
  end

  @doc """
  Sends one, if its switch is on.

  Returns `:skipped` when it is not, which is a different answer from `:ok` and
  the reason tests can tell the two apart.
  """
  @spec send(atom(), String.t(), String.t(), keyword()) :: :ok | :skipped | {:error, term()}
  def send(type, title, message, opts \\ []) do
    if enabled?(type), do: deliver(title, message, opts), else: :skipped
  end

  @doc """
  Sends a test, ignoring the switches.

  The point of a test button is to find out whether the URL and the style are
  right. Gating it on a switch would answer a different question.
  """
  @spec test() :: :ok | {:error, term()}
  def test do
    if enabled?() do
      deliver("Fanfarr test", "If you are reading this, notifications are set up.", [])
    else
      {:error, :no_url}
    end
  end

  @doc "Attaches the Oban handler. Called once, after the tree is up."
  @spec attach() :: :ok
  def attach do
    :telemetry.attach(
      "fanfarr-notify-job-failures",
      [:oban, :job, :stop],
      &__MODULE__.handle_oban/4,
      nil
    )

    :ok
  end

  @doc """
  A job that has run out of retries.

  On `:discarded` rather than on every exception: a job that fails and will be
  tried again is not news yet, and one that is retried five times would otherwise
  announce itself five times.
  """
  @spec handle_oban([atom()], map(), map(), term()) :: :ok | :skipped | {:error, term()}
  def handle_oban(_event, _measurements, %{job: job, state: :discarded}, _config) do
    send(
      :job_failures,
      "#{Fanfarr.Jobs.describe(job)} gave up",
      "#{Fanfarr.Jobs.describe(job)} failed after #{job.max_attempts} attempt(s).\n" <>
        "Last error: #{last_error(job)}"
    )
  end

  def handle_oban(_event, _measurements, _metadata, _config), do: :skipped

  defp last_error(job) do
    case List.last(job.errors || []) do
      %{"error" => error} when is_binary(error) -> String.slice(error, 0, 400)
      other -> inspect(other, limit: 3)
    end
  end

  @doc """
  Sends a health notification when the checks have just gone bad.

  Public, and here rather than in the monitor, because it is the whole rule and
  the rule is worth a test that does not depend on which checks happen to fail on
  the machine running it. The monitor's own state is a single process for the
  life of the application, so a test of the transition through it would be at the
  mercy of whatever ran before.

  A check that has been broken for an hour is not news, and an appliance that
  repeats itself is one people stop reading. Recovering is not news either: the
  switch is about failures.
  """
  @spec notify_transition(map() | nil, map()) :: :ok | :skipped | {:error, term()}
  def notify_transition(previous, snapshot) do
    if transition?(previous, snapshot) do
      failing = Enum.filter(snapshot.results, &(&1.level == :error))

      send(
        :health,
        "#{length(failing)} health check(s) failing",
        Enum.map_join(failing, "\n", &"#{&1.name}: #{&1.message}"),
        level: :error
      )
    else
      :skipped
    end
  end

  defp transition?(previous, snapshot) do
    Fanfarr.Health.worst(snapshot.results) == :error and
      (previous == nil or Fanfarr.Health.worst(previous.results) != :error)
  end

  defp enabled_setting?(type) do
    case Fanfarr.Config.get(type.setting) do
      nil -> type.default
      value -> value not in ["false", "0", "off"]
    end
  end

  defp deliver(title, message, opts) do
    style = style()

    with :ok <- check_token(style) do
      {headers, body} = payload(style, title, message, opts)

      case Req.post(client(), url: endpoint(style), headers: headers, body: body) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("[fanfarr] the notification endpoint answered #{status}")
          {:error, {:status, status}}

        {:error, reason} ->
          Logger.warning("[fanfarr] could not send a notification: #{inspect(reason, limit: 3)}")
          {:error, reason}
      end
    end
  end

  # A clear answer beats a 401 from somebody else's server. Gotify is the one
  # shape needing a second field, so forgetting it is the likely mistake.
  defp check_token("gotify") do
    if token(), do: :ok, else: {:error, :gotify_needs_a_token}
  end

  defp check_token(_style), do: :ok

  @doc """
  Where a notification is posted.

  Gotify is posted to an endpoint on the server the operator names; everything
  else is the address itself. Public because it is a rule worth testing without
  a request, and a `Req.Test` connection does not carry the path back to the
  caller.
  """
  @spec endpoint(String.t()) :: String.t() | nil
  def endpoint("gotify") do
    base = String.trim_trailing(url() || "", "/")

    if String.ends_with?(base, "/message"), do: base, else: base <> "/message"
  end

  def endpoint(_style), do: url()

  # Short and without retries: a notification is worth one attempt. Retrying it
  # in the background is how one failing endpoint turns into a queue of them.
  defp client do
    [
      retry: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(Application.get_env(:fanfarr, :notify_req_options, []))
    |> Req.new()
  end

  defp payload("ntfy", title, message, opts) do
    {[{"title", title}, {"priority", if(level(opts) == "error", do: "high", else: "default")}],
     message}
  end

  defp payload("discord", title, message, _opts) do
    {json_headers(), Jason.encode!(%{"content" => "#{title}\n#{message}"})}
  end

  defp payload("slack", title, message, _opts) do
    {json_headers(), Jason.encode!(%{"text" => "*#{title}*\n#{message}"})}
  end

  defp payload("gotify", title, message, opts) do
    body = %{
      "title" => title,
      "message" => message,
      # Gotify's own scale: 0 is silent, 10 is a shout. An error is meant to
      # interrupt; the rest is for reading later.
      "priority" => if(level(opts) == "error", do: 8, else: 4)
    }

    {[{"x-gotify-key", token()} | json_headers()], Jason.encode!(body)}
  end

  defp payload("json", title, message, opts) do
    body = %{
      "title" => title,
      "message" => message,
      "level" => level(opts),
      "source" => "fanfarr",
      "version" => Fanfarr.Version.display()
    }

    {json_headers(), Jason.encode!(body)}
  end

  defp json_headers, do: [{"content-type", "application/json"}]

  defp level(opts), do: if(Keyword.get(opts, :level, :info) == :error, do: "error", else: "info")
end
