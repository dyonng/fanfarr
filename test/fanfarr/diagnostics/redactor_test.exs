defmodule Fanfarr.Diagnostics.RedactorTest do
  @moduledoc """
  Everything the System page renders is assumed to end up in a bug report, so
  these are the tests that decide whether that page is safe to exist.
  """
  use Fanfarr.DataCase, async: false

  alias Fanfarr.Diagnostics.Redactor

  @token "xK7pQ2mNvR8sT4wY9zAb"

  setup do
    Redactor.forget_all()
    Fanfarr.Settings.put_setting!("plex_token", @token)
    # The cache is primed at boot, on save, and on every health tick; the
    # redactor never queries, because Ecto logs queries and a querying
    # redactor would recurse forever on a single log line.
    Redactor.prime()

    on_exit(fn ->
      System.delete_env("AUTH_PASSWORD")
      Redactor.forget_all()
    end)

    :ok
  end

  test "the stored Plex token is removed wherever it appears" do
    for text <- [
          "GET http://plex:32400/library/sections?X-Plex-Token=#{@token}",
          ~s(headers: [{"X-Plex-Token", "#{@token}"}]),
          # How it shows up in an Ecto parameter list, with no label at all.
          ~s|INSERT INTO settings VALUES ["plex_token", "#{@token}"]|
        ] do
      redacted = Redactor.redact(text)

      refute redacted =~ @token, "token survived in: #{redacted}"
      assert redacted =~ "[redacted]"
    end
  end

  test "the operator password from the environment is removed" do
    System.put_env("AUTH_PASSWORD", "correct-horse-battery")

    assert Redactor.redact("seeding user with correct-horse-battery") ==
             "seeding user with [redacted]"
  end

  test "a token belonging to someone else is removed by its label" do
    # Not a value this process knows; caught by the pattern instead.
    text = "https://other.example/x?X-Plex-Token=SOMEONE-ELSES-TOKEN&y=1"
    redacted = Redactor.redact(text)

    refute redacted =~ "SOMEONE-ELSES-TOKEN"
    assert redacted =~ "y=1", "the rest of the URL should survive"
  end

  test "labelled password and secret fields are removed" do
    assert Redactor.redact(~s(%{password: "hunter2222", user: "dyonng"})) =~ "dyonng"
    refute Redactor.redact(~s(%{password: "hunter2222", user: "dyonng"})) =~ "hunter2222"
    refute Redactor.redact("secret_key_base: AbCdEf123456789") =~ "AbCdEf123456789"
  end

  test "ordinary text is left alone" do
    text = "Sync finished: 742 items, 396 with a theme, 0 errors"
    assert Redactor.redact(text) == text
  end

  test "a short setting is not treated as a secret" do
    # Replacing a 3-character value would corrupt every log line containing it
    # while protecting nothing.
    Redactor.forget_all()
    Fanfarr.Settings.put_setting!("plex_token", "abc")
    Redactor.prime()
    assert Redactor.redact("the abc of it") == "the abc of it"
  end

  test "a rotated token is scrubbed, and the old one no longer needs to be" do
    # Secrets are read fresh; a cached list would scrub the old value and let
    # the new one straight through.
    Fanfarr.Settings.put_setting!("plex_token", "NEWTOKEN-abcdef123")
    Redactor.prime()
    refute Redactor.redact("token NEWTOKEN-abcdef123 here") =~ "NEWTOKEN-abcdef123"
  end

  test "non-binaries are inspected and scrubbed too" do
    redacted = Redactor.redact(%{plex_token: @token, url: "http://plex:32400"})
    refute redacted =~ @token
    assert redacted =~ "plex:32400"
  end
end
