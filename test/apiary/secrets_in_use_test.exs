defmodule Apiary.SecretsInUseTest do
  # Not async: what uses a secret, the instance's secret and its features are the node's,
  # set for a test and put back after it.
  use Apiary.DataCase, async: false

  @moduletag needs: :security

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{KeyDerivation, Secrets}
  alias Apiary.Secrets.Usage

  setup do
    previous = Application.get_env(:apiary, Usage)
    on_exit(fn -> restore(Usage, previous) end)
    %{scope: sign_up_fixture().scope}
  end

  defp restore(key, nil), do: Application.delete_env(:apiary, key)
  defp restore(key, previous), do: Application.put_env(:apiary, key, previous)

  # Something uses the secret named `name`: its value `value_id`.
  defp used(name, value_id) do
    Application.put_env(:apiary, Usage,
      answer: fn repo, secret ->
        # Asked inside the deleting transaction, with the secret's row locked.
        assert repo == Apiary.Repo
        assert Apiary.Repo.in_transaction?()

        if secret.name == name,
          do: [
            %{kind: :integration, id: "int_0123456789abcdef", name: "Example", value_id: value_id}
          ],
          else: []
      end
    )
  end

  test "a secret in use is not deleted, and says what uses it", %{scope: scope} do
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "x"})
    {:ok, other} = Secrets.create_secret(scope, %{name: "OTHER", value: "x"})
    used("API_KEY", nil)

    assert {:error, {:in_use, [%{kind: :integration, name: "Example"}]}} =
             Secrets.delete_secret(scope, secret)

    assert {:ok, _} = Secrets.get_secret(scope, secret.public_id)
    assert {:ok, _} = Secrets.delete_secret(scope, other)

    Application.delete_env(:apiary, Usage)
    assert {:ok, _} = Secrets.delete_secret(scope, secret)
  end

  test "a value in use is not deleted; another value of the secret is", %{scope: scope} do
    {:ok, secret} = Secrets.create_secret(scope, %{name: "KEYS", value: "a", value_id: "main"})
    {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "bot", value: "b"})
    {:ok, secret} = Secrets.add_value(scope, secret, %{value_id: "ci", value: "c"})
    used("KEYS", "main")

    assert {:error, {:in_use, [_use]}} = Secrets.delete_value(scope, secret, "main")
    assert {:ok, secret} = Secrets.delete_value(scope, secret, "bot")
    assert Enum.map(secret.values, & &1.value_id) == ["ci", "main"]
  end

  test "values stored under another APIARY_ENCRYPTION_SECRET are unavailable, never wrong",
       %{scope: scope} do
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "the value"})
    previous = Application.get_env(:apiary, KeyDerivation)
    on_exit(fn -> Application.put_env(:apiary, KeyDerivation, previous) end)
    Application.put_env(:apiary, KeyDerivation, secret: :binary.copy(<<3>>, 32))

    log =
      capture_log(fn ->
        assert Secrets.reveal_for_sealing(scope.workspace, secret.public_id, nil) ==
                 {:error, :unavailable}

        assert Secrets.set_value(scope, secret, nil, "new value") == {:error, :key_unavailable}
      end)

    assert log =~ "APIARY_ENCRYPTION_SECRET"
    refute log =~ "the value"

    Application.put_env(:apiary, KeyDerivation, previous)

    assert Secrets.reveal_for_sealing(scope.workspace, secret.public_id, nil) ==
             {:ok, "the value"}
  end
end
