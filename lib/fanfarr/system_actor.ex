defmodule Fanfarr.SystemActor do
  @moduledoc """
  Who is acting when nobody is.

  Most of what this application does, it does on its own: it seeds the operator
  account at boot, it syncs a library on a schedule, it writes a theme file from
  a job. None of that has a signed-in person behind it, and Ash still wants an
  actor -- a resource with policies and no actor is denied, which is the correct
  default and was previously worked around with `authorize?: false`.

  That workaround is what this module exists to remove. `authorize?: false`
  switches authorization off for the duration of one call: the exemption cannot
  be reviewed, cannot be logged, and cannot be told apart from a mistake, because
  the reason a rule was skipped is simply absent from the code. A system actor is
  the same exemption written down. It is a value, it travels with the call, and
  the resources that honour it say so among their other policies.

  Use it only where there is genuinely no user to name. Anything reached from a
  request or a LiveView has an actor: the person who made it, and that is who the
  call should carry. `test/fanfarr/system_actor_test.exs` fails the build if
  `authorize?: false` reappears in `lib/`.

  ## The shape

  A map with a `:system` key holding the context the work was done for, which is
  what an Ash policy matches on:

      Ash.read!(query, actor: Fanfarr.SystemActor.new(:seed))

  and, on a resource that should permit it:

      bypass expr(not is_nil(^actor(:system))) do
        authorize_if always()
      end

  The context is a closed set of atoms rather than free text, so a policy or a
  log line can be read without guessing what it meant, and a typo is a compile
  error rather than a bypass nobody notices.
  """

  @type context ::
          :seed | :config | :auth | :scheduler | :library | :themes | :overview

  @type t :: %{system: context()}

  @doc """
  The actor for work done on the application's own behalf, in `context`.

  Named at each call site on purpose: which part of the application is asking
  is the thing worth knowing when reading it back later.
  """
  @spec new(context()) :: t()
  def new(context) when is_atom(context), do: %{system: context}
end
