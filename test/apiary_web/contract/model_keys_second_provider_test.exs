defmodule ApiaryWeb.Contract.ModelKeysSecondProviderTest do
  # The `unauthorized` list of a gateway's model keys report (`POST /v1/runs/<id>/model-keys`)
  # for a run that has the keys of two providers: an API key of the first and a sign-in
  # (`Apiary.ModelKeys.Login`) of the second. The sign-in of the second provider is read
  # as a sign-in, as the report of a run of one provider reads it
  # (`Apiary.ModelKeys.reject/3`): a token that a refresh may renew marks nothing, and a
  # 401 for the current token marks the key. Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, Repo}
  alias Apiary.ModelKeys.{Login, Rejection}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets, :observability]
  setup {Apiary.DataCase, :without_registry}

  # The run's keys: an API key of its provider, which the claim stored, and the key
  # `second-1` of a sign-in of another provider, whose copy the run kept with the token of
  # `signed_in` seconds from now.
  defp two_providers!(signed_in) do
    %{scope: scope} = sign_up_fixture()
    ctx = sealed_run_fixture(scope)

    {:ok, second} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: login_tokens(expires_in: 3600))}]
      })

    value = Repo.one!(from v in Value, where: v.secret_id == ^second.secret_id)

    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), signed_in)]
      )

    [key] =
      [
        %{
          provider: second,
          secret_value_id: value.id,
          name: "second-1",
          position: 2,
          default_credential: false
        }
      ]
      |> then(&run_keys!(ctx.run, &1))
      |> Enum.filter(&(&1.name == "second-1"))

    login = Repo.get_by!(Login, secret_value_id: value.id)

    :ok =
      Apiary.ModelKeys.keep_copies(ctx.run.id, [
        {value.id, value.value_set_at, login.signed_in_at}
      ])

    Map.merge(ctx, %{key: key, value: value})
  end

  defp at(offset),
    do:
      DateTime.utc_now()
      |> DateTime.add(offset)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  # The model keys report, with a 401 of the sign-in's key at `at`.
  defp report(ctx, at) do
    members = [
      version: 1,
      run_id: ctx.run.node_run_id,
      time: at(0),
      keys: [],
      unauthorized: [%{"credential" => ctx.key.name, "at" => at}]
    ]

    {key, seed} = ctx.secrets_key

    signed_post(
      build_conn(),
      key.key_id,
      seed,
      Jason.encode!(Jason.OrderedObject.new(members)),
      target: "/v1/runs/#{ctx.run.node_run_id}/model-keys",
      content_type: "application/json",
      delivery: nil
    )
  end

  test "a 401 of a sign-in of the second provider that a refresh may renew marks nothing" do
    ctx = two_providers!(-3600)

    assert report(ctx, at(5)).status == 200
    assert Repo.all(Rejection) == []
  end

  test "a 401 of a sign-in of the second provider for the current token marks the key" do
    ctx = two_providers!(0)

    assert report(ctx, at(5)).status == 200
    assert [%Rejection{secret_value_id: id}] = Repo.all(Rejection)
    assert id == ctx.value.id
  end
end
