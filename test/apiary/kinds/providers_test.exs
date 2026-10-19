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

  defp provider(fields) do
    {:ok, base} = Providers.fetch("anthropic")

    struct!(
      %{base | auth: %{"scheme" => "bearer"}, key_variables: ["MODEL_KEY"]},
      fields
    )
  end

  defp declare(name, auth), do: %{"id" => "key", "title" => "Key", "name" => name, "auth" => auth}

  describe "the catalogue" do
    test "lists one provider per vendored description, in the order of its name" do
      assert Enum.map(Providers.list(), & &1.name) ==
               ~w(anthropic claude-subscription deepseek litellm openrouter)

      assert {:ok, %Provider{name: "deepseek"}} = Providers.fetch("deepseek")
      assert Providers.fetch("nothing") == :error
    end

    test "each provider has the members of its description's model_provider role" do
      for provider <- Providers.list() do
        document = provider.description.document
        role = document["roles"]["model_provider"]

        assert provider.title == document["title"]
        assert provider.endpoint == role["endpoint"]
        assert provider.formats == role["formats"]
        assert provider.hosts == Map.get(role, "hosts", [])
        assert provider.auth == role["auth"]
        assert provider.key_variables == role["key_variables"]
        assert provider.models == role["models"]
        assert provider.egress_hosts == document["egress_hosts"]
      end
    end

    test "a provider whose endpoint is a setting has no hosts and its egress host from that setting" do
      assert {:ok, provider} = Providers.fetch("litellm")
      assert provider.endpoint == %{"setting" => "address"}
      assert provider.hosts == []
      assert provider.egress_hosts == [%{"setting" => "address"}]
      assert provider.models == []
    end

    test "a provider with a URL endpoint lists its hosts and models" do
      assert {:ok, provider} = Providers.fetch("deepseek")
      assert provider.endpoint == "https://api.deepseek.com/anthropic"
      assert provider.hosts == ["api.deepseek.com"]
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
        |> pop_in(["roles", "model_provider", "formats"])
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

    test "load!/1 raises for a file named other than the description", %{tmp_dir: dir} do
      path = Path.join(dir, "other.json")
      File.write!(path, description("anthropic"))
      assert_raise ArgumentError, ~r/not a data description/, fn -> Provider.load!(path) end
    end
  end

  describe "serve/2 against the vendored claude runtime" do
    # At Forager eac178ce, the claude runtime declares ANTHROPIC_API_KEY (header x-api-key)
    # and CLAUDE_CODE_OAUTH_TOKEN (bearer), and only reserves ANTHROPIC_AUTH_TOKEN. The
    # Forager repin that declares ANTHROPIC_AUTH_TOKEN with the bearer scheme makes
    # openrouter and litellm serve the claude runtime, and changes this table.
    @served %{
      "anthropic" => :ok,
      "claude-subscription" => :ok,
      "deepseek" => :ok,
      "litellm" => {:error, :key_variable},
      "openrouter" => {:error, :key_variable}
    }

    test "each provider gets the result the pinned files give" do
      assert {:ok, claude} = Runtimes.fetch("claude")
      assert Runtimes.formats(claude) == ["anthropic-messages"]
      assert "ANTHROPIC_AUTH_TOKEN" in claude.reserves

      assert Map.new(Providers.list(), &{&1.name, Providers.serve(&1, claude)}) == @served

      for provider <- Providers.list(),
          do: assert(Providers.serves?(provider, claude) == (@served[provider.name] == :ok))
    end
  end

  describe "serve/2" do
    test "is :ok for a shared format and a declared key variable with the same auth" do
      runtime = runtime(declares: [declare("MODEL_KEY", %{"scheme" => "bearer"})])
      assert Providers.serve(provider([]), runtime) == :ok
      assert Providers.serves?(provider([]), runtime)
    end

    test "is :ok when one of several formats and one of several key variables match" do
      runtime =
        runtime(
          model: %{"formats" => ["openai-chat", "anthropic-messages"]},
          declares: [
            declare("OTHER_KEY", %{"scheme" => "bearer"}),
            declare("SECOND_KEY", %{"scheme" => "bearer"})
          ]
        )

      provider =
        provider(
          formats: ["gemini", "anthropic-messages"],
          key_variables: ["MODEL_KEY", "SECOND_KEY"]
        )

      assert Providers.serve(provider, runtime) == :ok
    end

    test "refuses with :format when the provider and the runtime share no format" do
      runtime = runtime(declares: [declare("MODEL_KEY", %{"scheme" => "bearer"})])
      provider = provider(formats: ["openai-chat", "openai-responses"])
      assert Providers.serve(provider, runtime) == {:error, :format}
      refute Providers.serves?(provider, runtime)
    end

    test "refuses with :format for a runtime without a model" do
      runtime = runtime(model: nil, declares: [declare("MODEL_KEY", %{"scheme" => "bearer"})])
      assert Runtimes.formats(runtime) == []
      assert Providers.serve(provider([]), runtime) == {:error, :format}
    end

    test "checks the format before the key variable" do
      runtime = runtime(declares: [])
      assert Providers.serve(provider(formats: ["gemini"]), runtime) == {:error, :format}
    end

    test "refuses with :key_variable when the runtime declares none of the key variables" do
      runtime = runtime(declares: [declare("OTHER_KEY", %{"scheme" => "bearer"})])
      assert Providers.serve(provider([]), runtime) == {:error, :key_variable}
    end

    test "refuses with :key_variable when the runtime only reserves the key variable" do
      runtime = runtime(declares: [], reserves: ["MODEL_KEY"])
      assert Providers.serve(provider([]), runtime) == {:error, :key_variable}
    end

    test "refuses with :key_variable when the declared auth differs" do
      for auth <- [
            %{"scheme" => "header", "header" => "x-api-key"},
            %{"scheme" => "basic", "username" => "runner"},
            nil
          ] do
        runtime = runtime(declares: [declare("MODEL_KEY", auth)])
        assert Providers.serve(provider([]), runtime) == {:error, :key_variable}, inspect(auth)
      end
    end

    test "refuses with :key_variable when the header of a header auth differs" do
      provider = provider(auth: %{"scheme" => "header", "header" => "x-api-key"})

      runtime =
        runtime(declares: [declare("MODEL_KEY", %{"scheme" => "header", "header" => "x-key"})])

      assert Providers.serve(provider, runtime) == {:error, :key_variable}
    end

    test "refuses with :key_variable when the matching auth is on another variable" do
      runtime =
        runtime(
          declares: [
            declare("MODEL_KEY", %{"scheme" => "header", "header" => "x-api-key"}),
            declare("OTHER_KEY", %{"scheme" => "bearer"})
          ]
        )

      assert Providers.serve(provider([]), runtime) == {:error, :key_variable}
    end
  end
end
