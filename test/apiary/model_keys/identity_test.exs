defmodule Apiary.ModelKeys.IdentityTest do
  # The identity line of a model key (`Apiary.ModelKeys.Identity`), the hint it shows for
  # an API key (`Apiary.Secrets.Value.hint/1`, written by every path that sets a key's
  # value), the value ids Apiary gives (`key-<n>`) and the email of a sign-in
  # (`Apiary.ModelKeys.Login`).
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.ModelKeys.{Identity, Login}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @long "sk-ant-fixture-key-0123456789-9c2e"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp anthropic!(scope, value \\ @long, place \\ :organisation) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{provider: "anthropic", keys: [%{value: value}]},
        place
      )

    provider
  end

  defp hint(provider, value_id), do: key_value!(provider, value_id).hint

  describe "Value.hint/1" do
    test "is the last 4 characters of a value of at least 12 characters" do
      assert Value.hint("abcdefghijkl") == "ijkl"
      assert Value.hint("sk-ant-0123456789-Rm52") == "Rm52"
    end

    test "is nil for a value of 11 characters or fewer" do
      assert Value.hint("abcdefghijk") == nil
      assert Value.hint("sk-short-1") == nil
      assert Value.hint("") == nil
    end

    test "counts characters, not bytes, and trims the whitespace at the ends" do
      # 11 characters, 22 bytes: no hint. 12 characters, 24 bytes: the last 4.
      assert Value.hint(String.duplicate("é", 11)) == nil
      assert Value.hint(String.duplicate("é", 12)) == "éééé"
      assert Value.hint("  abcdefghij  ") == nil
      assert Value.hint("  abcdefghijkl\n") == "ijkl"
    end

    test "is nil for text that is not UTF-8, for a term that is no text and for a long tail" do
      assert Value.hint(<<255, 254>> <> String.duplicate("a", 20)) == nil
      assert Value.hint(nil) == nil
      assert Value.hint(String.duplicate("a", 11) <> "e" <> String.duplicate("́", 30)) == nil
    end

    test "is nil when the last 4 characters have a control or a format character" do
      prefix = "sk-ant-0123456789-"

      for char <- ["\u202E", "\u200B", "\u2066", "\u00AD", "\u0007", "\u0000", "\u007F"],
          tail <- [char <> "abc", "a" <> char <> "bc", "abc" <> char] do
        assert Value.hint(prefix <> tail) == nil
      end

      # The character is before the last 4: the hint is the 4 characters after it.
      assert Value.hint(prefix <> "\u202E" <> "abcd") == "abcd"
      assert Value.hint(prefix <> "abcd") == "abcd"
    end

    test "does not appear in inspect or JSON" do
      value = %Value{value_id: "key-1", hint: "9c2e"}
      refute inspect(value) =~ "9c2e"
      refute Jason.encode!(value) =~ "9c2e"
    end
  end

  describe "Value.next_key_id/1" do
    test "is one more than the highest key-<n>" do
      assert Value.next_key_id([]) == "key-1"
      assert Value.next_key_id(["key-1", "key-2"]) == "key-3"
      assert Value.next_key_id(["key-2", "key-10", "key-9"]) == "key-11"
    end

    test "ignores a value id of another form" do
      assert Value.next_key_id(["main", nil, "key-", "key-x", "key-3b", "my-key-8"]) == "key-1"
      assert Value.next_key_id(["main", "key-4"]) == "key-5"
    end
  end

  describe "Identity.line/3" do
    test "is the email of a sign-in, else its account's last 4 characters" do
      login = %Login{email: "dana@example.com", account_id: "acct-9d81c27e7c1d"}

      assert Identity.line("OpenAI subscription", nil, login) ==
               "OpenAI subscription · dana@example.com"

      assert Identity.line("OpenAI subscription", nil, %{login | email: nil}) ==
               "OpenAI subscription · account …7c1d"

      assert Identity.line("OpenAI subscription", nil, %Login{account_id: "ab"}) ==
               "OpenAI subscription · account …ab"
    end

    test "is the hint of another key, else the provider's name alone" do
      assert Identity.line("Anthropic API", "9c2e", nil) == "Anthropic API · …9c2e"
      assert Identity.line("Anthropic API", nil, nil) == "Anthropic API"
      assert Identity.line("Anthropic API", "", nil) == "Anthropic API"
    end

    test "never shows the hint of a sign-in" do
      assert Identity.line("OpenAI subscription", "abcd", %Login{account_id: "acct-1234"}) ==
               "OpenAI subscription · account …1234"
    end
  end

  describe "the value id of a key" do
    test "is key-1 for the first key and key-<n> for the next, never given by a page", %{
      scope: scope
    } do
      provider = anthropic!(scope)
      assert Enum.map(provider.secret.values, & &1.value_id) == ["key-1"]

      assert {:ok, provider} =
               Connections.add_provider_key(scope, provider, %{value: "sk-ant-second-key-aaaa"})

      assert {:ok, provider} =
               Connections.add_provider_key(scope, provider, %{value: "sk-ant-third-key-bbbb"})

      assert Enum.map(provider.secret.values, & &1.value_id) |> Enum.sort() ==
               ["key-1", "key-2", "key-3"]
    end

    test "counts on after a deleted key that was not the highest", %{scope: scope} do
      provider = anthropic!(scope)
      {:ok, provider} = Connections.add_provider_key(scope, provider, %{value: @long <> "x"})
      {:ok, provider} = Connections.add_provider_key(scope, provider, %{value: @long <> "y"})
      {:ok, provider} = Connections.update_provider_key(scope, provider, "key-3", %{})
      {:ok, provider} = Connections.delete_provider_key(scope, provider, "key-2")
      {:ok, provider} = Connections.add_provider_key(scope, provider, %{value: @long <> "z"})

      assert Enum.map(provider.secret.values, & &1.value_id) |> Enum.sort() ==
               ["key-1", "key-3", "key-4"]
    end

    test "names the keys of a new provider in order, after the value ids given", %{scope: scope} do
      assert {:ok, provider} =
               Connections.create_provider(scope, %{
                 provider: "anthropic",
                 keys: [
                   %{value: "sk-ant-aaaaaaaaaaaaaaaa"},
                   %{value_id: "key-5", value: "sk-ant-bbbbbbbbbbbbbbbb"},
                   %{value: "sk-ant-cccccccccccccccc"}
                 ]
               })

      assert Enum.map(provider.secret.values, & &1.value_id) |> Enum.sort() ==
               ["key-5", "key-6", "key-7"]

      assert provider.default_value_id == "key-6"
    end
  end

  describe "the hint" do
    test "is written when a provider is created with a key, and when a key is added", %{
      scope: scope
    } do
      provider = anthropic!(scope)
      assert hint(provider, "key-1") == "9c2e"

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{value: "  sk-ant-another-key-Rm52\n"})

      assert hint(provider, "key-2") == "Rm52"
    end

    test "is written for a provider added for one workspace", %{scope: scope} do
      provider = anthropic!(scope, @long, :workspace)
      assert hint(provider, "key-1") == "9c2e"
    end

    test "is not written for a value of fewer than 12 characters", %{scope: scope} do
      provider = anthropic!(scope, "sk-short-1")
      assert hint(provider, "key-1") == nil
    end

    test "is replaced by a new value, and cleared by a short one", %{scope: scope} do
      provider = anthropic!(scope)

      assert {:ok, provider} =
               Connections.set_provider_key(scope, provider, "key-1", "sk-ant-replaced-key-Qx81")

      assert hint(provider, "key-1") == "Qx81"

      assert {:ok, provider} =
               Connections.update_provider_key(scope, provider, "key-1", %{
                 "value" => "  sk-ant-edited-key-4h7k "
               })

      assert hint(provider, "key-1") == "4h7k"

      assert {:ok, provider} =
               Connections.update_provider_key(scope, provider, "key-1", %{"value" => "short"})

      assert hint(provider, "key-1") == nil
    end

    test "stays when a key is saved without a new value", %{scope: scope} do
      provider = anthropic!(scope)

      assert {:ok, provider} =
               Connections.update_provider_key(scope, provider, "key-1", %{"value" => ""})

      assert hint(provider, "key-1") == "9c2e"
    end

    test "is not written for a sign-in, whose value is a document with a refresh token", %{
      scope: scope
    } do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [%{value: device_login()}]
        })

      assert hint(provider, "key-1") == nil

      assert {:ok, provider} =
               Connections.add_provider_key(scope, provider, %{value: device_login(tag: "b")})

      assert hint(provider, "key-2") == nil

      assert {:ok, provider} =
               Connections.set_provider_key(scope, provider, "key-1", device_login(tag: "c"))

      assert hint(provider, "key-1") == nil
    end

    test "is not written for an ordinary secret", %{scope: scope} do
      {:ok, secret} =
        Secrets.create_organisation_secret(scope, %{
          name: "ORDINARY",
          values: [%{value_id: "main", value: @long}]
        })

      assert [%Value{hint: nil}] = secret.values
      assert Repo.one!(from v in Value, where: v.secret_id == ^secret.id).hint == nil

      assert {:ok, _secret} =
               Secrets.add_value(scope, secret, %{value_id: "other", value: @long <> "1"})

      assert Repo.all(from v in Value, where: v.secret_id == ^secret.id, select: v.hint) == [
               nil,
               nil
             ]
    end
  end

  describe "Identity.for_value_id/2 and for_key/2" do
    test "read the line of an API key, with the provider's name", %{scope: scope} do
      provider = anthropic!(scope)
      assert Identity.for_value_id(provider, "key-1") == "#{provider.name} · …9c2e"

      id = key_value!(provider, "key-1").id
      assert Identity.for_key(provider, id) == "#{provider.name} · …9c2e"
    end

    test "read the provider's name alone for an API key with no hint and for a key not there",
         %{scope: scope} do
      provider = anthropic!(scope, "sk-short-1")
      assert Identity.for_value_id(provider, "key-1") == provider.name
      assert Identity.for_value_id(provider, "key-9") == provider.name
      assert Identity.for_key(provider, Ecto.UUID.generate()) == provider.name
    end

    test "read the email of a sign-in, and the account for one saved with no email", %{
      scope: scope
    } do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [%{value: device_login()}]
        })

      assert Identity.for_value_id(provider, "key-1") == "#{provider.name} · dana@example.com"

      value = key_value!(provider, "key-1")
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id), set: [email: nil])

      assert Identity.for_value_id(provider, "key-1") ==
               "#{provider.name} · account …re-a"
    end

    test "read the line of a key of another provider as not there", %{scope: scope} do
      one = anthropic!(scope)
      other = anthropic!(scope, @long <> "x")
      id = key_value!(other, "key-1").id
      assert Identity.for_key(one, id) == one.name
    end
  end

  describe "the email of a sign-in" do
    defp parsed(claims) do
      tokens = login_tokens()

      {:ok, parsed} =
        Login.from_tokens(
          %{
            "access_token" => tokens.access_token,
            "refresh_token" => tokens.refresh_token,
            "id_token" => jwt(Map.merge(%{"exp" => 1}, claims))
          },
          account_claim()
        )

      parsed
    end

    test "is read from the ID token's email claim, and stored in the row", %{scope: scope} do
      assert parsed(%{"email" => "sam@example.com"}).email == "sam@example.com"

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [%{value: device_login()}]
        })

      assert [%Login{email: "dana@example.com"}] = Map.values(Login.by_key(provider))
    end

    test "is nil for an ID token without the claim, or with a claim that is no email" do
      assert parsed(%{}).email == nil
      assert parsed(%{"email" => 5}).email == nil
      assert parsed(%{"email" => ""}).email == nil
      assert parsed(%{"email" => "no-at-sign"}).email == nil
      assert parsed(%{"email" => "a b@example.com"}).email == nil
      assert parsed(%{"email" => "a@b@example.com"}).email == nil
      assert parsed(%{"email" => "a@example.com\n"}).email == nil

      # A format character (Unicode `Cf`) anywhere in it: no email, so the line shows the account.
      for char <- ["\u202E", "\u200B", "\u2066", "\u200F", "\uFEFF"],
          email <- [
            char <> "a@example.com",
            "a" <> char <> "@example.com",
            "a@example.com" <> char
          ] do
        assert parsed(%{"email" => email}).email == nil
      end

      assert parsed(%{"email" => String.duplicate("a", 250) <> "@example.com"}).email == nil
    end

    test "is not read from the access token, and the ID token is not kept" do
      tokens = login_tokens()

      access =
        jwt(%{
          "exp" => System.os_time(:second) + 100,
          "email" => "access@example.com",
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-x"}
        })

      assert {:ok, parsed} =
               Login.from_tokens(
                 %{"access_token" => access, "refresh_token" => tokens.refresh_token},
                 account_claim()
               )

      assert parsed.email == nil
      refute parsed.document =~ "email"
      refute inspect(parsed) =~ "example.com"
    end

    test "is replaced by a new sign-in, also with none", %{scope: scope} do
      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [%{value: device_login()}]
        })

      assert {:ok, provider} =
               Connections.set_provider_key(
                 scope,
                 provider,
                 "key-1",
                 parsed(%{"email" => "lee@example.com"})
               )

      assert [%Login{email: "lee@example.com"}] = Map.values(Login.by_key(provider))

      assert {:ok, provider} =
               Connections.set_provider_key(scope, provider, "key-1", parsed(%{}))

      assert [%Login{email: nil}] = Map.values(Login.by_key(provider))
    end
  end

  describe "the entry of a key's change" do
    defp entries(provider),
      do:
        Repo.all(
          from e in Entry,
            where: e.organisation_id == ^provider.organisation_id,
            order_by: e.inserted_at
        )

    test "has the identity line of the key as it was written", %{scope: scope} do
      provider = anthropic!(scope)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{value: "sk-ant-another-key-Rm52"})

      {:ok, provider} =
        Connections.set_provider_key(scope, provider, "key-2", "sk-ant-replaced-key-Qx81")

      {:ok, provider} = Connections.delete_provider_key(scope, provider, "key-2")

      identities =
        for %Entry{details: %{"change" => "provider_keys_changed"} = details} <- entries(provider),
            do: details["identity"]

      assert identities == [
               "#{provider.name} · …Rm52",
               "#{provider.name} · …Qx81",
               "#{provider.name} · …Qx81"
             ]
    end

    test "has the line of a key deleted without a hint", %{scope: scope} do
      provider = anthropic!(scope)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{value: "sk-short-1"})

      {:ok, provider} = Connections.delete_provider_key(scope, provider, "key-2")

      assert %Entry{details: %{"identity" => identity}} =
               entries(provider) |> List.last()

      assert identity == provider.name
    end
  end
end
