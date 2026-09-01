defmodule Fanfarr.Settings do
  @moduledoc """
  Runtime configuration that can be changed from the dashboard.

  Follows the pattern already used elsewhere in this stack: environment
  variables supply the defaults, and a value set in the UI overrides them.
  That keeps a container runnable with no configuration at all while not
  forcing a restart to change a sync interval.
  """
  use Ash.Domain, otp_app: :fanfarr, extensions: [AshJsonApi.Domain]

  resources do
    resource Fanfarr.Settings.Setting do
      define :list_settings, action: :read
      define :put_setting, action: :put, args: [:key, :value]
      define :delete_setting, action: :destroy
    end
  end
end
