defmodule ApiaryWeb.SecretLive.InUseTest do
  # Not async: what uses a secret is the node's answer, set for a test and put back after
  # it (`Apiary.Secrets.Usage`).
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Secrets
  alias Apiary.Secrets.Usage

  @moduletag needs: :security

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:apiary, Usage)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Usage, previous),
        else: Application.delete_env(:apiary, Usage)
    end)

    Application.put_env(:apiary, Usage,
      answer: fn _repo, secret ->
        if secret.name == "FORGE_TOKEN",
          do: [%{kind: :integration, id: "int_0123456789abcdef", name: "Example", value_id: nil}],
          else: []
      end
    )
  end

  test "a secret says what uses it, and is not deleted while it is used",
       %{conn: conn, scope: scope} do
    {:ok, secret} = Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "x"})
    path = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets"

    {:ok, lv, _html} = live(conn, path)
    assert has_element?(lv, "#secret-#{secret.public_id}", "Example")
    refute has_element?(lv, "#secret-#{secret.public_id}", "Not used")

    {:ok, lv, _html} = live(conn, path <> "/#{secret.public_id}/delete")
    lv |> element("#secret-#{secret.public_id}-confirm button", "Yes, delete") |> render_click()

    # Refused, the confirmation stays open, and says why under its question.
    assert has_element?(
             lv,
             "#secret-#{secret.public_id}-confirm #secret-refused[role=alert]",
             "FORGE_TOKEN is used by Example: unlink it there first."
           )

    assert has_element?(lv, "#secret-#{secret.public_id}-confirm button", "Yes, delete")
    refute has_element?(lv, "#flash-error")
    assert {:ok, [_secret]} = Secrets.list_secrets(scope)
  end
end
