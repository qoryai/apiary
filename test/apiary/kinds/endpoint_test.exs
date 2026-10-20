defmodule Apiary.Kinds.EndpointTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Endpoint, Provider, Providers}

  defp refusal(address) do
    {:error, {message, bindings}} = Endpoint.check(address)
    {message, bindings}
  end

  defp message(address), do: address |> refusal() |> elem(0)

  describe "check/1 lets pass" do
    test "the contract's endpoint_url forms, private addresses included" do
      for address <- [
            "https://models.example.com",
            "https://models.example.com/",
            "https://models.example.com:8443/v1/messages",
            "https://a.b",
            "https://litellm.example.com/path-with_chars.~!$&'()*+,;=:@/x",
            "https://models.example.com/%2F%aa",
            "https://10.0.0.12",
            "https://192.168.1.1:4000",
            "https://172.16.0.1/proxy",
            "https://xn--bcher-kva.example",
            "https://models.example.com:1",
            "https://models.example.com:65535",
            "https://" <> String.duplicate("a", 63) <> ".example"
          ] do
        assert Endpoint.check(address) == :ok, address
      end
    end

    test "an address of 2,048 characters, and refuses one of 2,049" do
      base = "https://models.example.com/"
      at_bound = base <> String.duplicate("a", 2048 - String.length(base))
      assert String.length(at_bound) == 2048
      assert Endpoint.check(at_bound) == :ok

      assert refusal(at_bound <> "a") ==
               {"Shorten the address to at most 2,048 characters.", []}
    end
  end

  describe "check/1 refuses" do
    test "a scheme other than https" do
      for address <- [
            "http://models.example.com",
            "HTTPS://models.example.com",
            "models.example.com",
            "",
            nil,
            42
          ] do
        assert refusal(address) ==
                 {"Start the address with https://, such as https://models.example.com.", []},
               inspect(address)
      end
    end

    test "user information" do
      assert message("https://key@models.example.com") ==
               "Remove the part before @ from the address. Enter the key among the provider's keys instead."

      assert message("https://user:key@models.example.com/v1") =~ "Remove the part before @"
    end

    test "a query or a fragment, by its first character" do
      text =
        "Remove the %{character} and everything after it. The address takes a path, but no query or fragment."

      assert refusal("https://models.example.com?x=1") == {text, character: "?"}
      assert refusal("https://models.example.com/v1#top") == {text, character: "#"}
      assert refusal("https://models.example.com/v1#a?b") == {text, character: "#"}
    end

    test "an upper-case host, with the host in lower case" do
      assert refusal("https://Models.Example.com/v1") ==
               {"Write the host in lower case: %{host}.", host: "models.example.com"}
    end

    test "other characters, an empty host and IPv6" do
      for address <- [
            "https://models_x.example.com",
            "https://-models.example.com",
            "https://models-.example.com",
            "https://models..example.com",
            "https://.example.com",
            "https://",
            "https://:443",
            "https://[::1]/",
            "https://[fe80::1]:8443",
            "https://fe80::1",
            "https://" <> String.duplicate("a", 64) <> ".example",
            "https://modèles.example.com",
            "https://models.example.com" <> <<0xFF>>
          ] do
        assert refusal(address) ==
                 {"Write the host as labels of letters, digits and hyphens joined by dots, such as models.example.com.",
                  []},
               inspect(address)
      end
    end

    test "a port out of range or with a leading zero" do
      for address <- [
            "https://models.example.com:",
            "https://models.example.com:0",
            "https://models.example.com:065",
            "https://models.example.com:65536",
            "https://models.example.com:http"
          ] do
        assert refusal(address) ==
                 {"Write the port as a number from 1 to 65535, with no leading zero.", []},
               address
      end
    end

    test "a path character outside the set, and a bare %" do
      text = "Percent-encode %{character} in the path, or remove it."
      assert refusal("https://models.example.com/a b") == {text, character: " "}
      assert refusal("https://models.example.com/a\"b") == {text, character: "\""}
      assert refusal("https://models.example.com/50%") == {text, character: "%"}
      assert refusal("https://models.example.com/%zz") == {text, character: "%"}
      assert refusal("https://models.example.com/ü") == {text, character: "ü"}
    end

    test "a single label" do
      for address <- ["https://models", "https://localhost", "https://2130706433"] do
        assert refusal(address) ==
                 {"Enter the full host name, such as models.example.com. Runs may not reach a host without a dot.",
                  []},
               address
      end
    end

    test "a localhost name, or a host under one" do
      text =
        "Enter the host that runs reach over the network. %{host} is a name for the local machine."

      for host <- ~w(localhost.localdomain localhost4.localdomain6 a.localhost b.localhost6) do
        assert refusal("https://#{host}/v1") == {text, host: host}, host
      end

      assert Endpoint.check("https://localhost.example.com") == :ok
    end

    test "an IPv4 address in a refused range, with the range" do
      text = "Enter another host. Runs may not reach %{host}: it is in %{range}."

      for {host, range} <- [
            {"127.0.0.1", "127.0.0.0/8"},
            {"127.255.255.255", "127.0.0.0/8"},
            {"169.254.169.254", "169.254.0.0/16"},
            {"0.0.0.0", "0.0.0.0/8"},
            {"0.1.2.3", "0.0.0.0/8"}
          ] do
        assert refusal("https://#{host}:8443/v1") == {text, host: host, range: range}, host
      end

      for host <- ~w(126.255.255.255 128.0.0.1 169.253.0.1 169.255.0.1 1.0.0.0),
          do: assert(Endpoint.check("https://#{host}") == :ok, host)
    end

    test "a number in a form other than a canonical IPv4 address" do
      text =
        "Write the address as four numbers from 0 to 255 with dots between them and no leading zeros, such as 10.0.0.12."

      for host <-
            ~w(127.1 010.0.0.1 10.0.0.256 1.2.3.4.5 0x7f.0.0.1 a.0x7f models.example.123 a.0x) do
        assert refusal("https://#{host}") == {text, []}, host
      end
    end
  end

  test "host/1 is the host of an address that passes, and :error otherwise" do
    assert Endpoint.host("https://models.example.com:8443/v1") == {:ok, "models.example.com"}
    assert Endpoint.host("https://10.0.0.12") == {:ok, "10.0.0.12"}
    assert Endpoint.host("https://127.0.0.1") == :error
    assert Endpoint.host(nil) == :error
  end

  describe "the vendored descriptions" do
    # The compile reads every description through Provider.load!/1, which refuses one whose
    # URL endpoint or address default breaks the rule; this test states it of the pinned
    # files.
    test "every URL endpoint and every default of an address setting passes" do
      for provider <- Providers.list() do
        for %{"endpoint" => endpoint} <- provider.apis,
            is_binary(endpoint),
            do: assert(Endpoint.check(endpoint) == :ok, provider.name)

        for name <- Provider.address_settings(provider),
            {:ok, default} <- [Provider.setting_default(provider, name)],
            do: assert(Endpoint.check(default) == :ok, "#{provider.name}: #{name}")
      end
    end

    test "the address settings are those an endpoint or an egress host names" do
      settings = Map.new(Providers.list(), &{&1.name, Provider.address_settings(&1)})

      assert settings == %{
               "anthropic" => [],
               "claude-subscription" => [],
               "deepseek" => [],
               "litellm" => ["address"],
               "openrouter" => []
             }
    end
  end
end
