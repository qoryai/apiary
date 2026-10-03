defmodule Apiary.Integrations.DescriptionTest do
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations.Description

  @fixtures Path.expand("../../fixtures/integration-contract", __DIR__)

  defp parse(description), do: description |> encode() |> Description.parse()

  describe "the integrations contract's fixtures" do
    test "every accepted fixture is read" do
      for file <- Path.wildcard(Path.join(@fixtures, "*.json")) do
        assert {:ok, %Description{}} = file |> File.read!() |> Description.parse(),
               Path.basename(file)
      end
    end

    test "every refused fixture is refused, but the one without a publisher" do
      for file <- Path.wildcard(Path.join(@fixtures, "invalid/*.json")) do
        result = file |> File.read!() |> Description.parse()

        if Path.basename(file) == "description-no-publisher.json",
          do: assert({:ok, %Description{publisher: nil}} = result),
          else: assert({:error, {:description_invalid, _}} = result, Path.basename(file))
      end
    end
  end

  describe "a description" do
    test "is read: its name, publisher, roles, ways, secrets and plain settings" do
      assert {:ok, description} = parse(github_description())
      assert description.name == "github"
      assert description.program_version == "0.1.0"
      assert description.publisher == %{"name" => "Qory", "url" => "https://qory.dev"}
      assert description.roles == ["credential"]
      assert description.ways == ["credential"]

      assert description.secrets == [
               %{name: "private_key", title: "Private key", secret_name: "GITHUB_APP_PRIVATE_KEY"}
             ]

      assert description.settings == ["api_url", "app_id"]

      assert {:ok, tracker} = parse(tracker_description())
      assert tracker.roles == ["credential", "tool", "work_source"]
      assert tracker.ways == ["credential", "tool"]
    end

    test "is read without a publisher, which is shown and never required" do
      assert {:ok, %Description{publisher: nil}} =
               github_description() |> Map.delete("publisher") |> encode() |> Description.parse()

      assert {:error, {:description_invalid, _}} =
               parse(
                 github_description(%{
                   "publisher" => %{"name" => "Qory", "url" => "http://qory.dev"}
                 })
               )
    end

    test "is refused when it is no JSON object, or the schema refuses it" do
      assert {:error, {:description_invalid, [:not_json]}} = Description.parse("{")
      assert {:error, {:description_invalid, [:not_an_object]}} = Description.parse("[]")

      assert {:error, {:description_invalid, _}} =
               parse(github_description(%{"name" => "github\n"}))

      assert {:error, {:description_invalid, _}} = parse(github_description(%{"version" => 2}))
    end

    test "is refused for a secret without its _file, its title or a role listing it" do
      description = github_description()

      without_file =
        update_in(description, ["settings", "properties"], &Map.delete(&1, "private_key_file"))

      assert {:error, {:description_invalid, [{:secret_without_file, "private_key"}]}} =
               parse(without_file)

      unlisted =
        put_in(description, ["roles", "credential", "settings"], ["app_id"])
        |> put_in(["roles", "credential", "required"], ["app_id"])

      assert {:error, {:description_invalid, [{:secret_not_listed, "private_key"}]}} =
               parse(unlisted)

      untitled =
        put_in(description, ["settings", "properties", "private_key", "title"], "  ")

      assert {:error, {:description_invalid, [{:secret_without_title, "private_key"}]}} =
               parse(untitled)
    end

    test "is refused for a role that lists a secret's _file or a setting it does not have" do
      lists_file =
        put_in(github_description(), ["roles", "credential", "settings"], [
          "app_id",
          "private_key",
          "private_key_file"
        ])

      assert {:error,
              {:description_invalid, [{:role_lists_file, "credential", "private_key_file"}]}} =
               parse(lists_file)

      unknown =
        put_in(github_description(), ["roles", "credential", "required"], ["app_id", "region"])

      assert {:error, {:description_invalid, [{:role_requires_unlisted, "credential", "region"}]}} =
               parse(unknown)
    end

    test "is refused when a tool serves a credential host, or its MCP URL is not served" do
      overlap = put_in(tracker_description(), ["roles", "tool", "serves"], ["*.example.com"])
      assert {:error, {:description_invalid, problems}} = parse(overlap)
      assert {:hosts_overlap, "tracker.example.com", "*.example.com"} in problems

      unserved =
        put_in(tracker_description(), ["roles", "tool", "mcp"], "https://other.example.com/mcp")

      assert {:error, {:description_invalid, [{:mcp_not_served, "other.example.com"}]}} =
               parse(unserved)

      with_port =
        put_in(
          tracker_description(),
          ["roles", "tool", "mcp"],
          "https://mcp.example.com:8443/mcp"
        )

      assert {:error, {:description_invalid, [{:mcp_invalid, _}]}} = parse(with_port)
    end

    test "is refused for a tool placeholder a placeholder may not take: placeholder_conflict" do
      for name <- ["QORY_RUN_ID", "ANTHROPIC_API_KEY"] do
        conflicting = put_in(tracker_description(), ["roles", "tool", "placeholders"], [name])
        assert {:error, {:placeholder_conflict, [^name]}} = parse(conflicting)
      end
    end
  end

  describe "a connection's settings" do
    setup do
      {:ok, description} = parse(github_description())
      %{description: description}
    end

    test "are its plain settings, valid against the description", %{description: description} do
      assert Description.check_settings(description, %{"app_id" => "123456"}) == :ok
      assert Description.check_settings(description, %{}) == :ok

      assert {:error, {:integration_settings_invalid, _}} =
               Description.check_settings(description, %{"app_id" => "not an id"})

      assert {:error, {:integration_settings_invalid, _}} =
               Description.check_settings(description, %{"app_id" => "1\n"})
    end

    test "never hold a secret, a secret's _file, or a name no role lists",
         %{description: description} do
      assert {:error, {:integration_settings_not_allowed, ["private_key_file"]}} =
               Description.check_settings(description, %{"private_key_file" => "/etc/key.pem"})

      assert {:error, {:integration_settings_not_allowed, ["private_key"]}} =
               Description.check_settings(description, %{"private_key" => "-----BEGIN"})

      assert {:error, {:integration_settings_not_allowed, ["region"]}} =
               Description.check_settings(description, %{"region" => "eu"})
    end

    test "are at most 64 KiB as canonical JSON", %{description: description} do
      assert {:error, {:integration_settings_too_large, 65_536}} =
               Description.check_settings(description, %{
                 "api_url" => "https://" <> String.duplicate("a", 65_536)
               })
    end

    test "an argument matches every role's pattern whole", %{description: description} do
      assert Description.check_argument(description, nil) == :ok
      assert Description.check_argument(description, "acme/shop") == :ok

      assert {:error, {:integration_argument_not_allowed, ["credential"]}} =
               Description.check_argument(description, "acme/shop\n")

      assert {:error, {:integration_argument_not_allowed, ["credential"]}} =
               Description.check_argument(description, "acme")
    end
  end
end
