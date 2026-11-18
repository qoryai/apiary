defmodule Apiary.ModelKeys.LoginTest do
  # `Apiary.ModelKeys.Login.parse/1`, which reads a pasted `auth.json`, and what the module
  # says about a provider: the paste's tokens are kept in a document, the rest is dropped,
  # a paste that is no login is refused with a reason that has none of it, and no call
  # fails on any text.
  use ExUnit.Case, async: true

  import Apiary.ModelKeysFixtures

  alias Apiary.ModelKeys.Login

  defp paste!(tokens), do: login_paste(tokens: tokens)

  describe "parse/1" do
    test "keeps the three tokens in a document, and the account and the expiry apart" do
      tokens = login_tokens(exp: 1_800_000_000)

      assert {:ok, parsed} = Login.parse(paste!(tokens))

      assert parsed.account_id == tokens.account_id
      assert parsed.access_expires_at == ~U[2027-01-15 08:00:00.000000Z]

      assert Jason.decode!(parsed.document) == %{
               "version" => 1,
               "access_token" => tokens.access_token,
               "refresh_token" => tokens.refresh_token,
               "id_token" => tokens.id_token
             }
    end

    test "drops every member but the tokens" do
      {:ok, parsed} = Login.parse(login_paste())

      refute parsed.document =~ "auth_mode"
      refute parsed.document =~ "last_refresh"
      refute parsed.document =~ "OPENAI_API_KEY"
      refute parsed.document =~ "account_id"
    end

    test "reads a paste printed over several lines, or with space around it" do
      assert {:ok, _parsed} = Login.parse(login_paste())
      assert {:ok, _parsed} = Login.parse(login_paste() |> Jason.decode!() |> Jason.encode!())
    end

    test "refuses a login with no refresh token with its reason" do
      tokens =
        login_paste() |> Jason.decode!() |> get_in(["tokens"]) |> Map.delete("refresh_token")

      for text <- [
            Jason.encode!(%{"tokens" => tokens}),
            Jason.encode!(%{"tokens" => Map.put(tokens, "refresh_token", "")}),
            Jason.encode!(%{"tokens" => Map.put(tokens, "refresh_token", nil)})
          ] do
        assert Login.parse(text) == {:error, :no_refresh_token}
      end
    end

    test "refuses a paste that is no login" do
      tokens = login_paste() |> Jason.decode!() |> get_in(["tokens"])
      without = fn key -> Jason.encode!(%{"tokens" => Map.delete(tokens, key)}) end

      for text <- [
            "",
            "   ",
            "sk-proj-an-api-key",
            "[]",
            "null",
            "{}",
            ~s({"tokens": null}),
            ~s({"tokens": []}),
            ~s({"tokens": "x"}),
            without.("access_token"),
            without.("id_token"),
            without.("account_id"),
            Jason.encode!(%{"tokens" => Map.put(tokens, "account_id", 42)}),
            Jason.encode!(%{"tokens" => Map.put(tokens, "access_token", "not-a-jwt")}),
            Jason.encode!(%{"tokens" => Map.put(tokens, "access_token", "a.b.c")}),
            Jason.encode!(%{
              "tokens" => Map.put(tokens, "account_id", String.duplicate("a", 256))
            }),
            <<255, 254, 253>>,
            nil,
            42,
            %{"tokens" => tokens}
          ] do
        assert Login.parse(text) == {:error, :invalid}
      end
    end

    test "refuses an access token whose payload has no whole-second exp" do
      tokens = login_paste() |> Jason.decode!() |> get_in(["tokens"])

      for claims <- [%{}, %{"exp" => "soon"}, %{"exp" => 1.5e9}, %{"exp" => nil}] do
        text = Jason.encode!(%{"tokens" => Map.put(tokens, "access_token", jwt(claims))})
        assert Login.parse(text) == {:error, :invalid}
      end

      # A time past the calendar, and a payload that is not base64 or not JSON.
      for token <- [
            jwt(%{"exp" => 99_999_999_999_999_999}),
            "a.!!!.c",
            "a.#{Base.url_encode64("x", padding: false)}.c"
          ] do
        text = Jason.encode!(%{"tokens" => Map.put(tokens, "access_token", token)})
        assert Login.parse(text) == {:error, :invalid}
      end
    end

    test "refuses a paste past 32 KiB and a document past a value's size" do
      tokens = login_paste() |> Jason.decode!() |> get_in(["tokens"])

      assert Login.parse(String.duplicate(" ", 32_769)) == {:error, :invalid}

      long = Map.put(tokens, "id_token", String.duplicate("x", 17_000))
      assert Login.parse(Jason.encode!(%{"tokens" => long})) == {:error, :invalid}
    end

    test "never raises, and what it returns has none of the paste" do
      tokens = login_tokens()
      secret = tokens.refresh_token

      broken = [
        String.slice(paste!(tokens), 0, 200),
        paste!(tokens) <> "}",
        "{\"tokens\": {\"refresh_token\": \"#{secret}\"",
        "{\"tokens\": {\"refresh_token\": \"#{secret}\", \"access_token\": 1e999}}",
        String.duplicate("[", 30_000),
        "{\"tokens\": " <> String.duplicate("{\"a\":", 10_000) <> secret
      ]

      for text <- broken do
        assert {:error, reason} = Login.parse(text)
        assert reason in [:invalid, :no_refresh_token]
        refute inspect(reason) =~ secret
      end

      for reason <- [:invalid, :no_refresh_token] do
        refute inspect(Login.refusal(reason)) =~ secret
      end
    end

    test "a parsed login shows no token when inspected" do
      {:ok, parsed} = Login.parse(login_paste(tokens: login_tokens(tag: "inspect")))

      refute inspect(parsed) =~ "rt-fixture-refresh-token-inspect"
    end
  end

  describe "refusal/1 and problem/1" do
    test "have one sentence for a paste that is no login, and add why for a missing refresh token" do
      assert {"Paste the whole auth.json that codex login wrote.", []} = Login.refusal(:invalid)

      assert {"Paste the whole auth.json that codex login wrote. This text has no refresh token.",
              []} = Login.refusal(:no_refresh_token)
    end

    test "problem/1 is nil for a blank text and for a login, else the refusal" do
      assert Login.problem("") == nil
      assert Login.problem("  \n ") == nil
      assert Login.problem(nil) == nil
      assert Login.problem(login_paste()) == nil
      assert Login.problem("sk-an-api-key") == Login.refusal(:invalid)

      no_refresh =
        login_paste()
        |> Jason.decode!()
        |> update_in(["tokens"], &Map.delete(&1, "refresh_token"))
        |> Jason.encode!()

      assert Login.problem(no_refresh) == Login.refusal(:no_refresh_token)
    end
  end

  describe "provider?/1" do
    test "is true for a provider whose API has oauth_refresh, by its row or its name" do
      assert Login.provider?("openai-subscription")
      assert Login.provider?(%Apiary.Connections.Connection{provider_kind: "openai-subscription"})
    end

    test "is false for the others, for a name the catalogue lacks and for nil" do
      for kind <- ~w(anthropic claude-subscription openai deepseek openrouter litellm gone),
          do: refute(Login.provider?(kind))

      refute Login.provider?(nil)
      refute Login.provider?(%Apiary.Connections.Connection{provider_kind: nil})
    end
  end
end
