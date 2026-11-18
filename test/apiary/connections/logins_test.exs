defmodule Apiary.Connections.LoginsTest do
  # The keys of a model provider whose API has `oauth_refresh`, an OpenAI subscription:
  # a pasted `auth.json` is stored as the key's value in a document of the three tokens,
  # with a row for the key's sign-in (`Apiary.ModelKeys.Login`), by every function that
  # writes a key; a paste that is no login is refused with no key written; the secrets
  # endpoint's read refuses the key (`{:error, :login}`); a refreshed document replaces
  # the value and keeps its states and copies. No token reaches a log line, an audit entry
  # or an error.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, ModelKeys, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Copy, Login}
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp subscription!(scope, tokens \\ login_tokens(), place \\ :organisation) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{
          provider: "openai-subscription",
          keys: [%{value_id: "main", value: login_paste(tokens: tokens)}]
        },
        place
      )

    provider
  end

  defp row(provider, value_id), do: Login.by_key(provider)[key_value!(provider, value_id).id]

  defp stored(provider, value_id) do
    provider = Repo.get!(Connection, provider.id)
    assert {:ok, tokens} = Login.tokens(provider, key_value!(provider, value_id).id)
    tokens
  end

  defp trail(provider),
    do: Repo.all(from e in Entry, where: e.organisation_id == ^provider.organisation_id)

  # Every token of `tokens` and the paste's text, as strings to look for.
  defp secrets_of(tokens),
    do: [tokens.access_token, tokens.refresh_token, tokens.id_token, "auth_mode"]

  defp refute_leaks(text, tokens) do
    for secret <- secrets_of(tokens), do: refute(text =~ secret)
  end

  describe "creating a provider" do
    test "stores the tokens as the key's value and writes its sign-in", %{scope: scope} do
      tokens = login_tokens(exp: 1_800_000_000)

      log = capture_log(fn -> send(self(), {:provider, subscription!(scope, tokens)}) end)
      assert_received {:provider, provider}

      assert %Login{
               account_id: "acct-fixture-a",
               access_expires_at: ~U[2027-01-15 08:00:00.000000Z],
               state: "signed_in",
               sign_in_cause: nil,
               refreshed_at: nil,
               failures: 0,
               retry_at: nil,
               last_failure: nil,
               generation: 1,
               lease_id: nil,
               lease_until: nil,
               organisation_id: organisation_id,
               signed_in_at: %DateTime{}
             } = row(provider, "main")

      assert organisation_id == scope.organisation.id

      assert stored(provider, "main") == %{
               access_token: tokens.access_token,
               refresh_token: tokens.refresh_token,
               id_token: tokens.id_token
             }

      refute_leaks(log, tokens)
    end

    test "stores no more than the tokens", %{scope: scope} do
      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      value = key_value!(provider, "main")

      {:ok, document} = Secrets.reveal_login(plain, value.id)

      assert document |> Jason.decode!() |> Map.keys() |> Enum.sort() ==
               ~w(access_token id_token refresh_token version)
    end

    test "refuses a paste that is no login, and creates nothing", %{scope: scope} do
      before = Repo.aggregate(Connection, :count)

      for {text, message} <- [
            {"sk-proj-an-api-key", "Paste the whole auth.json that codex login wrote."},
            {"", "can't be blank"},
            {Jason.encode!(%{"tokens" => %{"refresh_token" => "r", "access_token" => "a"}}),
             "Paste the whole auth.json that codex login wrote."}
          ] do
        log =
          capture_log(fn ->
            assert {:error, %Ecto.Changeset{data: %Secret{}} = changeset} =
                     Connections.create_provider(scope, %{
                       provider: "openai-subscription",
                       keys: [%{value_id: "main", value: text}]
                     })

            assert message in values_errors(changeset)
            refute inspect(changeset) =~ "sk-proj-an-api-key"
          end)

        refute log =~ "sk-proj-an-api-key"
      end

      assert Repo.aggregate(Connection, :count) == before
      assert Repo.all(Login) == []
    end

    test "tells a login without a refresh token from any other paste", %{scope: scope} do
      no_refresh =
        login_paste()
        |> Jason.decode!()
        |> update_in(["tokens"], &Map.delete(&1, "refresh_token"))
        |> Jason.encode!()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Connections.create_provider(scope, %{
                 provider: "openai-subscription",
                 keys: [%{value_id: "main", value: no_refresh}]
               })

      assert "Paste the whole auth.json that codex login wrote. This text has no refresh token." in values_errors(
               changeset
             )
    end

    test "stores a workspace's login under the workspace's key", %{scope: scope} do
      tokens = login_tokens(tag: "w")
      provider = subscription!(scope, tokens, :workspace)

      assert %Login{account_id: "acct-fixture-w"} = row(provider, "main")
      assert stored(provider, "main").refresh_token == tokens.refresh_token
    end

    test "writes a row for each of several keys", %{scope: scope} do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [
            %{value_id: "main", value: login_paste(tag: "m")},
            %{value_id: "spare", value: login_paste(tag: "s")}
          ]
        })

      assert %Login{account_id: "acct-fixture-m"} = row(provider, "main")
      assert %Login{account_id: "acct-fixture-s"} = row(provider, "spare")
    end

    test "leaves the keys of any other provider as they are", %{scope: scope} do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      assert Login.by_key(provider) == %{}

      assert Secrets.reveal_key_for_sealing(
               Repo.get!(Connection, provider.id),
               key_value!(provider, "main").id
             ) == {:ok, "sk-proj-an-api-key"}

      assert Repo.all(Login) == []
    end
  end

  describe "adding a key" do
    test "stores the tokens and writes the key's sign-in", %{scope: scope} do
      provider = subscription!(scope)
      tokens = login_tokens(tag: "b")

      assert {:ok, _} =
               Connections.add_provider_key(scope, provider, %{
                 value_id: "spare",
                 value: "  " <> login_paste(tokens: tokens) <> "\n"
               })

      assert %Login{account_id: "acct-fixture-b", generation: 1} = row(provider, "spare")
      assert stored(provider, "spare").refresh_token == tokens.refresh_token
      assert row(provider, "main").account_id == "acct-fixture-a"
    end

    test "refuses a paste that is no login with the error on value, and adds nothing", %{
      scope: scope
    } do
      provider = subscription!(scope)

      for {text, message} <- [
            {"sk-proj-an-api-key", "Paste the whole auth.json that codex login wrote."},
            {"", "can't be blank"}
          ] do
        log =
          capture_log(fn ->
            assert {:error, %Ecto.Changeset{errors: [value: {^message, _}]} = changeset} =
                     Connections.add_provider_key(scope, provider, %{
                       value_id: "spare",
                       value: text
                     })

            refute inspect(changeset) =~ "sk-proj-an-api-key"
          end)

        refute log =~ "sk-proj-an-api-key"
      end

      assert [%{value_id: "main"}] =
               Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)

      assert map_size(Login.by_key(provider)) == 1
    end

    test "writes the settings and the sign-in in one transaction", %{scope: scope} do
      provider = subscription!(scope)

      assert {:error, %Ecto.Changeset{}} =
               Connections.add_provider_key(
                 scope,
                 provider,
                 %{value_id: "spare", value: login_paste(tag: "b")},
                 %{"pause_seconds" => 604_801}
               )

      assert map_size(Login.by_key(provider)) == 1
      refute Enum.any?(Repo.all(Value), &(&1.value_id == "spare"))
    end
  end

  describe "setting a key's value" do
    test "replaces the tokens, clears the states and starts a new sign-in", %{scope: scope} do
      provider = subscription!(scope)
      value = key_value!(provider, "main")
      key_state!(provider, "main", until: in_seconds(3600))
      assert ModelKeys.provider_states(provider, DateTime.utc_now())[value.id] != nil

      # A sign-in the provider rejected, with a refresh in flight.
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          failures: 3,
          retry_at: in_seconds(600),
          last_failure: DateTime.utc_now(),
          lease_id: Ecto.UUID.generate(),
          lease_until: in_seconds(60),
          refreshed_at: DateTime.utc_now()
        ]
      )

      tokens = login_tokens(tag: "new")

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Connections.set_provider_key(
                     scope,
                     provider,
                     "main",
                     login_paste(tokens: tokens)
                   )
        end)

      assert %Login{
               state: "signed_in",
               sign_in_cause: nil,
               failures: 0,
               retry_at: nil,
               last_failure: nil,
               lease_id: nil,
               lease_until: nil,
               refreshed_at: nil,
               generation: 2,
               account_id: "acct-fixture-new"
             } = row(provider, "main")

      assert stored(provider, "main").refresh_token == tokens.refresh_token
      assert ModelKeys.provider_states(provider, DateTime.utc_now())[value.id] == nil

      assert List.last(Enum.sort_by(trail(provider), & &1.inserted_at)).details["value_set"] ==
               true

      refute_leaks(log, tokens)
    end

    test "refuses a paste that is no login, and leaves the key, its states and its sign-in", %{
      scope: scope
    } do
      tokens = login_tokens()
      provider = subscription!(scope, tokens)
      value = key_value!(provider, "main")
      key_state!(provider, "main", until: in_seconds(3600))

      assert {:error, %Ecto.Changeset{errors: [value: {message, _}]}} =
               Connections.set_provider_key(scope, provider, "main", "sk-proj-an-api-key")

      assert message == "Paste the whole auth.json that codex login wrote."
      assert %Login{generation: 1} = row(provider, "main")
      assert stored(provider, "main").refresh_token == tokens.refresh_token
      assert ModelKeys.provider_states(provider, DateTime.utc_now())[value.id] != nil
    end
  end

  describe "updating a key" do
    test "with a new value replaces the tokens; without one keeps the sign-in", %{scope: scope} do
      provider = subscription!(scope)
      tokens = login_tokens(tag: "u")

      assert {:ok, _} =
               Connections.update_provider_key(scope, provider, "main", %{
                 "value_id" => "main",
                 "value" => login_paste(tokens: tokens),
                 "settings" => %{"pause_seconds" => 7200}
               })

      assert %Login{generation: 2, account_id: "acct-fixture-u"} = row(provider, "main")

      assert {:ok, _} =
               Connections.update_provider_key(scope, provider, "main", %{
                 "value_id" => "main",
                 "value" => "  ",
                 "settings" => %{"pause_seconds" => 3600}
               })

      assert %Login{generation: 2} = row(provider, "main")
      assert stored(provider, "main").refresh_token == tokens.refresh_token
    end

    test "refuses a new value that is no login", %{scope: scope} do
      provider = subscription!(scope)

      assert {:error, %Ecto.Changeset{errors: [value: {message, _}]}} =
               Connections.update_provider_key(scope, provider, "main", %{
                 "value_id" => "renamed",
                 "value" => "sk-proj-an-api-key"
               })

      assert message =~ "auth.json"
      assert Repo.get_by(Value, secret_id: provider.secret_id).value_id == "main"
    end

    test "a rename keeps the sign-in and its tokens", %{scope: scope} do
      tokens = login_tokens()
      provider = subscription!(scope, tokens)
      value = key_value!(provider, "main")

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tag: "s")
        })

      {:ok, provider} = Connections.put_default_key(scope, provider, "spare")

      assert {:ok, _} = Connections.rename_provider_key(scope, provider, "main", "renamed")

      assert %Login{generation: 1} = Login.by_key(provider)[value.id]
      assert stored(provider, "renamed").refresh_token == tokens.refresh_token
    end

    test "deleting the key deletes its sign-in", %{scope: scope} do
      provider = subscription!(scope)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tag: "s")
        })

      assert map_size(Login.by_key(provider)) == 2
      assert {:ok, _} = Connections.delete_provider_key(scope, provider, "spare")
      assert [%Login{account_id: "acct-fixture-a"}] = Repo.all(Login)
    end
  end

  describe "the audit trail" do
    test "has no token, and no account", %{scope: scope} do
      tokens = login_tokens(tag: "t")
      provider = subscription!(scope, tokens)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tokens: tokens)
        })

      {:ok, _provider} =
        Connections.set_provider_key(scope, provider, "spare", login_paste(tokens: tokens))

      entries = trail(provider)
      assert length(entries) >= 3

      text = inspect(entries, limit: :infinity, printable_limit: :infinity)
      refute_leaks(text, tokens)
      refute text =~ "acct-fixture-t"
    end
  end

  describe "revealing a key for sealing" do
    test "refuses the key of a provider whose keys are logins, with or without its row", %{
      scope: scope
    } do
      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      value = key_value!(provider, "main")

      assert Secrets.reveal_key_for_sealing(plain, value.id) == {:error, :login}
      assert Secrets.reveal_key_and_set_at(plain, value.id) == {:error, :login}

      Repo.delete_all(Login)
      assert Secrets.reveal_key_for_sealing(plain, value.id) == {:error, :login}
    end

    test "reveal_login/2 is for a provider of logins alone", %{scope: scope} do
      {:ok, api} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      assert Secrets.reveal_login(Repo.get!(Connection, api.id), key_value!(api, "main").id) ==
               {:error, :not_found}

      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      assert Secrets.reveal_login(plain, Ecto.UUID.generate()) == {:error, :not_found}
      assert Secrets.reveal_login(plain, "not-an-id") == {:error, :not_found}
    end
  end

  describe "writing a refreshed value" do
    defp refreshed(tokens),
      do:
        Jason.encode!(%{
          "version" => 1,
          "access_token" => tokens.access_token,
          "refresh_token" => tokens.refresh_token,
          "id_token" => tokens.id_token
        })

    test "keeps the copies that runs hold of the value", %{scope: scope} do
      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      value = key_value!(provider, "main")
      pool = Apiary.NodesFixtures.pool_fixture(scope)
      %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)

      %{run: run} =
        Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, key, %{
          provider_connection_id: provider.id,
          provider_secret_id: provider.secret_id,
          provider_chain: "organisation",
          provider_api: %{
            "format" => "openai-responses",
            "endpoint" => "https://api.model.example/openai",
            "auth" => %{"scheme" => "bearer", "oauth" => true}
          },
          model_keys: [%{"id" => value.id, "name" => "model-1", "pause_for_s" => 3600}],
          run_settings: %{}
        })

      :ok = ModelKeys.keep_copies(run.id, [{value.id, value.value_set_at}])
      next = login_tokens(tag: "copies")

      assert Secrets.write_refreshed_key(plain, value.id, refreshed(next)) == :ok

      assert [%{copy_kept: true, copy_set_at: copy_set_at}] = ModelKeys.run_keys(run)
      assert copy_set_at == Repo.get!(Value, value.id).value_set_at
      assert %Copy{value_set_at: ^copy_set_at} = Repo.get_by!(Copy, run_id: run.id)
    end

    test "keeps value_set_at, the states and the sign-in's generation", %{scope: scope} do
      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      value = key_value!(provider, "main")
      key_state!(provider, "main", until: in_seconds(3600))
      next = login_tokens(tag: "refreshed")

      assert Secrets.write_refreshed_key(plain, value.id, refreshed(next)) == :ok

      after_write = Repo.get!(Value, value.id)
      assert after_write.value_set_at == value.value_set_at
      assert after_write.updated_at == value.updated_at
      assert after_write.updated_by_id == value.updated_by_id
      assert after_write.ciphertext != value.ciphertext

      assert stored(provider, "main").refresh_token == next.refresh_token
      assert ModelKeys.provider_states(provider, DateTime.utc_now())[value.id] != nil
      assert %Login{generation: 1} = row(provider, "main")
    end

    test "encrypts under the value id the key has now", %{scope: scope} do
      provider = subscription!(scope)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tag: "s")
        })

      value = key_value!(provider, "spare")
      {:ok, provider} = Connections.rename_provider_key(scope, provider, "spare", "renamed")
      plain = Repo.get!(Connection, provider.id)
      next = login_tokens(tag: "after-rename")

      assert Secrets.write_refreshed_key(plain, value.id, refreshed(next)) == :ok
      assert stored(provider, "renamed").refresh_token == next.refresh_token
    end

    test "refuses what is not a refreshed login", %{scope: scope} do
      provider = subscription!(scope)
      plain = Repo.get!(Connection, provider.id)
      value = key_value!(provider, "main")
      before = Repo.get!(Value, value.id)

      too_large = String.duplicate("x", Value.value_max() + 1)
      assert Secrets.write_refreshed_key(plain, value.id, too_large) == {:error, :too_large}

      assert Secrets.write_refreshed_key(plain, Ecto.UUID.generate(), "{}") ==
               {:error, :not_found}

      assert Secrets.write_refreshed_key(plain, "not-an-id", "{}") == {:error, :not_found}

      {:ok, api} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      assert Secrets.write_refreshed_key(
               Repo.get!(Connection, api.id),
               key_value!(api, "main").id,
               "{}"
             ) ==
               {:error, :not_found}

      assert Repo.get!(Value, value.id).ciphertext == before.ciphertext
    end
  end

  describe "Login.put/3" do
    test "adds 1 to the generation for each login pasted over the key", %{scope: scope} do
      provider = subscription!(scope)
      value = key_value!(provider, "main")
      {:ok, parsed} = Login.parse(login_paste(tag: "x"))

      assert {:ok, %Login{generation: 2}} = Login.put(value, parsed)
      assert {:ok, %Login{generation: 3}} = Login.put(value, parsed)
      assert [%Login{generation: 3}] = Repo.all(Login)
    end
  end

  # The errors of the keys' secret on `values`, and those of its values.
  defp values_errors(%Ecto.Changeset{errors: errors, changes: changes}) do
    nested =
      for %Ecto.Changeset{errors: value_errors} <- List.wrap(changes[:values]),
          {_field, {message, _opts}} <- value_errors,
          do: message

    nested ++ for {:values, {message, _opts}} <- errors, do: message
  end
end
