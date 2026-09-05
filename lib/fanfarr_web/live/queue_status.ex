defmodule FanfarrWeb.QueueStatus do
  @moduledoc """
  Keeps every page's idea of the queue current, so the widget can live in the
  layout.

  Mounted as a hook rather than a nested LiveView. A nested LiveView would
  mean a second process, its own mount and its own supervision on every page,
  and the hook does the same job by attaching to the timer each page already
  runs.

  The poll is what makes the widget honest. Oban jobs change state in whatever
  process happens to be running them, and nothing broadcasts when one finishes
  -- the same race that left an item page insisting it was still working ten
  minutes after the job had ended.

  ## Why the open/closed state lives here

  The widget expands into a list of the queue, and it is rendered from the
  layout, which every page shares. Its toggle therefore cannot be a
  `handle_event/3` on any one LiveView -- it would have to be repeated on all
  of them. So this hook owns the event as well as the data, and a page still
  only has to render `Layouts.app`.

  The list is fetched only while the widget is open. Closed, it is two
  integers; polling a job list every three seconds on every page to render
  nothing would be the wrong trade.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  @poll_ms 3_000

  # Enough to show what is running and a sense of what is behind it, without
  # turning a corner widget into the Activity page. The total is shown
  # alongside, so a cropped list never reads as the whole queue.
  @visible_jobs 8

  @doc "The shape `Layouts.app` renders. One assign rather than five attrs."
  @spec empty() :: map()
  def empty, do: %{summary: %{running: 0, queued: 0}, open: false, jobs: [], total: 0, eta: nil}

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:queue, empty())
      |> refresh()
      |> attach_hook(:queue_poll, :handle_info, &handle_poll/2)
      |> attach_hook(:queue_toggle, :handle_event, &handle_toggle/3)

    if connected?(socket), do: Process.send_after(self(), :poll_queue_status, @poll_ms)

    {:cont, socket}
  end

  defp handle_poll(:poll_queue_status, socket) do
    Process.send_after(self(), :poll_queue_status, @poll_ms)
    {:halt, refresh(socket)}
  end

  # Anything else is the page's own business.
  defp handle_poll(_message, socket), do: {:cont, socket}

  defp handle_toggle("toggle_queue_widget", _params, socket) do
    open? = !socket.assigns.queue.open

    {:halt, socket |> assign(:queue, %{socket.assigns.queue | open: open?}) |> refresh()}
  end

  defp handle_toggle(_event, _params, socket), do: {:cont, socket}

  defp refresh(socket) do
    queue = socket.assigns.queue
    queue = %{queue | summary: Fanfarr.Jobs.summary()}

    queue =
      if queue.open do
        %{
          queue
          | jobs: Fanfarr.Jobs.active(@visible_jobs),
            total: Fanfarr.Jobs.total_active(),
            eta: Fanfarr.Jobs.eta_seconds()
        }
      else
        %{queue | jobs: [], total: 0, eta: nil}
      end

    assign(socket, :queue, queue)
  end
end
