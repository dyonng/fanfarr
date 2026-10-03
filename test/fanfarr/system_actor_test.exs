defmodule Fanfarr.SystemActorTest do
  @moduledoc """
  Authorization is enforced, and the system actor is how internal work passes it.

  Three things are asserted here, and they are the same rule seen from different
  sides.

  Application code does not switch authorization off. Doing so makes an
  exemption invisible: it cannot be reviewed, logged, or told apart from a
  mistake, because the reason a rule was skipped is absent from the code. Work
  with no user behind it names the system instead, and the resources that permit
  it say so among their other policies.

  That actor is actually checked. A resource with policies refuses a call with no
  actor, so the system actor is not a comment on the call -- it is the thing that
  lets it through, and if this ever passes without one, a policy stopped
  applying somewhere.

  And the shape is what the policies match on, so a change to it is a change to
  every bypass in the application.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Accounts.User
  alias Fanfarr.SystemActor

  describe "the system actor" do
    test "is what makes an internal call to a policied resource legal" do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(User)

      assert {:ok, users} = Ash.read(User, actor: SystemActor.new(:seed))
      assert is_list(users)
    end

    test "carries the context the work was done for" do
      assert SystemActor.new(:seed) == %{system: :seed}
      assert SystemActor.new(:scheduler)[:system] == :scheduler
    end
  end

  describe "the rule itself" do
    test "no application code switches authorization off" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _number} -> switches_authorization_off?(line) end)
          |> Enum.map(fn {line, number} ->
            "  #{Path.relative_to_cwd(file)}:#{number}: #{String.trim(line)}"
          end)
        end)

      assert offenders == [], """
      Authorization is switched off in application code:

      #{Enum.join(offenders, "\n")}

      Pass the caller's actor (`actor: current_user`) where a person made the
      request, or `Fanfarr.SystemActor.new(:context)` where the application is
      acting on its own behalf, and permit the system on the resource with:

          bypass expr(not is_nil(^actor(:system))) do
            authorize_if always()
          end
      """
    end
  end

  # A line that turns authorization off, rather than one that talks about it.
  #
  # The distinction matters because the rule is explained in several places, and
  # those explanations have to be able to name the thing they are warning about.
  # Two things separate the code from the prose, and both are reliable in this
  # codebase: prose about it is written in comments, and inline code in prose is
  # wrapped in backticks.
  defp switches_authorization_off?(line) do
    trimmed = String.trim_leading(line)

    not String.starts_with?(trimmed, "#") and
      not String.starts_with?(trimmed, "\"") and
      Regex.match?(~r/(?<!`)authorize\?: false/, line)
  end
end
