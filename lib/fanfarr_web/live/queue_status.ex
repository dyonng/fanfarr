defmodule FanfarrWeb.QueueStatus do
  @moduledoc """
  Keeps every page's idea of the queue current, so the widget can live in the
  layout.

  Mounted as a hook rather than a nested LiveView. The widget is two integers
  and a link; a nested LiveView for that would mean a second process, its own
  mount and its own supervision on every page, and the hook does the same job
  by attaching to the timer each page already runs.

  The poll is what makes the widget honest. Oban jobs change state in whatever
  process happens to be running them, and nothing broadcasts when one finishes
  -- the same race that left an item page insisting it was still working ten
  minutes after the job had ended.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  @poll_ms 3_000

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:queue_summary, Fanfarr.Jobs.summary())
      |> attach_hook(:queue_poll, :handle_info, &handle_poll/2)

    if connected?(socket), do: Process.send_after(self(), :poll_queue_status, @poll_ms)

    {:cont, socket}
  end

  defp handle_poll(:poll_queue_status, socket) do
    Process.send_after(self(), :poll_queue_status, @poll_ms)
    {:halt, assign(socket, :queue_summary, Fanfarr.Jobs.summary())}
  end

  # Anything else is the page's own business.
  defp handle_poll(_message, socket), do: {:cont, socket}
end
