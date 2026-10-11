defmodule ApiaryWeb.SettingsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
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

  describe "the Workspaces list" do
    # A reader the edition lets rename a workspace and not delete one, as no level of the
    # core's edition is: the list without Delete… and without the deletion's note.
    defp workspaces do
      for {name, slug} <- [{"Main", "main"}, {"Staging", "staging"}] do
        %Workspace{
          id: Ecto.UUID.generate(),
          name: name,
          slug: slug,
          inserted_at: ~U[2026-10-01 09:00:00Z]
        }
      end
    end

    defp list(may_delete) do
      assigns = %{
        scope: %Scope{organisation: %Organisation{id: Ecto.UUID.generate(), slug: "acme"}},
        workspaces: workspaces(),
        may_delete: may_delete
      }

      rendered_to_string(~H"""
      <SettingsComponents.workspace_list
        scope={@scope}
        workspaces={@workspaces}
        may_delete={@may_delete}
      />
      """)
    end

    test "offers Delete… and says what a deletion does to a reader who may delete" do
      html = list(true)

      assert html =~ ~s(href="/acme/main")
      assert html =~ ~s(href="/acme/staging")
      assert html =~ "Delete…"
      assert html =~ ~s(id="workspaces-note")
      assert html =~ "A deleted workspace is purged after"
    end

    test "lists the workspaces without Delete…, its menu or its note to one who may not delete" do
      html = list(false)

      assert html =~ ~s(href="/acme/main")
      assert html =~ ~s(href="/acme/staging")
      refute html =~ "Delete…"
      refute html =~ "q-rowmenu"
      refute html =~ ~s(id="workspaces-note")
      refute html =~ "A deleted workspace is purged after"
    end
  end
end
