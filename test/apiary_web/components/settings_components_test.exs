defmodule ApiaryWeb.SettingsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.SettingsComponents

  # A button's words, and its words while it acts.
  defp button(html, id) do
    doc = LazyHTML.from_fragment(html)
    text = &(doc |> LazyHTML.query("##{id} #{&1}") |> LazyHTML.text() |> String.trim())
    {text.(".btn-label"), text.(".btn-busy")}
  end

  describe "a deletion's confirmation" do
    test "says Yes, delete and Deleting unless given its own words" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SettingsComponents.deletion_confirm
          id="delete-secret"
          question="Delete FORGE_TOKEN?"
          submit="delete"
          cancel="/acme/shop/settings/secrets"
        />
        """)

      assert {"Yes, delete", "Deleting"} = button(html, "delete-secret-confirm")

      html =
        rendered_to_string(~H"""
        <SettingsComponents.deletion_confirm
          id="remove-runtime"
          question="Remove the runtime?"
          submit="remove"
          cancel="/acme/shop/settings/integrations"
          confirm_label="Yes, remove"
          busy_label="Removing"
        />
        """)

      assert {"Yes, remove", "Removing"} = button(html, "remove-runtime-confirm")
    end

    test "a danger zone's line passes its words on to its confirmation" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SettingsComponents.danger_action
          id="remove-integration"
          title="Remove this integration"
          button="Remove…"
          open
          open_path="/acme/shop/settings/integrations/1/remove"
          close_path="/acme/shop/settings/integrations/1"
          question="Remove the integration?"
          submit="remove"
          confirm_label="Yes, remove"
          busy_label="Removing"
        >
          Its runtimes stop.
        </SettingsComponents.danger_action>
        """)

      assert {"Yes, remove", "Removing"} = button(html, "remove-integration-confirm")
    end
  end
end
