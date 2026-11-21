defmodule ApiaryWeb.RunLive.QueuedRestartTest do
  # The line of a queued run's page while the node stops (`Apiary.ModelKeys.Login.stopping?/0`)
  # and a sign-in of the run's provider is due for a refresh: it names the sign-in by its
  # identity line, as a link to the key's page at its row id. The state is the whole node's,
  # so the test is not async and sets the test function `stopping:` of
  # `Apiary.ModelKeys.Login`, which replaces the real check.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.ModelKeysFixtures, only: [key_value!: 2, device_login: 1, login_tokens: 1]
  import Apiary.NodesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelKeys.Login
  alias Apiary.Runs.Run

  @moduletag needs: [:factory, :secrets]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    workspace_gateway!(scope)
    pool = pool_fixture(scope, name: "build-pool")
    %{access_key: _key} = enrolled_key_fixture(scope, pool)
    previous = Application.get_env(:apiary, Login, [])
    on_exit(fn -> Application.put_env(:apiary, Login, previous) end)
    Application.put_env(:apiary, Login, Keyword.put(previous, :stopping, fn -> true end))
    :ok
  end

  test "names the sign-in by its identity line, as a link to its page", ctx do
    %{conn: conn, scope: scope} = ctx

    {:ok, provider} =
      Apiary.Connections.create_provider(scope, %{
        provider: "openai-subscription",
        name: "Team sign-ins",
        keys: [
          %{value: device_login(tokens: login_tokens(tag: "restart", expires_in: 3600))}
        ]
      })

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        runtime: "codex",
        model: "gpt-6-sol"
      })

    value = key_value!(provider, "key-1")
    work_item = work_item_fixture(scope, %{title: "Add currency to orders"})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()

    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
        set: [model_provider_ids: [provider.id]]
      )

    # A sign-in that expires in 10 minutes, with no refresh going on: due.
    Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
      set: [
        state: "signed_in",
        sign_in_cause: nil,
        signed_in_at: DateTime.add(DateTime.utc_now(), -3600),
        access_expires_at: DateTime.add(DateTime.utc_now(), 600),
        lease_id: nil,
        lease_until: nil
      ]
    )

    run = Repo.one!(from r in Run, where: r.dispatch_run_id == ^queued.id)

    {:ok, view, _html} =
      live(conn, "/#{scope.organisation.slug}/#{scope.workspace.slug}/runs/#{run.number}")

    render_async(view)

    identity = "Team sign-ins · dana@example.com"

    edit =
      ~p"/#{scope.organisation}/settings/model-providers/#{provider.public_id}/keys/#{value.id}/edit"

    why =
      view
      |> element("#prepare-machine-why")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

    assert why ==
             "Waiting for a model key: the server is restarting; the ChatGPT sign-in of #{identity} refreshes after it starts."

    assert has_element?(view, ~s{#prepare-machine-why a[href="#{edit}"]}, identity)
  end
end
