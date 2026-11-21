defmodule Apiary.ModelKeys.LoginTest do
  # `Apiary.ModelKeys.Login.from_tokens/3`, which reads the response of a device sign-in's code
  # exchange, and what the module says about a provider: the tokens are kept in a document,
  # the rest is dropped, a response that is no sign-in is refused, and no call fails on any
  # term.
  use ExUnit.Case, async: true

  import Apiary.ModelKeysFixtures

  alias Apiary.ModelKeys.Login

  # The response of the code exchange for `tokens`, as the provider sends it.
  defp response(tokens, extra \\ %{}) do
    Map.merge(
      %{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token,
        "id_token" => tokens.id_token,
        "expires_in" => 864_000
      },
      extra
    )
  end

  defp read(response), do: Login.from_tokens(response, account_claim())

  describe "from_tokens/3" do
    test "keeps the access and refresh tokens in a document, and the account and the expiry apart" do
      tokens = login_tokens(exp: 1_800_000_000)

      assert {:ok, parsed} = read(response(tokens))

      assert parsed.account_id == tokens.account_id
      assert parsed.access_expires_at == ~U[2027-01-15 08:00:00.000000Z]

      assert Jason.decode!(parsed.document) == %{
               "version" => 1,
               "access_token" => tokens.access_token,
               "refresh_token" => tokens.refresh_token
             }
    end

    test "does not store the id token, and reads a response without one" do
      tokens = login_tokens()
      assert {:ok, parsed} = read(response(tokens))

      assert Map.keys(Jason.decode!(parsed.document)) |> Enum.sort() ==
               ~w(access_token refresh_token version)

      refute parsed.document =~ tokens.id_token

      without_id = response(tokens) |> Map.delete("id_token")
      assert {:ok, same} = read(without_id)
      assert same.document == parsed.document
    end

    test "reads the account id from the access token, and the ID token's only to compare" do
      tokens = login_tokens()
      claim = fn id -> %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => id}} end
      bare = jwt(%{"exp" => System.os_time(:second) + 100})
      with_id = jwt(Map.put(claim.("acct-a"), "exp", System.os_time(:second) + 100))

      # The claim only in the ID token: no account.
      assert read(
               response(tokens, %{"access_token" => bare, "id_token" => jwt(claim.("acct-a"))})
             ) ==
               {:error, :no_account}

      # The claim only in the access token.
      assert {:ok, %{account_id: "acct-a"}} =
               read(response(tokens, %{"access_token" => with_id, "id_token" => jwt(%{})}))

      assert {:ok, %{account_id: "acct-a"}} =
               read(response(tokens, %{"access_token" => with_id}) |> Map.delete("id_token"))

      # Both, and they agree.
      assert {:ok, %{account_id: "acct-a"}} =
               read(
                 response(tokens, %{
                   "access_token" => with_id,
                   "id_token" => jwt(claim.("acct-a"))
                 })
               )

      # Both, and they differ.
      assert read(
               response(tokens, %{"access_token" => with_id, "id_token" => jwt(claim.("acct-b"))})
             ) ==
               {:error, :invalid}

      # Neither.
      assert read(response(tokens, %{"access_token" => bare, "id_token" => jwt(%{})})) ==
               {:error, :no_account}

      assert read(response(tokens, %{"access_token" => bare}) |> Map.delete("id_token")) ==
               {:error, :no_account}
    end

    test "refuses a response whose access token and ID token have different account ids" do
      tokens = login_tokens()

      other =
        jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-other"}})

      assert read(response(tokens, %{"id_token" => other})) == {:error, :invalid}

      same = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => tokens.account_id}})
      assert {:ok, %{account_id: account}} = read(response(tokens, %{"id_token" => same}))
      assert account == tokens.account_id
    end

    test "reads the pointer of the claim as RFC 6901 writes it" do
      tokens = login_tokens()
      access = jwt(%{"exp" => System.os_time(:second) + 100, "a/b" => %{"c~d" => "acct-x"}})

      assert {:ok, %{account_id: "acct-x"}} =
               Login.from_tokens(response(tokens, %{"access_token" => access}), "/a~1b/c~0d")

      assert Login.from_tokens(response(tokens), "no-slash") == {:error, :no_account}
      assert Login.from_tokens(response(tokens), nil) == {:error, :invalid}
    end

    # The account id is read as the gateway of Forager reads it
    # (`Apiary.ModelKeys.AccountClaim`): a response whose token the gateway would refuse is
    # no sign-in. The token has the payload `payload` as it is, with no `exp`.
    defp read_payload(payload, opts \\ []) do
      encode =
        if opts[:padded], do: &Base.url_encode64/1, else: &Base.url_encode64(&1, padding: false)

      access = "e30." <> encode.(payload) <> ".sig"
      Login.from_tokens(response(login_tokens(), %{"access_token" => access}), "/id")
    end

    test "refuses an account id with a space at either end" do
      for id <- [" acct-1", "acct-1 ", "\\tacct-1", "acct-1\\t"] do
        assert read_payload(~s({"id":"#{id}"})) == {:error, :no_account}, id
      end
    end

    test "refuses an account id with a control character" do
      for id <- ["acct\\n1", "acct\\u0000-1", "acct\\u007F-1", "acct\\u0085-1"] do
        assert read_payload(~s({"id":"#{id}"})) == {:error, :no_account}, id
      end
    end

    test "refuses a payload over 8 KiB" do
      over = ~s({"id":"acct-1","pad":"#{String.duplicate("p", 8192)}"})
      assert read_payload(over) == {:error, :no_account}
    end

    test "refuses a payload with a member name twice" do
      assert read_payload(~s({"id":"acct-1","id":"acct-2"})) == {:error, :no_account}
    end

    test "reads a payload with padding" do
      assert {:ok, %{account_id: "acct-1"}} =
               read_payload(~s({"id":"acct-1","exp":4102444800}), padded: true)
    end

    test "refuses a response with no refresh token or no access token" do
      tokens = login_tokens()

      for refresh <- [nil, "", 42] do
        assert read(response(tokens, %{"refresh_token" => refresh})) == {:error, :invalid}
      end

      assert read(response(tokens) |> Map.delete("refresh_token")) == {:error, :invalid}
      assert read(response(tokens) |> Map.delete("access_token")) == {:error, :invalid}
      assert read(response(tokens, %{"access_token" => "has a space.b.c"})) == {:error, :invalid}
    end

    test "refuses anything that is no response" do
      for term <- ["", "sk-proj-an-api-key", [], nil, 42, %{}, <<255, 254, 253>>] do
        assert read(term) == {:error, :invalid}
      end
    end

    test "accepts an account id of printable ASCII without a space, up to 255 characters" do
      tokens = login_tokens()

      for account_id <- ["acct-1", "a", "!~", "A.b_c:d/e=", String.duplicate("a", 255)] do
        access =
          jwt(%{
            "exp" => System.os_time(:second) + 100,
            "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
          })

        assert {:ok, %{account_id: ^account_id}} =
                 read(response(tokens, %{"access_token" => access}))
      end
    end

    # An account id that the gateway of Forager refuses (a control character, a space or a
    # tab at either end, none) is no account id; one that it reads but that no header may
    # have (a space or tab inside, past ASCII, over 255 characters) is no sign-in.
    defp account_response(account_id) do
      access =
        jwt(%{
          "exp" => System.os_time(:second) + 100,
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
        })

      response(login_tokens(), %{"access_token" => access})
    end

    test "reads no account id with a control character, a space at either end, or none" do
      for account_id <- [
            "acct\r\nX-Injected: 1",
            "acct-1\n",
            "acct-1\r",
            "acct\n1",
            " acct-1",
            "acct-1 ",
            "acct\0 1",
            "acct\u007F1",
            ""
          ] do
        assert read(account_response(account_id)) == {:error, :no_account}, inspect(account_id)
      end
    end

    test "refuses an account id with a space inside, past ASCII, or over 255 characters" do
      for account_id <- ["acct 1", "acct\t1", "acct-é", "acct-\u2028", String.duplicate("a", 256)] do
        assert read(account_response(account_id)) == {:error, :invalid}, inspect(account_id)
      end
    end

    test "reads the expiry from exp, else from expires_in, else leaves it empty" do
      tokens = login_tokens()
      claim = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-1"}}
      now = ~U[2026-11-18 12:00:00Z]

      for claims <- [%{}, %{"exp" => "soon"}, %{"exp" => 1.5e9}, %{"exp" => nil}] do
        access = jwt(Map.merge(claim, claims))

        assert {:ok, %{access_expires_at: at}} =
                 Login.from_tokens(
                   response(tokens, %{"access_token" => access, "expires_in" => 3600}),
                   account_claim(),
                   now
                 )

        assert at == ~U[2026-11-18 13:00:00.000000Z]

        assert {:ok, %{access_expires_at: nil}} =
                 Login.from_tokens(
                   response(tokens, %{"access_token" => access}) |> Map.delete("expires_in"),
                   account_claim(),
                   now
                 )
      end
    end

    test "reads no account id from a claim that is no text" do
      tokens = login_tokens()

      access =
        jwt(%{
          "exp" => System.os_time(:second) + 100,
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => 42}
        })

      assert read(response(tokens, %{"access_token" => access, "id_token" => nil})) ==
               {:error, :no_account}
    end

    test "uses an expires_in only from 1 second to 366 days" do
      tokens = login_tokens()
      claim = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-1"}}
      access = jwt(claim)
      now = ~U[2026-11-18 12:00:00Z]
      day = 86_400

      for {seconds, expected} <- [
            {1, ~U[2026-11-18 12:00:01.000000Z]},
            {366 * day, ~U[2027-11-19 12:00:00.000000Z]},
            {0, nil},
            {-5, nil},
            {366 * day + 1, nil},
            {1_000_000_000_000_000_000_000, nil},
            {3600.5, nil},
            {"3600", nil}
          ] do
        assert {:ok, %{access_expires_at: at}} =
                 Login.from_tokens(
                   response(tokens, %{"access_token" => access, "expires_in" => seconds}),
                   account_claim(),
                   now
                 )

        assert at == expected
      end
    end

    test "uses an exp only from 1 second to 366 days after now, else falls back" do
      tokens = login_tokens()
      claim = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-1"}}
      now = ~U[2026-11-18 12:00:00Z]
      unix = DateTime.to_unix(now)
      fallback = ~U[2026-11-18 13:00:00.000000Z]

      for {exp, expected} <- [
            {unix + 1, ~U[2026-11-18 12:00:01.000000Z]},
            {unix, fallback},
            {unix - 3600, fallback},
            {unix + 366 * 86_400 + 1, fallback},
            {1_000_000_000_000_000_000_000, fallback},
            {-1_000_000_000_000_000_000_000, fallback}
          ] do
        access = jwt(Map.put(claim, "exp", exp))

        assert {:ok, %{access_expires_at: at}} =
                 Login.from_tokens(
                   response(tokens, %{"access_token" => access, "expires_in" => 3600}),
                   account_claim(),
                   now
                 )

        assert at == expected
      end
    end

    test "refuses a document past a value's size" do
      long = String.duplicate("x", 17_000)
      assert read(response(login_tokens(), %{"refresh_token" => long})) == {:error, :invalid}
    end

    test "never raises, and what it returns has none of the response" do
      tokens = login_tokens()
      secret = tokens.refresh_token

      for term <- [
            %{"refresh_token" => secret},
            %{"refresh_token" => secret, "access_token" => 1.0e300},
            %{"refresh_token" => secret, "access_token" => "a.b.c"},
            %{"refresh_token" => secret, "access_token" => [secret]}
          ] do
        assert {:error, reason} = read(term)
        refute inspect(reason) =~ secret
      end
    end

    test "a read sign-in shows no token when inspected" do
      {:ok, parsed} = read(response(login_tokens(tag: "inspect")))

      refute inspect(parsed) =~ "rt-fixture-refresh-token-inspect"
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
