defmodule ApiaryWeb.SecretLive.InUseTest do
  # Not async: what uses a secret is the node's answer, set for a test and put back after
  # it (`Apiary.Secrets.Usage`).
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Secrets
  alias Apiary.Secrets.Usage

  @moduletag needs: :secrets

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
        case secret.name do
          "FORGE_TOKEN" ->
            [%{kind: :integration, id: "int_0123456789abcdef", name: "Example", value_id: nil}]

          # As a model provider uses the secret of its keys, and its default key.
          "MODEL_KEYS" ->
            [
              %{
                kind: :model_provider,
                id: "con_0123456789abcdef",
                name: "Example Models",
                value_id: "main"
              }
            ]

          _other ->
            []
        end
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

    # What uses it is cut to its column, the whole of it in its title.
    assert has_element?(
             lv,
             "#secret-#{secret.public_id}-used-by.q-cut[title='Example']",
             "Example"
           )

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

  test "a model provider's keys say to remove the provider, or to choose another default key",
       %{conn: conn, scope: scope} do
    {:ok, secret} =
      Secrets.create_secret(scope, %{
        name: "MODEL_KEYS",
        values: [%{value_id: "main", value: "x"}, %{value_id: "spare", value: "y"}]
      })

    path = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets"

    {:ok, lv, _html} = live(conn, path <> "/#{secret.public_id}/delete")
    lv |> element("#secret-#{secret.public_id}-confirm button", "Yes, delete") |> render_click()

    assert has_element?(
             lv,
             "#secret-#{secret.public_id}-confirm #secret-refused[role=alert]",
             "Remove the model provider Example Models first: MODEL_KEYS has the provider's keys."
           )

    refute render(lv) =~ "unlink it there first"

    {:ok, lv, _html} = live(conn, path <> "/#{secret.public_id}/values/main/delete")

    lv
    |> element("#secret-#{secret.public_id}-main-confirm button", "Yes, delete")
    |> render_click()

    assert has_element?(
             lv,
             "#secret-#{secret.public_id}-main-confirm #secret-refused[role=alert]",
             "Choose another default key for Example Models first: main is its default key."
           )

    {:ok, lv, _html} = live(conn, path <> "/#{secret.public_id}/values/main/rename")
    lv |> form("#secret-form", secret_value: %{value_id: "first"}) |> render_submit()

    assert has_element?(
             lv,
             "#flash-error",
             "Choose another default key for Example Models first: main is its default key."
           )

    assert has_element?(lv, "#secret-form")

    # The value that is not the default key goes.
    {:ok, lv, _html} = live(conn, path <> "/#{secret.public_id}/values/spare/delete")

    lv
    |> element("#secret-#{secret.public_id}-spare-confirm button", "Yes, delete")
    |> render_click()

    assert render(lv) =~ "spare is deleted from MODEL_KEYS."

    assert {:ok, [%{values: [%{value_id: "main"}]}]} = Secrets.list_secrets(scope)
  end
end
