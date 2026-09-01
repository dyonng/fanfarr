defmodule Fanfarr.Settings.Setting do
  @moduledoc """
  One overridable setting.

  Values are stored as strings and cast on read. A typed column per setting
  would mean a migration every time one is added, which is the wrong trade for
  configuration that changes shape as features land.

  A row exists only when the operator has actually overridden something. An
  absent row means "use the environment default", which keeps the distinction
  between *unset* and *set to the same value as the default* -- they behave
  identically now but differ the moment a default changes.
  """
  use Ash.Resource,
    otp_app: :fanfarr,
    domain: Fanfarr.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "settings"
    repo Fanfarr.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:key, :value]

    create :create do
      primary? true
      accept [:key, :value]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:value]
    end

    create :put do
      upsert? true
      upsert_identity :unique_key
      accept [:key, :value]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true

    attribute :value, :string do
      public? true
      description "Stored as a string; the reader casts. Nil clears the override."
    end

    timestamps()
  end

  identities do
    identity :unique_key, [:key]
  end
end
