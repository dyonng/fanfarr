defmodule FanfarrWeb.VendorSaladUITest do
  @moduledoc """
  Guards the vendored SaladUI components (lib/fanfarr_web/components/vendor).

  We took a copy rather than a dependency, so nothing upstream will tell us if
  a component stops rendering -- this is that signal.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  test "a variant-styled button renders with its computed classes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SaladUI.Button.button variant="destructive" size="sm">Delete</SaladUI.Button.button>
      """)

    assert html =~ "Delete"
    assert html =~ "<button"
    # tw_merge resolved the variant into real utility classes
    assert html =~ "bg-destructive"
  end

  test "a table renders its structural elements" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <SaladUI.Table.table>
        <SaladUI.Table.table_body>
          <SaladUI.Table.table_row>
            <SaladUI.Table.table_cell>One Piece</SaladUI.Table.table_cell>
          </SaladUI.Table.table_row>
        </SaladUI.Table.table_body>
      </SaladUI.Table.table>
      """)

    assert html =~ "<table"
    assert html =~ "One Piece"
  end
end
