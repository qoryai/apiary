defmodule Apiary.Kinds.ProvidersTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Provider, Providers, Runtime, Runtimes}

  @descriptions Path.expand("../../../priv/contract/integration/descriptions", __DIR__)

  defp description(name), do: @descriptions |> Path.join(name <> ".json") |> File.read!()

  defp runtime(fields) do
    struct!(
      %Runtime{name: "runner", title: "Runner", model: %{"formats" => ["anthropic-messages"]}},
      fields
    )
  end

  # The anthropic provider with one API of `format` and `auth`, or the APIs `apis` gives.
  defp provider(fields) do
    {:ok, base} = Providers.fetch("anthropic")
    apis = Keyword.get(fields, :apis, [api("anthropic-messages", %{"scheme" => "bearer"})])
    %{base | apis: apis}
  end

  defp api(format, auth, endpoint \\ "https://models.example.com"),
    do: %{"format" => format, "endpoint" => endpoint, "auth" => auth}

  defp key(auth, format \\ "anthropic-messages", variable \\ "MODEL_KEY"),
    do: %{"format" => format, "auth" => auth, "variable" => variable}

  defp declare(name, auth), do: %{"id" => "key", "title" => "Key", "name" => name, "auth" => auth}

  describe "the catalogue" do
    test "lists one provider per vendored description, in the order of its name" do
      assert Enum.map(Providers.list(), & &1.name) ==
               ~w(anthropic claude-subscription deepseek litellm openrouter)

      assert {:ok, %Provider{name: "deepseek"}} = Providers.fetch("deepseek")
      assert Providers.fetch("nothing") == :error
    end

    test "ref/0 is the commit in .integration-contract-ref" do
      ref =
        Path.expand("../../../.integration-contract-ref", __DIR__)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))

      assert ref == [Providers.ref()]
      assert Providers.ref() =~ ~r/\A[0-9a-f]{40}\z/
    end

    test "each provider has the members of its description's model_provider role" do
      for provider <- Providers.list() do
        document = provider.description.document
        role = document["roles"]["model_provider"]

        assert provider.title == document["title"]
        assert provider.apis == role["apis"]
        assert provider.models == role["models"]
        assert provider.egress_hosts == document["egress_hosts"]
      end
    end

    test "a provider whose endpoint is a setting has its egress host from that setting" do
      assert {:ok, provider} = Providers.fetch("litellm")

      assert [%{"format" => "anthropic-messages", "endpoint" => %{"setting" => "address"}}] =
               provider.apis

      assert provider.egress_hosts == [%{"setting" => "address"}]
      assert provider.models == []
    end

    test "a provider with a URL endpoint lists its API and models" do
      assert {:ok, provider} = Providers.fetch("deepseek")

      assert provider.apis == [
               %{
                 "format" => "anthropic-messages",
                 "endpoint" => "https://api.deepseek.com/anthropic",
                 "auth" => %{"scheme" => "header", "header" => "x-api-key"}
               }
             ]

      assert provider.egress_hosts == ["api.deepseek.com"]

      assert [%{"id" => "deepseek-v4-pro", "effort" => ["low", "high", "max"]} | _] =
               provider.models
    end
  end

  describe "a description that fails stops the compile" do
    @describetag :tmp_dir

    test "load!/1 reads a valid data description", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")
      File.write!(path, description("anthropic"))
      assert %Provider{name: "anthropic"} = Provider.load!(path)
    end

    test "load!/1 raises for a description the schema refuses", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")

      broken =
        description("anthropic")
        |> Jason.decode!()
        |> pop_in(["roles", "model_provider", "apis"])
        |> elem(1)

      File.write!(path, Jason.encode!(broken))

      assert_raise ArgumentError, ~r/is refused: \{:description_invalid/, fn ->
        Provider.load!(path)
      end
    end

    test "load!/1 raises for a program description", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")

      program =
        description("anthropic") |> Jason.decode!() |> Map.put("program_version", "1.0.0")

      File.write!(path, Jason.encode!(program))
      assert_raise ArgumentError, ~r/not a data description/, fn -> Provider.load!(path) end
    end

    test "load!/1 raises for two APIs of one format", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")
      document = Jason.decode!(description("anthropic"))
      [api] = document["roles"]["model_provider"]["apis"]
      bearer = %{api | "auth" => %{"scheme" => "bearer"}}

      File.write!(
        path,
        document |> put_in(["roles", "model_provider", "apis"], [api, bearer]) |> Jason.encode!()
      )

      assert_raise ArgumentError,
                   ~r/more than one API of the format \["anthropic-messages"\]/,
                   fn ->
                     Provider.load!(path)
                   end
    end

    test "load!/1 raises for a URL endpoint the endpoint rule refuses", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")
      document = Jason.decode!(description("anthropic"))
      [api] = document["roles"]["model_provider"]["apis"]

      File.write!(
        path,
        document
        |> put_in(["roles", "model_provider", "apis"], [
          %{api | "endpoint" => "https://169.254.10.1/v1"}
        ])
        |> Jason.encode!()
      )

      assert_raise ArgumentError, ~r/has an address that Apiary.Kinds.Endpoint refuses/, fn ->
        Provider.load!(path)
      end
    end

    test "load!/1 raises for an address setting whose default the endpoint rule refuses", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "litellm.json")

      for {default, _why} <- [
            {"https://localhost.localdomain", :localhost},
            {"https://127.0.0.1:4000", :loopback},
            {"http://litellm.example.com", :scheme}
          ] do
        with_default =
          description("litellm")
          |> Jason.decode!()
          |> put_in(["settings", "properties", "address", "default"], default)

        File.write!(path, Jason.encode!(with_default))

        assert_raise ArgumentError, ~r/has an address that Apiary.Kinds.Endpoint refuses/, fn ->
          Provider.load!(path)
        end
      end

      passing =
        description("litellm")
        |> Jason.decode!()
        |> put_in(["settings", "properties", "address", "default"], "https://10.0.0.12:4000")

      File.write!(path, Jason.encode!(passing))

      assert {:ok, "https://10.0.0.12:4000"} =
               path |> Provider.load!() |> Provider.setting_default("address")
    end

    test "load!/1 records the SHA-256 of the file's bytes", %{tmp_dir: dir} do
      path = Path.join(dir, "anthropic.json")
      bytes = description("anthropic")
      File.write!(path, bytes)

      assert Provider.load!(path).sha256 ==
               Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    end

    test "load!/1 raises for a file named other than the description", %{tmp_dir: dir} do
      path = Path.join(dir, "other.json")
      File.write!(path, description("anthropic"))
      assert_raise ArgumentError, ~r/not a data description/, fn -> Provider.load!(path) end
    end
  end

  describe "serve/2 against the vendored claude runtime" do
    # At Forager b6ac9f06, the claude runtime reads a model key from ANTHROPIC_API_KEY
    # (header x-api-key), ANTHROPIC_AUTH_TOKEN (bearer) and CLAUDE_CODE_OAUTH_TOKEN
    # (bearer, oauth), each for anthropic-messages. Every vendored provider sends
    # anthropic-messages with a header x-api-key or a bearer without oauth.
    @served %{
      "anthropic" => :ok,
      "claude-subscription" => :ok,
      "deepseek" => :ok,
      "litellm" => :ok,
      "openrouter" => :ok
    }

    test "each provider gets the result the pinned files give" do
      assert {:ok, claude} = Runtimes.fetch("claude")
      assert Runtimes.formats(claude) == ["anthropic-messages"]
      assert claude.declares == []

      assert Map.new(Providers.list(), &{&1.name, Providers.serve(&1, claude)}) == @served

      for provider <- Providers.list(),
          do: assert(Providers.serves?(provider, claude) == (@served[provider.name] == :ok))
    end

    test "a provider whose auth no model key of the runtime has gets :key_variable" do
      assert {:ok, claude} = Runtimes.fetch("claude")
      {:ok, anthropic} = Providers.fetch("anthropic")
      [api] = anthropic.apis

      for auth <- [
            %{"scheme" => "basic", "username" => "runner"},
            %{"scheme" => "header", "header" => "authorization"}
          ] do
        assert Providers.serve(%{anthropic | apis: [%{api | "auth" => auth}]}, claude) ==
                 {:error, :key_variable}
      end
    end

    test "api/2 is the one API of each provider" do
      assert {:ok, claude} = Runtimes.fetch("claude")

      for provider <- Providers.list() do
        assert Providers.api(provider, claude) == {:ok, hd(provider.apis)}, provider.name
      end
    end
  end

  describe "serve/2" do
    test "is :ok for a shared format and a model key with that format and the same auth" do
      runtime = runtime(model_keys: [key(%{"scheme" => "bearer"})])
      assert Providers.serve(provider([]), runtime) == :ok
      assert Providers.serves?(provider([]), runtime)
    end

    test "is :ok when one of several APIs and one of several model keys match" do
      runtime =
        runtime(
          model: %{"formats" => ["openai-chat", "anthropic-messages"]},
          model_keys: [
            key(%{"scheme" => "header", "header" => "x-api-key"}, "anthropic-messages"),
            key(%{"scheme" => "bearer"}, "openai-chat", "OTHER_KEY")
          ]
        )

      provider =
        provider(
          apis: [
            api("gemini", %{"scheme" => "bearer"}),
            api("openai-chat", %{"scheme" => "bearer"})
          ]
        )

      assert Providers.serve(provider, runtime) == :ok
    end

    test "reads none of the runtime's declarations" do
      runtime =
        runtime(model_keys: [], declares: [declare("MODEL_KEY", %{"scheme" => "bearer"})])

      assert Providers.serve(provider([]), runtime) == {:error, :key_variable}
    end

    test "refuses with :format when no API has a format of the runtime" do
      runtime = runtime(model_keys: [key(%{"scheme" => "bearer"})])

      provider =
        provider(
          apis: [
            api("openai-chat", %{"scheme" => "bearer"}),
            api("openai-responses", %{"scheme" => "bearer"})
          ]
        )

      assert Providers.serve(provider, runtime) == {:error, :format}
      refute Providers.serves?(provider, runtime)
    end

    test "refuses with :format for a runtime without a model" do
      runtime = runtime(model: nil, model_keys: [])
      assert Runtimes.formats(runtime) == []
      assert Providers.serve(provider([]), runtime) == {:error, :format}
    end

    test "checks the format before the model key" do
      runtime = runtime(model_keys: [])

      assert Providers.serve(provider(apis: [api("gemini", %{"scheme" => "bearer"})]), runtime) ==
               {:error, :format}
    end

    test "refuses with :key_variable when the runtime has no model key" do
      assert Providers.serve(provider([]), runtime(model_keys: [])) == {:error, :key_variable}
    end

    test "refuses with :key_variable when the model key's auth differs" do
      for auth <- [
            %{"scheme" => "header", "header" => "x-api-key"},
            %{"scheme" => "basic", "username" => "runner"},
            %{"scheme" => "bearer", "oauth" => true}
          ] do
        runtime = runtime(model_keys: [key(auth)])
        assert Providers.serve(provider([]), runtime) == {:error, :key_variable}, inspect(auth)
      end
    end

    test "refuses with :key_variable when the header of a header auth differs" do
      provider =
        provider(
          apis: [api("anthropic-messages", %{"scheme" => "header", "header" => "x-api-key"})]
        )

      runtime = runtime(model_keys: [key(%{"scheme" => "header", "header" => "x-key"})])
      assert Providers.serve(provider, runtime) == {:error, :key_variable}
    end

    test "compares the header of a header auth with case ignored, as Forager does" do
      provider =
        provider(
          apis: [api("anthropic-messages", %{"scheme" => "header", "header" => "X-Api-Key"})]
        )

      runtime = runtime(model_keys: [key(%{"scheme" => "header", "header" => "x-api-key"})])
      assert Providers.serve(provider, runtime) == :ok
    end

    test "refuses with :key_variable when the matching auth is for a format of another API" do
      runtime =
        runtime(
          model: %{"formats" => ["anthropic-messages", "openai-chat"]},
          model_keys: [
            key(%{"scheme" => "header", "header" => "x-api-key"}, "anthropic-messages"),
            key(%{"scheme" => "bearer"}, "openai-chat")
          ]
        )

      provider =
        provider(
          apis: [
            api("anthropic-messages", %{"scheme" => "bearer"}),
            api("gemini", %{"scheme" => "header", "header" => "x-api-key"})
          ]
        )

      assert Providers.serve(provider, runtime) == {:error, :key_variable}
    end
  end

  describe "api/2" do
    test "is the API whose format and auth a model key of the runtime has" do
      runtime =
        runtime(
          model: %{"formats" => ["anthropic-messages", "openai-chat"]},
          model_keys: [key(%{"scheme" => "bearer"}, "openai-chat", "OTHER_KEY")]
        )

      chat = api("openai-chat", %{"scheme" => "bearer"}, "https://chat.example.com/v1")

      provider =
        provider(apis: [api("anthropic-messages", %{"scheme" => "bearer"}), chat])

      assert Providers.api(provider, runtime) == {:ok, chat}
    end

    test "is the first in the description's order when more than one matches" do
      runtime =
        runtime(
          model: %{"formats" => ["anthropic-messages", "openai-chat"]},
          model_keys: [
            key(%{"scheme" => "bearer"}, "openai-chat", "OTHER_KEY"),
            key(%{"scheme" => "bearer"}, "anthropic-messages")
          ]
        )

      chat = api("openai-chat", %{"scheme" => "bearer"}, "https://chat.example.com/v1")
      messages = api("anthropic-messages", %{"scheme" => "bearer"})

      assert Providers.api(provider(apis: [chat, messages]), runtime) == {:ok, chat}
      assert Providers.api(provider(apis: [messages, chat]), runtime) == {:ok, messages}
    end

    test "gives the refusals of serve/2" do
      runtime = runtime(model_keys: [key(%{"scheme" => "bearer"})])

      assert Providers.api(provider(apis: [api("gemini", %{"scheme" => "bearer"})]), runtime) ==
               {:error, :format}

      assert Providers.api(
               provider(
                 apis: [api("anthropic-messages", %{"scheme" => "basic", "username" => "u"})]
               ),
               runtime
             ) == {:error, :key_variable}
    end
  end
end
