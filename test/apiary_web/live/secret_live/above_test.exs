defmodule ApiaryWeb.SecretLive.AboveTest do
  # Not async: the level above is the edition's answer, set for a test through the
  # configuration `Apiary.Policy.Above.for_workspace/1` reads, and put back after it.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Policy.Above
  alias Apiary.Variables
  alias Apiary.Variables.Variable

  @moduletag needs: :secrets

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:apiary, Above)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Above, previous),
        else: Application.delete_env(:apiary, Above)
    end)
  end

  test "a value a lock above sets aside says so in words that break onto further lines",
       %{conn: conn, scope: scope} do
    # Set in the workspace first: once the level above locks the name, no level below
    # sets it.
    {:ok, variable} =
      Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "production"})

    Application.put_env(:apiary, Above,
      answer: fn _workspace ->
        %Above{
          id: Ecto.UUID.generate(),
          name: "Example level",
          slug: "example",
          policy: false,
          variables: [%Variable{name: "NODE_ENV", value: "staging", locked: true}]
        }
      end
    )

    path = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/variables"
    {:ok, lv, _html} = live(conn, path)

    # Only this state word wraps: the table stays in its box rather than widen for it.
    assert has_element?(
             lv,
             "#variable-#{variable.id}-lock.q-stw.q-stw-wrap",
             "Set aside: locked above the workspace"
           )

    assert has_element?(lv, "#variables .q-stw-wrap")
    refute has_element?(lv, "#variables .q-stw-wrap:not(#variable-#{variable.id}-lock)")
  end
end
